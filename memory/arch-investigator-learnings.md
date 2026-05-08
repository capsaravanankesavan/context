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
