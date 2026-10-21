# examples/basic.cr
require "../src/llm-telemetry"

telemetry = LLM::Telemetry::InMemoryTelemetryContext.new

trace_id = telemetry.start_span(
  LLM::Telemetry::SpanOptions.new(
    name: "example",
    attributes: LLM::Telemetry.attributes(component: "example")
  )
) do |span|
  span.add_event("started")

  counter = telemetry.counter("examples")
  counter.add(1)

  latency = telemetry.histogram(
    "example_latency",
    LLM::Telemetry::InstrumentOptions.new(unit: "ms")
  )
  latency.record(4.2, context: span)

  LLM::Telemetry.carrier_of(span).not_nil!["pi-memory-trace"]
end

trace = telemetry.get_trace(trace_id).not_nil!
puts LLM::Telemetry.render_trace(trace.spans)
