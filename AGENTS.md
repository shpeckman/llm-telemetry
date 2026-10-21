# AGENTS.md

## Overview

`llm-telemetry` is the Crystal port of the subset of
[`@earendil-works/pi-telemetry`](https://github.com/earendil-works/pi/tree/main/packages/telemetry)
that `llm-chord` uses: span, metrics, propagation and store contracts, no-op
implementations, the in-memory recorder, `render_trace`, and the adapter and
store conformance suites. It has no dependencies and does not depend on
`llm-chord`, which consumes it as `LLM::Telemetry`.

Upstream is the specification. When behavior is in doubt, read the upstream
source and tests (`packages/telemetry/src`, `packages/telemetry/test`) and
match them.

## Repository layout

```
src/llm-telemetry.cr                            Entry point: requires json, uuid and the library
src/llm-telemetry/testing.cr                    Entry point for `require "llm-telemetry/testing"`
src/llm/telemetry.cr                            Attributes, options, status, span/context/metrics/propagation contracts, store records, no-ops
src/llm/telemetry/clock.cr                      Clock (now_ms, elapsed_ms, every), SystemClock, SYSTEM_CLOCK
src/llm/telemetry/memory.cr                     InMemoryTelemetryContext: recording, propagation, store queries, snapshots
src/llm/telemetry/render.cr                     render_trace
src/llm/telemetry/testing/support.cr            Case, fixtures, ManualClock, assertions
src/llm/telemetry/testing/adapter_conformance.cr  adapter_conformance (upstream src/testing/conformance.ts)
src/llm/telemetry/testing/store_conformance.cr    store_conformance (upstream test/store-conformance.ts)
spec/telemetry_spec.cr                          No-op, in-memory recorder and render_trace specs
spec/conformance_spec.cr                        Both conformance suites against InMemoryTelemetryContext; clock specs
examples/basic.cr                               Usage example
```

## Build / test / spec

```console
crystal tool format src spec
crystal spec
ameba
```

## Code standards

- Every Crystal file opens with a single comment naming its path, e.g.
  `# src/llm/telemetry/clock.cr`. No other comments in code.
- Compiler-friendly, performance-focused, idiomatic Crystal; data-driven design.
- The usage-facing API must be ergonomic.
- Prevent shotgun surgery: a behavior change should touch one cohesive spot.
- Never use `out` as an identifier — it is a reserved keyword.
- Never edit the `version` field in `shard.yml`.
- Keep `README.md` (usage and public API) and this file in sync with the code.

## Conventions specific to this codebase

- Upstream promises map to blocking calls: `start_span` yields the span to a
  block and returns the block's value. A span settles when its block returns
  or raises.
- Time comes from a `Clock`: `now_ms` is upstream's `Date.now`, `elapsed_ms`
  its `performance.now`. Recorders take a clock (default `SYSTEM_CLOCK`) so
  tests can control time; never read `Time.utc` or `Time.instant` in a
  recorder directly.
- Compiler quirk: a method that captures a block (`&block : ...`) and also
  contains a proc literal (`-> { }`) can fail with "read before assignment" for
  the block variable. Keep the proc literal in a separate private method, as
  `SystemClock#stopper` and `ManualClock#canceller` do.
- The conformance suites are runner independent, like upstream's: cases are
  data (`{group, name, proc}` tables built in `adapter_conformance` and
  `store_conformance`) and raise `Testing::ConformanceFailure`. They must not
  require `spec`. A new case is one method plus one table row.
- `store_conformance` replaces upstream's `vi.spyOn(Date, "now")` with a
  `ManualClock` handed to the fixture factory; its timers (`advance`) replace
  vitest's fake timers.
- Not ported: rejections with `undefined` or non-`Error` values and
  non-string carrier values, which Crystal's types cannot express.
