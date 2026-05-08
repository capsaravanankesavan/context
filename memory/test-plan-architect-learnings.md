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
