---
name: Test Plan Architect Learnings
description: Accumulated test patterns and non-obvious findings from test-plan-architect sessions
type: feedback
---

## Session: 2026-04-30 — CAP-183706_ai_context

### Meta-Testing Pattern (Documentation / Guardrail Systems)
When the system under test is a documentation/guardrail folder (not runnable code), the standard test pyramid does not apply. Use this adapted pyramid instead:
- **Static Review (SR)** — checklist verification of file content (replaces unit tests)
- **AI Prompt Tests (APT)** — prescribe an exact Claude Code prompt; observe agent output (replaces integration tests)
- **Navigation Tests (NT)** — timed developer exercise starting from the index file (replaces smoke tests)
- **Security Audit (SA)** — grep commands + manual review for credentials, autonomous-action directives, audit trail

### APT "Must NOT See" Column
For AI agent compliance tests, the failure signal is more diagnostic than the pass signal. Always define a **Must NOT See** column alongside Expected Behaviour — it tells the reviewer exactly which CLAUDE.md directive or .context/ section to tighten when a test fails.

### CLAUDE.md as a Testable Artifact
CLAUDE.md directives can be validated against a three-property checklist:
1. **Conditional** — "if X → read Y", not blanket "always read everything"
2. **Specific** — names the class, file, or section, not vague categories
3. **No autonomous-action verbs** — no push, delete, force, CI/CD as agent actions

This is a reusable SR test pattern for any repo that uses CLAUDE.md to direct an AI coding agent.

---

## Session: 2026-05-08 — CAP-184618 Expiry Job Tuning (MongoDB Load Reduction)

### Codebase Test Infrastructure Patterns

- **BatchStatus enum state machine tests**: When a new intermediate status (WAITING) is added to
  `BatchStatus`, the test plan must cover: (a) transition INTO the status (semaphore rejection
  handler), (b) re-entry of the same status on repeated rejections, (c) guard methods that include
  the status (shouldProceed, isJobRunningForPromotion), and (d) orphan cleanup with a separate
  threshold. Testing only the terminal states misses all of these.

- **RMQMessageTrackerAspect filter tests**: Spring AMQP wraps listener exceptions in
  `ListenerExecutionFailedException`. Unit tests for the aspect's exception filter must cover:
  (a) a direct `SemaphoreRejectedException` thrown without wrapping, and (b) a
  `SemaphoreRejectedException` wrapped as the `.cause` of `ListenerExecutionFailedException`.
  Testing only the direct case gives false confidence.

- **`SpringAmqpConfigTest` for `setAdviceChain()`**: To verify the custom
  `StatefulRetryOperationsInterceptor` is correctly wired, retrieve the bean from the Spring
  context and use reflection to inspect the advice chain array. Do not rely on behavioural
  integration tests alone — the wiring can be wrong while the retry still appears to work
  because the configurer's retry chain survives as a fallback.

### Test Cases That Were Non-Obvious

- **UT-W1 (WAITING transition + `lastUpdatedOn` refresh)**: The state change to WAITING happens
  inside a `SemaphoreRejectedException` handler inside `changeExpiryForPromotion()`. The
  `lastUpdatedOn` refresh is the critical detail — test must assert the timestamp was updated,
  not just that the status changed.

- **UT-W8 (aspect filter for wrapped exception)**: Easy to write the direct-throw case and miss
  the `ListenerExecutionFailedException` wrapper. Always write both as separate test methods.

- **UT-W6 (2h threshold boundary for WAITING orphan)**: Unlike OPEN/RUNNING which use a 24h
  threshold, WAITING uses 2h. Test must assert (a) a job last-updated 1h 59m ago is NOT expired,
  and (b) a job last-updated 2h 1m ago IS expired. Missing the NOT-expired boundary is the
  common omission.

### Ambiguities Encountered

- **"Layer 1 vs Layer 2" ordering**: The user asked "can we do Layer 2 first before Layer 1 fix."
  The natural reading of "Layer 1 first" implies deployment order, but the user meant "within
  Optimisation 2, can the semaphore (called Layer 2 in the design) deploy before the container
  factory (called Layer 1)?" Always clarify: "which component performs the actual throttling
  work?" rather than reasoning from layer numbering.

- **WAITING orphan threshold (2h)**: Was not in the original design spec. Surfaced during the
  `markAllJobAsExpiredIfNotRunning()` method design when the 24h threshold was noted as too long
  for an active retry window. Rule: whenever an intermediate status is added to a batch job,
  always ask "does the orphan cleanup threshold need to be different for this status?"

### Automation Gap Patterns

- No existing automation test for the expiry date change job flow at all. All proposed AT-DEV
  tests are net-new and require: (a) creating a promotion with an expiry date, (b) triggering
  the expiry change API, (c) waiting for RMQ processing, (d) asserting the issued promotion
  records have the new expiry. The RMQ processing delay (async) makes these tests fragile without
  a polling wait with a timeout.

---

## Session: 2026-05-12 — CAP-184615 Stats Test (Automation Layer Philosophy)

### AT Layer Philosophy — Cross-Repo Generalizable Pattern

When a system has a background data pipeline (ETL, Databricks, Kafka consumer, nightly batch job)
that feeds an API, automation tests against live clusters serve a fundamentally different purpose
than integration tests:

- **ITs** prove correctness of today-path logic with controlled seeded data
- **ATs** prove the full pipeline is live: ETL ran, aggregated correctly, API reflects the result

The key differentiator is the **pipeline integrity assertion**:
```
api_value == source_db_count(active/valid)
```
This assertion can only be made from an AT running against a real cluster where the ETL has
processed the fixture series. ITs cannot make this assertion because they use embedded DBs
with no ETL running.

**Consequence for test design**: If an AT only tests today-path operations (issue N, assert
api.num_issued increases by N) without a pipeline integrity assertion, it duplicates IT coverage
and adds no value at the AT layer. Every AT against a system with an ETL pipeline should include
this `api == db_source` check, skipped only when the fixture was created this run (ETL not yet
processed it — use an `is_new` flag or equivalent).

---

## Session: 2026-05-14 — CAP-0514-0030-V2 (MongoDB Routing A/B Toggle)

### Feature Flag / A/B Routing Test Patterns

- **Org-allowlist component (`CatalogueMongoEnabledOrgs`)**: When an env-var-backed allowlist gates a feature, unit tests must cover: (a) valid multi-value parse, (b) invalid non-numeric value WARN+skip, (c) empty string → 0 orgs, (d) null orgId lookup (null-safe), (e) included org → true, (f) excluded org → false. These 6 cases are the canonical set for any env-var-backed org allowlist component.

- **`isV2Eligible()` — one unit test per unsupported filter type**: When a routing method has 9 OR-conditions that return false, write one unit test per condition. A single "any unsupported filter" test is insufficient — it passes even if 8 of the 9 conditions are missing. This is the pattern that catches the subtle "userId filter not rejected" bug where segment checks would be bypassed.

- **`size=null` pagination trap in A/B routing**: The MySQL path frequently uses `Integer.MAX_VALUE` when `size` is null (unbounded result). Any v2 path that defaults to a different value (e.g., 20) will break correctness-sampling count comparisons. Detection pattern: whenever writing test specs for correctness sampling IT tests, explicitly ask "what does MySQL return when size is null, and does the v2 path match?"

### Codebase Test Infrastructure Patterns

- **MongoDB integration tests use direct MongoTemplate inserts** (not via sync listener) for filter/response-shape tests — keeps tests deterministic and fast. Only use sync listener in dedicated `DataSyncIT` class.

- **Org IDs for v2 ITs**: Use orgId=500, 501, 502 (distinct from orgId=0 and orgId=123 used in Phase 1 ITs) to avoid cross-test pollution within the same MySQL + MongoDB containers.

- **Correctness sampling rate**: Force to 1.0 via `ReflectionTestUtils.setField` in ITs — not controllable via test application.properties without Spring context restart.

- **`CatalogueMongoEnabledOrgs` in ITs**: Construct directly with test org ID string (not via Spring context) when unit-testing; use `@Value` injection when testing through the full Spring context in ITs.

### Test Cases That Were Non-Obvious

- **Pre-Phase-2 doc null `startDate` + `status=LIVE` filter (UC-REVIEW-02)**: When a new filter field is added to a MongoDB document, pre-existing documents are missing that field. A `$lte` predicate on a null field returns no matches. This manifests as zero results for the most common status filter during the rollout window. Detection pattern: whenever adding a new filter field to a MongoDB document, ask "what does a query on this field return for pre-existing documents that lack it?" Always add a test that seeds a doc WITHOUT the field and asserts zero results — this documents the known rollout-window gap rather than hiding it.

- **Review-injected use case: MongoDB failure fallback (UC-REVIEW-01)**: The catch-all in the v2 facade path is documented but easy to omit from the test plan. Every A/B routing facade with a catch-all must have an integration test that forces an exception and verifies the fallback path serves a valid response.

- **Default sort null-field ordering (UC-REVIEW-03)**: When the default sort field (`createdOn`) is missing from pre-existing docs, MongoDB sort behavior is implementation-defined (nulls first or last, depending on direction). This produces non-deterministic page ordering during rollout. Document as a rollout caveat; add a test that seeds a null-createdOn doc and asserts the rollout window ordering is expected (not a bug, but a known behavior).

### Automation Gap Patterns

- **Pipeline integrity assertion is the key AT-layer value**: AT-DEV-02 (seed MySQL reward → sync → assert v2 API reflects it) is worth more than AT-DEV-01 (simple smoke call). The sync pipeline cannot be tested in ITs (no real RMQ + sync listener in embedded DB). Always include at least one AT that proves the full pipeline is live, not just that the endpoint returns HTTP 200.

- **AT-DEV tests for MongoDB features require the embedded MongoDB to be running on the dev cluster** — confirm cluster name and org ID before AT design.

### Tenant Isolation Test Patterns

- **Two-enabled-orgs test (TI-02)**: Distinct from Org-A-enabled-Org-B-not pattern. Both orgs enabled; seed N docs for A and M docs for B; verify each org gets exactly their count. Proves the `orgId` predicate in MongoDB Criteria prevents bleed even when both orgs are in the routing path.

- **Pre-seeded doc contamination**: Use unique orgIds per test class in MongoDB-based ITs. Unlike MySQL where rows can be deleted by orgId in `@After`, MongoDB collections persist across tests unless explicitly cleaned. Always include a `mongoTemplate.remove(Query.query(Criteria.where("orgId").is(testOrgId)), collectionName)` in `@After`.
