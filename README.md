# llm-telemetry

Vendor-neutral telemetry primitives for Crystal:

- tracing contexts and spans
- span attributes, events, links, and status
- counter, up-down counter, and histogram contracts
- context propagation through string carriers
- an in-memory reference implementation
- trace and metric querying
- `render_trace` for human-readable traces

This shard is extracted from `llm-chord`, but it does not depend on
`llm-chord`.

## Installation

Add the shard to `shard.yml`:

```yaml
dependencies:
  llm-telemetry:
    github: shpeckman/llm-telemetry
```

Run `shards install`, then require it:

```crystal
require "llm-telemetry"
```

## Quick start

```crystal
telemetry = LLM::Telemetry::InMemoryTelemetryContext.new

telemetry.start_span(
  LLM::Telemetry::SpanOptions.new(
    name: "request",
    attributes: LLM::Telemetry.attributes(route: "/demo")
  )
) do |span|
  span.add_event("validated", LLM::Telemetry.attributes(step: 1))

  counter = telemetry.counter("requests")
  counter.add(1)

  histogram = telemetry.histogram(
    "latency",
    LLM::Telemetry::InstrumentOptions.new(unit: "ms")
  )
  histogram.record(12.5, context: span)
end

page = telemetry.find_traces(
  LLM::Telemetry::TraceQuery.new(name: "request")
)

puts LLM::Telemetry.render_trace(page.traces[0].spans)
```

## Main API

### Contexts and spans

`LLM::Telemetry::TelemetryContext` starts child spans synchronously.
`LLM::Telemetry::TelemetrySpan` adds events, links, attributes, and status.

```crystal
telemetry.start_span("operation") do |span|
  span.add_event("ready")
  span.merge_attributes(LLM::Telemetry.attributes(phase: "ready"))
  span.status = LLM::Telemetry::SpanStatus.ok
end
```

### Metrics

The metrics API exposes three instrument kinds:

- `Counter`
- `UpDownCounter`
- `Histogram`

`InMemoryTelemetryContext` records measurements and supports
`MetricQuery` through `TelemetryStore#find_metrics`.

### Propagation

`InMemoryTelemetryContext` implements carrier-based propagation for its own
spans and extracted parents.

The current carrier keys are:

- `pi-memory-scope`
- `pi-memory-span`
- `pi-memory-trace`

These names preserve compatibility with the existing chord wire behavior.

### No-op implementation

Use `LLM::Telemetry::NOOP`, `NOOP_TELEMETRY_CONTEXT`, `NOOP_METRICS`, and
`NOOP_PROPAGATION` when telemetry should be discarded.

### Querying and rendering

`InMemoryTelemetryContext` implements `TelemetryStore`:

```crystal
page = telemetry.find_traces(
  LLM::Telemetry::TraceQuery.new(name: "request", errors: true)
)

trace = telemetry.get_trace(page.traces[0].trace_id).not_nil!
text = LLM::Telemetry.render_trace(trace.spans)
```

### Clocks

`LLM::Telemetry::Clock` is the time source of a recorder:

| Method | Meaning |
| --- | --- |
| `now_ms : Int64` | Wall-clock milliseconds since the Unix epoch (JavaScript's `Date.now`). Span starts and metric intervals use it. |
| `elapsed_ms : Float64` | Monotonic milliseconds (`performance.now`). Span durations and event times use it. |
| `every(interval) { }` | Runs the block every `interval` until the returned `Proc(Nil)` is called. |

`LLM::Telemetry::SYSTEM_CLOCK` is the default. Pass another clock to a
recorder to control time, for example
`InMemoryTelemetryContext.new(clock)`.

## Conformance suites

`require "llm-telemetry/testing"` adds `LLM::Telemetry::Testing`, a port of
pi-telemetry's adapter conformance suite (`/testing`) and its store
conformance suite. The cases do not depend on a test framework: each is a
`Testing::Case` (`group`, `name`, `run`) that raises
`Testing::ConformanceFailure` when the adapter does not conform. Register them
with your runner:

```crystal
require "spec"
require "llm-telemetry/testing"

class MyAdapterFixture < LLM::Telemetry::Testing::AdapterFixture
  getter context : LLM::Telemetry::TelemetryContext = MyRecorder.new

  def recorded_spans : Array(LLM::Telemetry::RecordedSpan)
    # normalize the adapter's settled spans
  end
end

factory = -> { MyAdapterFixture.new.as(LLM::Telemetry::Testing::AdapterFixture) }
LLM::Telemetry::Testing.adapter_conformance(factory).each do |test|
  it("#{test.group}: #{test.name}") { test.run }
end
```

- `adapter_conformance(factory : -> AdapterFixture)` returns the adapter
  cases (groups `capabilities`, `metrics`, `links`, `propagation`,
  `callback lifecycle`, `status`, `recording`, `parentage`). Each case creates
  its own fixture and closes it.
- An `AdapterFixture` provides `context` and `recorded_spans`. Overriding
  `propagation` enables the propagation cases; overriding `metrics` enables the
  metric cases, which then also need `recorded_metrics`. `close` releases the
  fixture.
- `store_conformance(factory : ManualClock -> StoreFixture)` returns the
  `TelemetryStore` cases. The factory builds the recorder on the given clock;
  the cases move its time. A `StoreFixture` provides `context` (with metrics
  and propagation), `store`, `flush` (persist what was recorded), and `close`.
- `Testing::ManualClock.new(now_ms, elapsed_ms)` is a clock whose time only
  moves when set (`now_ms=`, `elapsed_ms=`) or advanced: `advance(ms)` moves
  both and runs the interval timers that fall due, in order, on the calling
  fiber. Like vitest's fake timers, timers run on the clock's own ticks:
  setting `now_ms` (vitest's `setSystemTime`) does not make a timer due.
  `timers` counts the active ones.

Differences from pi-telemetry's suites: Crystal can only raise exceptions,
so the cases that reject with `undefined` or a non-`Error` value, and the
carrier values that are not strings, are not ported. An asynchronous
rejection is a raise after the block yields to the scheduler.

## Relationship to llm-chord

`llm-chord` consumes this shard as `LLM::Telemetry`. The old embedded
`LLM::Chord::Telemetry` implementation is removed from chord and replaced by
a dependency on this shard.

## Development

```bash
crystal tool format src spec
crystal spec
```

`spec/conformance_spec.cr` runs both conformance suites against
`InMemoryTelemetryContext`.
