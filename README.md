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

## Relationship to llm-chord

`llm-chord` consumes this shard as `LLM::Telemetry`. The old embedded
`LLM::Chord::Telemetry` implementation is removed from chord and replaced by
a dependency on this shard.

## Development

```bash
crystal tool format src spec
crystal spec
```
