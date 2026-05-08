# Tech Detailer Learnings

---

## Session: 2026-04-21 — CAP-184615 Stats Test Coverage (Luci)

### Codebase Patterns Discovered

- **`isMysql` field flag on `CouponSeriesStatisticsField` enum** (`CouponSeriesStatisticsField.java:12,13,32`):
  Fields with `isMysql=true` (RIC, RRC) are **never stored in the blueprint rolling table** (`stats_history_blueprint_*`).
  They live exclusively in `stats_series_summary`. `getMysqlSummaryValue()` reads them; `getHistoricalValue()` never touches them.
  Pattern to watch: any new stats field must set `isMysql` correctly or it will silently never appear in limit checks.

- **Two-path GET API stats assembly** (`MySQLCouponSeriesStatisticsReadService.java:192-299`):
  `bulkFetchHistoryValues()` is NOT "blueprint + summary". It splits into:
  - `bulkGetHistoricalValues()` → blueprint ONLY
  - `bulkFetchStatsFromCacheOrDb()` → summary (snapshotDate+1 → today) — owned by `cachedStats`
  - `bulkGetMysqlSummaryValues()` → RIC/RRC from summary only
  Final value = `cachedStat(IC - RIC) + blueprintIC`. A test seeding only blueprint will NOT see summary IC unless it also seeds `stats_series_summary`.

- **`getHistoricalValue()` is `@Cacheable`** (`StatsHistoryServiceImpl.java:49-50`):
  Uses `MIDNIGHT_EXPIRING_CACHE_NAME`. Tests that seed blueprint data mid-run must evict Redis before exercising the limit path. `deleteRedisByKeyPattern(MIDNIGHT_EXPIRING_CACHE_NAME + "*")` is available in `BaseIntegrationTest`.

- **`isDbStatsReadEnabled` is `true` for all orgs in IT env** (`src/test/resources/application.properties`):
  `luci.app.db.stats.read.enabled=${DB_STATS_READ_ENABLED:true}` + empty orgs list.
  No per-test setup needed. Applies to orgId=0 and orgId=123 equally.

- **`MAX_LOOK_BACK_DAYS = -100`** (`StatsHistoryServiceImpl.java:34`): Confirmed exact value.
  The fallback path (no registry) reads summary from today−100 days → yesterday.

- **Actual IC limit check split across TWO processors**:
  - `SeriesLockAcquireProcessor.process()` → computes `effectiveIssued`, puts into context
  - `MaxCouponIssualPerSeriesProcessor.process()` → reads context, compares vs `maxCreate`
  The handoff (and most mental models) conflate these. When writing IC limit tests, the full chain must fire.

- **`insertHistoricalStatsData(orgId, couponSeriesId, tableName, ic, rc)`** accepts `Long couponSeriesId`:
  The existing test passes hardcoded `1L` (risky — assumes clean DB + first series = ID 1).
  All new tests MUST pass `(long) savedSeries.getId()` — use the actual series ID from `saveCouponSeries()`.

### Design Gaps Caught (and what pattern to watch for)

- **RIC-in-blueprint claim**: Handoff stated "seed RIC in a blueprint table" → impossible.
  Detection pattern: check `field.isMysql()` before assuming any field goes into the blueprint.
  Any investigator claim about blueprint data should be validated against the enum.

- **"bulkFetchHistoryValues = blueprint + summary"**: Handoff over-simplified the GET API path.
  Detection pattern: read `MySQLCouponSeriesStatisticsReadService.bulkFetchHistoryValues()` directly
  when a "bulk fetch" claim is made — the three separate sub-calls are not obvious from the method name.

### Use Cases That Were Non-Obvious

- **UC-8 (snapshot=today edge case)**: When DataBricks runs early and writes a snapshot for today,
  `startDate > endDate` in `getHistoricalValue` → `sumValuesForDateRange` is skipped. This is handled
  by `StatsHistoryServiceImpl.java:87` but has no IT coverage. Not obvious from the handoff because the
  handoff focused on "past days" scenarios.

- **UC-2 (RC limit boundary at exact limit)**: `incrementRedeemedCount()` is called BEFORE the check
  (`MaxRedemptionForSeriesProcessor.java:119`). So if maxRedeem=15 and historical=14, the 1st redeem
  increments to mysql_today=1 → total=15 → `15 < 15` is false → proceeds. 2nd redeem: total=16 →
  `15 < 16` → fails. Tests must issue 2 different coupons to exercise both sides of the boundary.

### Low-Level Guardrail Violations Found

None — this was a test-only task. No production code was changed.

### Questions That Unlocked Hidden Scope

- "Is `isDbStatsReadEnabled` enabled in the IT env?" → Answer: yes, globally via application.properties.
  This eliminated the need for per-test `ReflectionTestUtils.setField` calls in ITs.

- "What is `Fixture.orgId`?" → 123. The existing history IT uses 123; new tests use 0.
  Both work because the flag is enabled for all orgs in the IT env.

### Upstream / Downstream Notes

- `stats_history_blueprint_*` tables are created by `StatsHistoryRunner` (DataBricks ETL).
  In ITs, `createRollingTable(daysAgo)` creates the table schema; `insertHistoricalStatsData()` populates it.
- `stats_series_summary` is written in real-time on every issue/redeem/revoke/reactivate.
  In ITs, past-day rows are seeded directly via `insertStatsSeriesSummary()`.
- The midnight-expiring Redis cache (`MIDNIGHT_EXPIRING_CACHE_NAME`) is the primary caching layer
  for `getHistoricalValue`. Its eviction is handled by `updateStatsSeriesSummaryDateTo()` in the
  existing test (line 1200). New tests that don't call this method must evict explicitly.

---

## Session: 2026-05-08 — CAP-184618 Expiry Job Tuning (MongoDB Load Reduction)

### Codebase Patterns Discovered

- **`BatchStatus` enum** (`bo/reminder/BatchStatus.java:4`): `OPEN, RUNNING, ERRORED, COMPLETED, EXPIRED, STOPPED`.
  Adding a new intermediate status (WAITING) between existing values requires auditing **every** place
  that matches on BatchStatus, not just the obvious processing path. Three locations were affected:
  `shouldProceed()`, `isJobRunningForPromotion()`, and `markAllJobAsExpiredIfNotRunning()` — each
  needed different handling of the new status.

- **`ExpiryDateChangeJobFacade.shouldProceed()`** (`ExpiryDateChangeJobFacade.java:58-64`):
  Checks BatchStatus directly to decide whether to continue processing an RMQ message.
  If WAITING is not added here, the job retries consume the message but silently drop the job —
  no error, no log, work simply disappears. This is the highest-risk omission when adding a new
  "retrying" status to any batch job in this codebase.

- **`ExpiryDateChangeJobService.isJobRunningForPromotion()`** (`ExpiryDateChangeJobService.java:96-102`):
  Queries for `OPEN, RUNNING` jobs to block duplicate creation. WAITING must be included or a
  second admin trigger creates a second job while the first is throttle-retrying, causing
  double-processing of the same promotion.

- **`ExpiryDateChangeJobService.markAllJobAsExpiredIfNotRunning()`** (`ExpiryDateChangeJobService.java:113-127`):
  Uses 24h threshold for OPEN/RUNNING orphans. WAITING needs a **shorter** 2h threshold — safe because
  `lastUpdatedOn` is refreshed on every semaphore rejection (active retrying jobs are never caught),
  and 2h >> the actual 17-min retry window (no false positives on healthy retrying jobs).

- **Spring AMQP exception wrapping**: When a `@RabbitListener` method throws, Spring AMQP wraps the
  exception in `ListenerExecutionFailedException`. An AOP aspect (`RMQMessageTrackerAspect`) catching
  listener failures receives the wrapper, not the raw exception. Must check both:
  `throwable instanceof SemaphoreRejectedException` AND `throwable.getCause() instanceof SemaphoreRejectedException`.
  Missing the `.getCause()` check means the aspect filter does not fire for any Spring AMQP invocation.

- **`factory.setAdviceChain()` vs `configurer.configure()`** (`SpringAmqpConfig.java`):
  `configurer.configure(factory)` sets the message converter, error handler, and default retry chain.
  `factory.setAdviceChain(retryInterceptor)` **replaces** only the retry chain, leaving the rest intact.
  The correct sequence is: (1) `configurer.configure(factory)`, (2) `factory.setAdviceChain(retryInterceptor)`.
  Inverting the order or skipping `configurer.configure()` drops the message converter.

- **Custom `StatefulRetryOperationsInterceptor` requires explicit `@Value` injection**: The retry
  properties (`maxAttempts`, `initialInterval`, `multiplier`, `maxInterval`) used by
  `configurer.configure()` are not exposed as fields on the configurer object — they are injected
  directly into the configurer bean. A custom interceptor built in `SpringAmqpConfig` must declare
  its own `@Value` fields for the same properties.

### Design Gaps Caught (and what pattern to watch for)

- **`shouldProceed()` listed as "no change"**: Analysis doc originally put `shouldProceed()` in the
  "What Does NOT Change" list. In reality, adding WAITING required updating it.
  Detection pattern: **whenever adding a new BatchStatus value, grep every usage of `BatchStatus.`
  in the codebase before writing the "no change" list**. Status enums propagate silently — the
  compiler won't warn you about a missing `case`.

- **Flat task list with no deployment order**: The original task breakdown was a single ordered list
  with no PR boundaries. Three of the optimisations are fully independent and could be deployed
  separately, but that wasn't visible from the flat list.
  Detection pattern: after grouping tasks by component, ask "can any subset of these deploy without
  the others?" If yes, define PR boundaries explicitly — implementers default to one big PR
  unless told otherwise.

### Use Cases That Were Non-Obvious

- **UC-11 (duplicate job blocked by WAITING guard)**: While a job is throttle-retrying in WAITING
  state, a second admin triggering the same promotion's expiry change must be blocked. Not obvious
  because WAITING looks like a "failed" state from the outside, but it is an active retry state that
  still holds exclusive ownership of the job slot.

- **UC-10 (WAITING orphan expiry at 2h)**: The 2h threshold is safe precisely because `lastUpdatedOn`
  is refreshed on every semaphore rejection. This is not obvious — the threshold choice only makes
  sense once you confirm that the lastUpdatedOn refresh happens inside the rejection handler, not
  just on terminal state changes.

### Low-Level Guardrail Violations Found

None — this session was design and documentation work, not production code modification.

### Questions That Unlocked Hidden Scope

- "Should `lastUpdatedOn` be refreshed when transitioning to WAITING?" → Yes → this refresh is what
  makes the 2h orphan threshold safe → the entire WAITING design depends on this single detail.
  Without the refresh, any threshold would either expire healthy jobs or never expire true orphans.

- "Within Optimisation 2, can the Redis semaphore (Layer 2) deploy before the container factory
  (Layer 1)?" → Yes → the semaphore lives in the processing path, independent of which container
  factory consumed the message → this answer enabled the three-PR split and gave the team a
  shippable intermediate state.

### Upstream / Downstream Notes

- `RMQMessageTrackerAspect` is an AOP aspect wrapping all RabbitMQ listener invocations in this
  service. Spring AMQP routes exceptions through `ListenerExecutionFailedException` before the aspect
  sees them — always check `.getCause()` when filtering for application-level exceptions in this
  aspect.

- `expiryDateChangeContainerFactory` (dedicated Spring AMQP container factory): both the bean
  definition AND the `@RabbitListener(containerFactory=...)` update must deploy together (PR-2).
  The bean alone does nothing; the annotation change alone breaks the listener. They are a single
  atomic deployment unit.
