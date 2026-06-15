# Arch Investigator Learnings

---

## Session: 2026-04-01 — MongoDB Duplicate Index Migration (Promotion Engine)

### Failure Pattern
**Category:** Infrastructure — Index write amplification under bulk update workload
Every write synchronously maintains redundant indexes. On 1.4B+ doc collections with 150GB+ total index size, each redundant index multiplies write IO linearly. Bulk jobs (ExpiryDateUpdateJob) expose this at scale even though normal traffic hides it.

### Codebase-Specific Knowledge (Promotion Engine)
- `IAttributionMigration.java` — dual-write interface. Implemented by `CustomerEarnedPromotion`, `CustomerIssuedPromotion`, `CodeBasedPromotion`, `PromotionRedemption`, `CartEvaluation`, `CustomerPromotionPreference`. All have `attribution.lastUpdatedOn` + `lastUpdatedOn` indexes.
- `AbstractExpiryDateChangeDao.java` — bulk update base class. Bypasses BO layer — dual-write must be removed HERE separately from the BO layer fix.
- `TODO IDATE-Clean` markers throughout codebase — active migration work in progress. These mark dual-write code to be removed.
- Sep 1, 2023 = dual-write went live. `ObjectId("64f18c000000000000000000")` = hard upper bound for null docs.
- `OrgMongoDataSourceManager` — shard key manager. Migration jobs must iterate per shard.
- `AttributionMigrationService` — migration service already implemented. Two bugs: missing `.batchSize(batchSize)` on `FindIterable` and `sleepMs` defaults to 0.

### MongoDB Internals — Decisive Signals

**Index B-tree structure:**
- Secondary index leaf node = `(indexed_field_value → _id)`. The `_id` is stored IN the index leaf.
- `find({lastUpdatedOn: null}, {_id: 1})` with `hint({lastUpdatedOn:1})` = **covered query**. MongoDB reads only index pages. Never touches document heap. Each result = 12 bytes (ObjectId only).
- `updateMany` cannot be a covered operation — it MUST fetch the document to rewrite it. Doc heap access is unavoidable for any update strategy.

**getMore mechanics:**
- `limit(N)` = logical total result limit.
- `batchSize(M)` = network packet size (docs per transmission). Defaults to **101**.
- If `limit > 101` and `batchSize` not set → multiple `getMore` calls generated.
- Fix: `.limit(N).batchSize(N)` → all N docs in first response, zero getMore. Safe because covered query returns only ObjectIds (12 bytes each, far below 16MB cap).
- High `getmore` metric in Prometheus = streaming cursor pattern, not the `updateMany` call.

**updateMany with hint (MongoDB 4.2+):**
- `updateMany(filter, pipeline, {hint: {field: 1}})` forces the index for candidate discovery.
- With `hint({lastUpdatedOn:1})` and filter `{lastUpdatedOn:null, _id:{$gte:s,$lt:e}}`: MongoDB traverses null index entries, checks `_id` range from index leaf (no doc fetch), only fetches docs for matches.
- `updateMany` has NO `limit` parameter — cannot do doc-count-bounded updates in one call.

**WiredTiger cache eviction:**
- Migration scanning cold (old) documents evicts hot operational data from WiredTiger cache.
- Cache eviction rate (pages/sec) in Prometheus is the key signal — spikes indicate cold doc scan competing with operational working set.
- Covered index scan (projection `{_id:1}`) loads only index pages → much lower cache pressure than full document scan.

**Why doc-count batching beats time-bucketing for campaign systems:**
- Time-bucket approach: uniform time slice, variable doc count. In promotions, campaigns run in bursts — one week can have 10M docs, next week 50K. Uncontrollable load spikes per bucket.
- Doc-count batching (`findBatchIds + applyBatch`): always exactly N docs per batch regardless of temporal density. Uniform, predictable load. Correct choice for any system with burst-write patterns.

**Self-advancing cursor pattern (no stored state):**
- `find({lastUpdatedOn: null}).limit(N)` → after `applyBatch`, those N docs have `lastUpdatedOn` set → they drop out of the null index entries → next `find({lastUpdatedOn: null}).limit(N)` naturally returns the next N unprocessed docs.
- No cursor kept alive. No position tracking. Free crash recovery — restart job, it continues from remaining null docs automatically.

**ObjectId time encoding:**
- ObjectId first 4 bytes = Unix timestamp. Use to compute hard boundaries without querying.
- Sep 1 2023 00:00:00 UTC = `ObjectId("64f18c000000000000000000")`
- Jan 1 2020 = `ObjectId("5e0be1000000000000000000")`
- Jan 1 2023 = `ObjectId("63b0c1000000000000000000")`
- When dual-write cutoff date is known, migration scope is permanently bounded — never need to scan post-cutoff docs.

**`countDocuments` on large collections:**
- `countDocuments({lastUpdatedOn: null})` without an `_id` range bound = full collection scan → timeout on 1.4B docs.
- Safe alternative: `countDocuments({lastUpdatedOn: null}, {limit: 1})` — existence check only, exits after finding first match. O(1) effectively.

### Signals That Pointed to Root Cause
- Index size (161GB, 151GB) disproportionate to data size (71GB, 55GB) → index count problem
- CPU spike coincides with `ExpiryDateUpdateJob` bulk updateMulti → index maintenance under bulk write
- `getmore mean=139 max=448` in Prometheus → streaming cursor, not batched queries (key signal for migration approach)
- Cache eviction 200 pages/sec → cold doc scan evicting operational working set
- Write latency (76ms mean) lower than read latency (186ms mean) → reads/scans are the bottleneck, not writes

### Hypotheses That Were Wrong (and Why)
- "Phase 1 (collect IDs) scan causes document heap cache eviction" — WRONG. With `{_id:1}` projection and `hint({lastUpdatedOn:1})`, Phase 1 is a covered query loading only index pages. Cache eviction comes from Phase 2 document updates.
- "Separating collect IDs from update reduces total load" — WRONG. Doc heap access is unavoidable for update phase regardless. Total heap fetches = same. Only adds round trips and storage overhead.
- "time-bucketed updateMany eliminates findBatchIds" — PARTIALLY WRONG for this domain. Valid approach for uniform density, but promotions have campaign burst density — time buckets produce variable doc counts per bucket causing unpredictable load spikes.

### Architect Instinct Sharpened
1. **Always ask "when did the dual state start?" first** — the answer gives you the migration boundary as a closed, bounded window. It transforms "migrate entire collection" into "migrate a known date range."
2. **Distinguish limit (result count) from batchSize (transmission size)** — these are independent MongoDB concepts. Missing `.batchSize()` to match `.limit()` is a common bug causing unexpected getMore ops.
3. **For variable-density data (campaign systems, event-driven writes), always use doc-count batching, not time-range batching.** Time ranges look uniform but are data-density-dependent in burst-write domains.
4. **"updateMany is server-side, so let's avoid findBatchIds" is seductive but wrong when you need doc-count throttling** — updateMany has no limit. Two-phase is the correct design when uniform batch sizes matter more than round-trip count.
5. **Check auto-index-creation before dropping any MongoDB index in Spring Data apps** — `@CompoundIndex` annotations recreate dropped indexes on next startup if `auto-index-creation=true`. Code change and index drop must be coordinated in the same release.
6. **The WiredTiger cache eviction rate (pages/sec) is the real production risk metric** — more diagnostic than CPU alone. It shows whether cold-doc migration is interfering with the operational working set.

### Recurring Infrastructure / Config to Watch (Promotion Engine)
- `expiry.date.change.batch.size` (default 1000) — controls ExpiryDateUpdateJob batch size
- `attribution.migration.batch.size` (default 100) — migration job batch size. Should be 500-1000 for reasonable throughput.
- `attribution.migration.sleep.ms` (default 0 — DANGEROUS) — must be set to 500+ for prod migration runs
- `attribution.migration.heartbeat.timeout.secs` (default 300) — stale job recovery window
- `spring.data.mongodb.auto-index-creation` — verify false in prod before any index drop operation
- MongoDB cluster `emf` — primary `mongodb-emf-0`, secondary `mongodb-emf-1`, arbiter `mongodb-emf-arbiter-0`. Disk capacity 394 GiB each, currently 349/201 GiB used.

---

## Session: 2026-06-10 — num_uploaded_total Undercount for Tagged Uploads (Luci)

### Failure Pattern
**Category:** Branching asymmetry in a notification handler — one counter (TC) updated in all branches, sibling counter (UTC) updated in only one branch. Silent data loss with no error, no log, no alert.

The bug is invisible in single-import-type workloads. It only surfaces when two import types are mixed on the same series AND someone asserts both counters. This is the classic "the test that doesn't exist can't catch the bug" pattern — all prior tests used NONE-only uploads.

### Codebase-Specific Knowledge (Luci)

- `LuciThriftServiceImpl.java:1701` — `notifyCouponsUploadRequest()` is the Dracarys upload-complete notification handler. This is the write entry point for all upload stats (TC, UC, UTC).
- `LuciThriftServiceImpl.java:1726` — `CustomerIdentifierType.NOT_TAGGED` = NONE/pool import. All tagged types (USER_ID, MOBILE, EXTERNAL_ID, EMAIL) fall into the `else` branch.
- `CouponSeriesConfigImpl.java:530` — `incrementUploadedTotalCount()` has NO import-type gate. Only checks `!isExternalIssual()`. The method is correct; the caller is wrong.
- `CouponSeriesConfigImpl.java:576` — `incrementTotalCount()` is gated on `DISC_CODE_PIN` clientHandlingType only (not import type). TC is correct for all import types.
- `CouponSeriesConfigImpl.java:508` — `updateTotalAndUploadTotalCountPostRevoke()` decrements BOTH TC and UTC together on revoke — this is correct and symmetrical.
- `CouponSeriesStatisticsField.java:16` — `UploadedTotalCount("utc", false, false)` — `isMysql=false`, meaning DataBricks CAN write it to blueprint tables. Not a MySQL-only field.
- `MySQLCouponSeriesStatisticsReadService.java:393` — `getUploadedTotalCount()` read formula is `getSumFromCache(UTC)` = `blueprint_UTC + summary_UTC`. Read path is correct and needs no change.
- Regression gate: `test_LUCI_STATS_SM_05_AT_DEV_05` in `campaigns_auto/tests/luci/test_stats_mysql_pipeline.py` — uploads N1=5 NONE + N2=3 USER_ID on series `STATS_MIX_{year}_{month}`, asserts `num_uploaded_total delta == 8`. Has been failing every weekly run on US prod since 2026-05-25.

### Signals That Pointed to Root Cause

- Test log showed `numTotal delta=+8` (correct) alongside `num_uploaded_total delta=+5` (wrong). The gap = exactly N2 (USER_ID upload count). This arithmetic immediately pointed to import-type branching, not a formula bug.
- `incrementUploadedTotalCount()` has no import-type guard → the call site must be wrong, not the method.
- Searching `notifyCouponsUploadRequest` and reading both `if/else` branches revealed the asymmetry in under 2 minutes once the arithmetic pointed to write-path branching.

### Hypotheses That Were Wrong (and Why)

- "The read formula is wrong" — eliminated immediately: `numTotal` (same formula pattern, same `getSumFromCache`) was correct. If the formula were wrong, both would be off by the same amount.
- "The `incrementUploadedTotalCount` method has an import-type check" — eliminated by reading `CouponSeriesConfigImpl:530`. Only `!isExternalIssual()` gate exists.

### Architect Instinct Sharpened

1. **When two sibling counters diverge by exactly N, the bug is in the write path, not the read formula.** The divergence amount tells you what was dropped; the pattern tells you it's conditional (not off-by-one or type coercion).
2. **"Method has no guard, so the bug is in the caller" is a fast elimination move.** Read the increment method first — if it's unconditional, the branch logic must be in whoever calls it.
3. **Bugs invisible in single-import-type tests are a class of coverage gap specific to multi-mode APIs.** Any API that accepts a type enum should have at least one test that mixes two types and asserts all downstream counters.
4. **A regression gate test that fails consistently is more valuable than one that's flaky** — it gives you a precise "bug is still present" signal across every cluster on every deploy.

### Recurring Infrastructure / Config to Watch (Luci)

- `CustomerIdentifierType` enum — when a new import type is added, audit `notifyCouponsUploadRequest` branching to confirm all stat increments are covered.
- `isExternalIssual()` flag on `CouponSeriesEntity` — controls whether UTC and UC writes are suppressed. External issuance series intentionally excluded from upload stats.
- `stats_series_summary` key `"utc"` — written by `incrementUploadedTotalCount`; aggregated into `num_uploaded_total` via `getSumFromCache`. Blueprint key is also `"utc"` (DataBricks-written).
- AT-DEV-05 (`STATS_MIX_{year}_{month}`) — the only automation test that mixes NONE + USER_ID uploads and asserts UTC. Green on this test = FR-014 fix is live.

---

## Absorbed from tech-detailer inbox: 2026-06-15

### isMysql flag — mandatory pre-check before claiming where a stat field lives
- Always verify `CouponSeriesStatisticsField.isMysql()` before asserting a field is in blueprint. `RIC` (`RevokedIssueCount.isMysql=true`) and `RRC` (`ReactivatedRedemptionCount`) are NEVER in blueprint tables. Seeding them there produces zeros.
- `getSumFromCache` splits into THREE paths: `bulkGetHistoricalValues()` (blueprint-only), `bulkFetchStatsFromCacheOrDb()` (summary IC/RC), `bulkGetMysqlSummaryValues()` (RIC/RRC from summary). Not a single combined query.

### @Cacheable eviction — mandatory check for any IT that seeds blueprint mid-run
- `getHistoricalValue` has `@Cacheable` — ITs seeding blueprint data mid-run will read stale cache unless Redis is evicted first via `deleteRedisByKeyPattern(MIDNIGHT_EXPIRING_CACHE_NAME + "*")`.
- Add to investigation checklist: "If the affected method has @Cacheable, identify the cache key pattern that needs eviction in IT setup."

### Feature flag in IT environment
- `src/test/resources/application.properties` sets `luci.app.db.stats.read.enabled=${DB_STATS_READ_ENABLED:true}` with empty orgs list → all orgs have `isDbStatsReadEnabled=true` in IT env. No per-test setup needed.

### BatchStatus enum propagation — three blast-radius points
- When adding a new BatchStatus value: (a) grep all if/switch usages, (b) grep statusIn query lists, (c) check orphan-cleanup / shouldProceed() threshold methods. All three are separate blast-radius points.
- `shouldProceed()` is commonly overlooked as a "no change" candidate — adding WAITING state required updating it to allow the new status through.

### Spring AMQP exception wrapping
- AOP aspects wrapping Spring AMQP `@RabbitListener` must handle `ListenerExecutionFailedException` wrapper — the real cause is in `.getCause()`. Always note this in handoffs that propose AOP aspects on AMQP listeners.
