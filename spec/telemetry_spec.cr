# spec/telemetry_spec.cr
require "./spec_helper"

private def options(name : String, attributes : LLM::Telemetry::Attributes? = nil, links : Array(LLM::Telemetry::SpanLink)? = nil) : LLM::Telemetry::SpanOptions
  LLM::Telemetry::SpanOptions.new(name, attributes, links)
end

private def stored(id : String, parent_id : String? = nil, name : String = id, started : Float64 = 0.0, ended : Float64 = 10.0,
                   attributes : LLM::Telemetry::Attributes = LLM::Telemetry::Attributes.new,
                   events = [] of LLM::Telemetry::StoredEvent, links = [] of LLM::Telemetry::StoredLink,
                   status : LLM::Telemetry::SpanStatus = LLM::Telemetry::SpanStatus.ok, trace : String = "trace") : LLM::Telemetry::StoredSpan
  LLM::Telemetry::StoredSpan.new(id, trace, parent_id, name, started, ended, attributes, events, links, status)
end

describe "LLM::Telemetry::NOOP" do
  it "admits callbacks synchronously and reuses one inert span" do
    admitted = false
    result = LLM::Telemetry::NOOP.start_span(options("first")) do |span|
      admitted = true
      span.start_span(options("child")) { |child| child }.should be span
      span.should be LLM::Telemetry::NOOP
      42
    end
    admitted.should be_true
    result.should eq 42
    LLM::Telemetry::NOOP.metrics.should be LLM::Telemetry::NOOP_METRICS
    LLM::Telemetry::NOOP.propagation.should be LLM::Telemetry::NOOP_PROPAGATION
  end

  it "preserves raised exceptions" do
    failure = ArgumentError.new("sync")
    raised = expect_raises(ArgumentError) { LLM::Telemetry::NOOP.start_span(options("sync")) { raise failure } }
    raised.should be failure
  end

  it "ignores recording payloads" do
    LLM::Telemetry::NOOP.start_span(options("operation", LLM::Telemetry.attributes(kind: "test"))) do |span|
      span.add_event("event", LLM::Telemetry.attributes(count: 1))
      span.merge_attributes(LLM::Telemetry.attributes(complete: true))
      span.status = LLM::Telemetry::SpanStatus.error("Expected", "test")
      span.add_link(LLM::Telemetry::SpanLink.new(span))
      42
    end.should eq 42
  end

  it "shares no-op instruments and propagation" do
    counter = LLM::Telemetry::NOOP_METRICS.counter("bytes", LLM::Telemetry::InstrumentOptions.new(unit: "By"))
    counter.should be LLM::Telemetry::NOOP_METRICS.counter("other")
    counter.add(1, LLM::Telemetry.attributes(direction: "out"))
    LLM::Telemetry::NOOP_METRICS.up_down_counter("active").add(-1)
    LLM::Telemetry::NOOP_METRICS.histogram("duration").record(1, nil, LLM::Telemetry::NOOP)
    LLM::Telemetry::NOOP_PROPAGATION.inject(LLM::Telemetry::NOOP).should be_nil
    LLM::Telemetry::NOOP_PROPAGATION.extract({"unknown" => "format"}).should be LLM::Telemetry::NOOP
  end
end

describe LLM::Telemetry::InMemoryTelemetryContext do
  it "records parents, attributes, events, statuses, and settlement order" do
    telemetry = LLM::Telemetry::InMemoryTelemetryContext.new
    telemetry.start_span(options("root", LLM::Telemetry.attributes(kind: "request"))) do |root|
      root.start_span(options("child")) do |child|
        child.merge_attributes(LLM::Telemetry.attributes(rows: 3, tags: ["a"]))
        child.add_event("cache.miss", LLM::Telemetry.attributes(hit: false))
      end
      root.status = LLM::Telemetry::SpanStatus.error("Expected", "explicit")
    end
    root, child = telemetry.recorded_spans
    root.parent_id.should be_nil
    child.parent_id.should eq root.id
    child.context["pi-memory-trace"].should eq root.context["pi-memory-trace"]
    root.attributes.should eq LLM::Telemetry.attributes(kind: "request")
    child.attributes.should eq LLM::Telemetry.attributes(rows: 3, tags: ["a"])
    child.events.should eq [LLM::Telemetry::RecordedEvent.new("cache.miss", LLM::Telemetry.attributes(hit: false))]
    root.status.error.should eq LLM::Telemetry::SpanError.new("Expected", "explicit")
    child.status.ok?.should be_true
    {root.settled, child.settled}.should eq({true, true})
    child.end_sequence.should eq 1
    root.end_sequence.should eq 2
  end

  it "marks raised exceptions as errors unless a status was set" do
    telemetry = LLM::Telemetry::InMemoryTelemetryContext.new
    expect_raises(ArgumentError) { telemetry.start_span(options("failing")) { raise ArgumentError.new("boom") } }
    expect_raises(ArgumentError) do
      telemetry.start_span(options("explicit")) do |span|
        span.status = LLM::Telemetry::SpanStatus.ok
        raise ArgumentError.new("ignored")
      end
    end
    failing, explicit = telemetry.recorded_spans
    failing.status.error.should eq LLM::Telemetry::SpanError.new("ArgumentError", "boom")
    explicit.status.ok?.should be_true
  end

  it "ignores recording after settlement and records children of settled spans as inert" do
    telemetry = LLM::Telemetry::InMemoryTelemetryContext.new
    escaped = nil.as(LLM::Telemetry::TelemetrySpan?)
    telemetry.start_span(options("done")) { |span| escaped = span }
    span = escaped.not_nil!
    span.add_event("late")
    span.merge_attributes(LLM::Telemetry.attributes(late: true))
    span.start_span(options("orphan")) { |child| child.add_event("inert") }
    telemetry.recorded_spans.map(&.name).should eq ["done"]
    telemetry.recorded_spans[0].events.should be_empty
  end

  it "records wall-clock boundaries and relative event times" do
    telemetry = LLM::Telemetry::InMemoryTelemetryContext.new
    id = ""
    before = Time.utc.to_unix_ms.to_f64
    telemetry.start_span(options("timed")) do |span|
      carrier = telemetry.inject(span).not_nil!
      id = "#{carrier["pi-memory-scope"]}:#{carrier["pi-memory-span"]}"
      sleep 2.milliseconds
      span.add_event("event", LLM::Telemetry.attributes(count: 1))
    end
    trace = telemetry.get_trace(id).not_nil!
    trace.trace_id.should eq id
    stored_span = trace.spans[0]
    stored_span.id.should eq id
    stored_span.parent_id.should be_nil
    stored_span.started_ms.should be >= before
    stored_span.ended_ms.should be >= stored_span.started_ms + 2
    stored_span.events[0].time_ms.should be >= 2
    stored_span.events[0].attributes.should eq LLM::Telemetry.attributes(count: 1)
    telemetry.get_trace("missing").should be_nil
  end

  it "maps raw metric measurements to count-one rows and detached snapshots" do
    telemetry = LLM::Telemetry::InMemoryTelemetryContext.new
    telemetry.counter("calls").add(2)
    telemetry.counter("calls").add(3)
    rows = telemetry.find_metrics(LLM::Telemetry::MetricQuery.new("calls"))
    rows.map { |row| {row.count, row.sum, row.kind} }.should eq [{1, 2.0, LLM::Telemetry::MetricKind::Counter}, {1, 3.0, LLM::Telemetry::MetricKind::Counter}]
    (rows[0].interval_ms % 10_000).should eq 0
    telemetry.recorded_metrics.map(&.value).should eq [2.0, 3.0]

    histogram = telemetry.histogram("duration", LLM::Telemetry::InstrumentOptions.new(boundaries: [1.0, 2.0]))
    telemetry.start_span(options("request")) { |span| histogram.record(1, LLM::Telemetry.attributes(tags: ["original"]), span) }
    measurement = telemetry.recorded_metrics[2]
    measurement.boundaries.not_nil! << 3.0
    measurement.attributes["tags"].as(Array(String)) << "mutated"
    measurement.context.not_nil!["pi-memory-span"] = "999"
    fresh = telemetry.recorded_metrics[2]
    fresh.boundaries.should eq [1.0, 2.0]
    fresh.attributes.should eq LLM::Telemetry.attributes(tags: ["original"])
    fresh.context.should eq telemetry.recorded_spans[0].context
  end

  it "detaches link attributes and error details" do
    telemetry = LLM::Telemetry::InMemoryTelemetryContext.new
    target = telemetry.start_span(options("target")) { |span| span }
    telemetry.start_span(options("source", nil, [LLM::Telemetry::SpanLink.new(target, LLM::Telemetry.attributes(tags: ["original"]))])) do |span|
      span.status = LLM::Telemetry::SpanStatus.error("Expected", "original")
    end
    trace = telemetry.find_traces(LLM::Telemetry::TraceQuery.new(name: "source")).traces[0]
    trace.spans[0].links[0].attributes.not_nil!["tags"].as(Array(String)) << "changed"
    fresh = telemetry.get_trace(trace.trace_id).not_nil!.spans[0]
    fresh.links[0].attributes.should eq LLM::Telemetry.attributes(tags: ["original"])
    fresh.status.error.should eq LLM::Telemetry::SpanError.new("Expected", "original")
  end

  it "finds traces by name, attributes, errors, and pages with a cursor" do
    telemetry = LLM::Telemetry::InMemoryTelemetryContext.new
    5.times do |index|
      telemetry.start_span(options("request", LLM::Telemetry.attributes(index: index))) do |span|
        span.start_span(options("inner")) { |inner| inner.status = LLM::Telemetry::SpanStatus.error if index.odd? }
      end
      sleep 1.millisecond
    end
    all = telemetry.find_traces
    all.traces.size.should eq 5
    index_of = ->(trace : LLM::Telemetry::StoredTrace) { trace.spans.find!(&.name.==("request")).attributes["index"] }
    all.traces.map(&index_of).should eq [4, 3, 2, 1, 0]
    telemetry.find_traces(LLM::Telemetry::TraceQuery.new(errors: true)).traces.size.should eq 2
    telemetry.find_traces(LLM::Telemetry::TraceQuery.new(attributes: {"index" => 2_i64.as(LLM::Telemetry::QueryValue)})).traces.size.should eq 1
    telemetry.find_traces(LLM::Telemetry::TraceQuery.new(name: "missing")).traces.should be_empty
    first = telemetry.find_traces(LLM::Telemetry::TraceQuery.new(limit: 2))
    first.traces.map(&index_of).should eq [4, 3]
    second = telemetry.find_traces(LLM::Telemetry::TraceQuery.new(limit: 2, cursor: first.cursor))
    second.traces.map(&index_of).should eq [2, 1]
    third = telemetry.find_traces(LLM::Telemetry::TraceQuery.new(limit: 2, cursor: second.cursor))
    third.traces.map(&index_of).should eq [0]
    third.cursor.should be_nil
  end

  it "continues a parent from another recorder through a carrier" do
    caller = LLM::Telemetry::InMemoryTelemetryContext.new
    carrier = caller.start_span(options("caller")) { |span| caller.inject(span) }
    worker = LLM::Telemetry::InMemoryTelemetryContext.new
    worker.extract(JSON.parse(carrier.to_json).as_h.transform_values(&.as_s)).start_span(options("worker")) { }
    recorded = worker.recorded_spans
    recorded.size.should eq 1
    recorded[0].parent_context.should eq carrier
    recorded[0].parent_id.should be_nil
    recorded[0].context.should_not eq carrier
  end

  it "isolates crossed concurrent remote parents and links shared roots" do
    caller = LLM::Telemetry::InMemoryTelemetryContext.new
    provider = LLM::Telemetry::InMemoryTelemetryContext.new
    activation = nil.as(LLM::Telemetry::TelemetrySpan?)
    gate = Channel(Nil).new
    activated = Channel(Nil).new
    done = Channel(Nil).new(2)
    shared_started = false
    %w[first later].each do |name|
      spawn do
        caller.start_span(options(name)) do |trigger|
          parent = provider.extract(caller.inject(trigger))
          parent.start_span(options("#{name}.method")) do |getter|
            unless shared_started
              shared_started = true
              spawn do
                provider.start_span(options("activation", nil, [LLM::Telemetry::SpanLink.new(getter)])) do |span|
                  activation = span
                  activated.send(nil)
                  gate.receive
                end
              end
              activated.receive
            end
            while activation.nil?
              Fiber.yield
            end
            activation.try { |span| getter.add_link(LLM::Telemetry::SpanLink.new(span)) }
            gate.send(nil) if name == "later"
          end
        end
        done.send(nil)
      end
    end
    done.receive
    done.receive
    spans = provider.recorded_spans
    root = spans.find! { |span| span.name == "activation" }
    root.parent_context.should be_nil
    first = spans.find! { |span| span.name == "first.method" }
    later = spans.find! { |span| span.name == "later.method" }
    first.parent_context.should eq caller.recorded_spans[0].context
    later.parent_context.should eq caller.recorded_spans[1].context
    root.links[0].context.should eq first.context
    later.links[0].context.should eq root.context
  end

  it "detaches carrier and link snapshots and retains settled target identities" do
    telemetry = LLM::Telemetry::InMemoryTelemetryContext.new
    target = telemetry.start_span(options("target")) { |span| span }
    original = telemetry.inject(target)
    injected = telemetry.inject(target).not_nil!
    injected["pi-memory-span"] = "999"
    telemetry.inject(target).should eq original
    telemetry.start_span(options("linked", nil, [LLM::Telemetry::SpanLink.new(target, LLM::Telemetry.attributes(tags: ["original"]))])) { }
    first, linked = telemetry.recorded_spans
    first.context["pi-memory-span"] = "123"
    linked.links[0].context["pi-memory-span"] = "456"
    telemetry.recorded_spans[1].links.should eq [LLM::Telemetry::RecordedLink.new(original.not_nil!, LLM::Telemetry.attributes(tags: ["original"]))]
  end

  it "links a new root to an extracted remote target" do
    sender = LLM::Telemetry::InMemoryTelemetryContext.new
    receiver = LLM::Telemetry::InMemoryTelemetryContext.new
    carrier = sender.start_span(options("trigger")) { |span| sender.inject(span) }.not_nil!
    target = receiver.extract(carrier.dup)
    receiver.start_span(options("background", nil, [LLM::Telemetry::SpanLink.new(target, LLM::Telemetry.attributes(reason: "restart"))])) do |span|
      span.add_link(LLM::Telemetry::SpanLink.new(target))
    end
    recorded = receiver.recorded_spans[0]
    recorded.parent_context.should be_nil
    recorded.links.should eq [
      LLM::Telemetry::RecordedLink.new(carrier, LLM::Telemetry.attributes(reason: "restart")),
      LLM::Telemetry::RecordedLink.new(carrier, LLM::Telemetry::Attributes.new),
    ]
  end

  it "uses the root for absent and unknown carriers" do
    telemetry = LLM::Telemetry::InMemoryTelemetryContext.new
    [nil, LLM::Telemetry::Carrier.new, {"unknown" => "format"}].each do |carrier|
      telemetry.extract(carrier).should be telemetry
    end
  end

  it "treats recognized carrier identifiers as opaque strings" do
    telemetry = LLM::Telemetry::InMemoryTelemetryContext.new
    carrier = {"pi-memory-scope" => "external-recorder", "pi-memory-span" => "external-span", "pi-memory-trace" => "external-trace"}
    telemetry.extract(carrier).start_span(options("receiver")) { }
    telemetry.recorded_spans[0].parent_context.should eq carrier
  end

  it "exposes its metrics and propagation on spans and extracted parents" do
    telemetry = LLM::Telemetry::InMemoryTelemetryContext.new
    telemetry.metrics.should be telemetry
    telemetry.start_span(options("x")) do |span|
      span.metrics.should be telemetry
      span.propagation.should be telemetry
      telemetry.extract(telemetry.inject(span)).metrics.should be telemetry
    end
  end
end

describe "LLM::Telemetry.render_trace" do
  it "renders an unordered trace with attributes, durations, errors, events, and links" do
    root = stored("root", started: 1000.0, ended: 1020.0,
      attributes: LLM::Telemetry.attributes(request: "a b", attempt: 2, cached: false, tags: ["a", "b"], sizes: [1, 2], flags: [true, false]),
      events: [
        LLM::Telemetry::StoredEvent.new("checkpoint", 2.0, LLM::Telemetry.attributes(phase: "tools")),
        LLM::Telemetry::StoredEvent.new("tick", 3.5, LLM::Telemetry::Attributes.new),
      ],
      links: [
        LLM::Telemetry::StoredLink.new("remote-trace", "remote", LLM::Telemetry.attributes(reason: "steer")),
        LLM::Telemetry::StoredLink.new("other-trace", "other"),
      ])
    first = stored("first", "root", started: 1005.0, ended: 1009.5, status: LLM::Telemetry::SpanStatus.error("Error", "failed call"))
    nested = stored("nested", "first", started: 1006.0, ended: 1007.0)
    second = stored("second", "root", started: 1010.0, ended: 1012.0, status: LLM::Telemetry::SpanStatus.error)
    LLM::Telemetry.render_trace([second, nested, first, root]).should eq [
      %(root request="a b" attempt=2 cached=false tags=["a","b"] sizes=[1,2] flags=[true,false] (20ms)),
      %(  · checkpoint phase="tools" (+2ms)),
      "  · tick (+3.5ms)",
      %(  → link trace remote-trace span remote reason="steer"),
      "  → link trace other-trace span other",
      "  first (4.5ms) error Error: failed call",
      "    nested (1ms)",
      "  second (2ms) error",
    ].join('\n')
  end

  it "treats missing parents as roots and orders roots and children by start time" do
    LLM::Telemetry.render_trace([
      stored("later", "external", started: 20.0, ended: 30.0),
      stored("child", "later", started: 25.0, ended: 30.0),
      stored("earlier", started: 10.0, ended: 15.0, links: [LLM::Telemetry::StoredLink.new("trace", "later")]),
    ]).should eq ["earlier (5ms)", "  → link trace trace span later", "later (10ms)", "  child (5ms)"].join('\n')
  end

  it "deduplicates spans merged from stores by global ID" do
    root = stored("server:1", name: "root")
    child = stored("worker:1", "server:1", name: "child", events: [LLM::Telemetry::StoredEvent.new("done", 3.0, LLM::Telemetry::Attributes.new)])
    grandchild = stored("worker:2", "worker:1", name: "grandchild")
    LLM::Telemetry.render_trace([child, root, grandchild, root, child]).should eq "root (10ms)\n  child (10ms)\n    · done (+3ms)\n    grandchild (10ms)"
  end

  it "preserves input order for equal start times" do
    LLM::Telemetry.render_trace([stored("root"), stored("z", "root"), stored("a", "root"), stored("other")])
      .should eq "root (10ms)\n  z (10ms)\n  a (10ms)\nother (10ms)"
  end

  it "escapes string attribute values" do
    LLM::Telemetry.render_trace([stored("root", attributes: LLM::Telemetry.attributes(text: %(line one\n"line two")))])
      .should eq %(root text="line one\\n\\"line two\\"" (10ms))
  end

  it "renders deep trees without recursion and empty input as an empty string" do
    spans = (0...2000).map { |index| stored(index.to_s, index == 0 ? nil : (index - 1).to_s) }
    rendered = LLM::Telemetry.render_trace(spans)
    rendered.split('\n').size.should eq 2000
    rendered.ends_with?("#{"  " * 1999}1999 (10ms)").should be_true
    LLM::Telemetry.render_trace([] of LLM::Telemetry::StoredSpan).should eq ""
  end
end
