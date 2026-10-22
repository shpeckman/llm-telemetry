# src/llm-telemetry/testing/adapter_conformance.cr
module LLM::Telemetry::Testing
  alias AdapterTest = AdapterFixture -> Nil

  def self.adapter_conformance(factory : AdapterFactory) : Array(Case)
    tests = [
      {"capabilities", "carries adapter capabilities through contexts and spans", ->capabilities(AdapterFixture)},
      {"metrics", "records ordered measurements and optional histogram exemplars", ->ordered_measurements(AdapterFixture)},
      {"metrics", "copies instrument metadata and measurement attributes", ->copied_metadata(AdapterFixture)},
      {"links", "records initial and late links without changing parents", ->initial_and_late_links(AdapterFixture)},
      {"links", "ignores links added after source settlement", ->late_links(AdapterFixture)},
      {"propagation", "roundtrips parent identity through JSON without retaining the carrier", ->json_roundtrip(AdapterFixture)},
      {"propagation", "absent and unknown carriers produce recorded roots", ->fallback_roots(AdapterFixture)},
      {"propagation", "propagates across fresh adapters and multiple hops", ->(fixture : AdapterFixture) { multiple_hops(fixture, factory) }},
      {"callback lifecycle", "admits once synchronously and preserves the result", ->admits_once(AdapterFixture)},
      {"callback lifecycle", "preserves synchronous and asynchronous rejection values", ->rejections(AdapterFixture)},
      {"status", "uses last explicit status without automatic overwrite", ->explicit_status(AdapterFixture)},
      {"recording", "merges attributes and records ordered events", ->merged_recording(AdapterFixture)},
      {"recording", "makes calls after settlement inert", ->inert_after_settlement(AdapterFixture)},
      {"parentage", "records nested and concurrent child relationships", ->parentage(AdapterFixture)},
    ] of {String, String, AdapterTest}
    tests.map do |(group, name, test)|
      Case.new(group, name, adapter_run(factory, test))
    end
  end

  private def self.adapter_run(factory : AdapterFactory, test : AdapterTest) : Proc(Nil)
    -> do
      fixture = factory.call
      begin
        test.call(fixture)
      ensure
        fixture.close
      end
      nil
    end
  end

  private def self.with_fixture(factory : AdapterFactory, &)
    fixture = factory.call
    begin
      yield fixture
    ensure
      fixture.close
    end
  end

  private def self.check_capabilities(context : TelemetryContext, metrics : Metrics?, propagation : Propagation?) : Nil
    check_same(context.metrics, metrics, "context metrics")
    check_same(context.propagation, propagation, "context propagation")
  end

  private def self.capabilities(fixture : AdapterFixture) : Nil
    metrics = fixture.metrics || fixture.context.metrics
    propagation = fixture.propagation || fixture.context.propagation
    check_capabilities(fixture.context, metrics, propagation)
    settled = nil.as(TelemetrySpan?)
    fixture.context.start_span(options("capabilities")) do |span|
      settled = span
      check_capabilities(span, metrics, propagation)
      span.start_span(options("capabilities.child")) { |child| check_capabilities(child, metrics, propagation) }
      if propagation
        parent = propagation.extract(propagation.inject(span))
        check_capabilities(parent, metrics, propagation)
        parent.start_span(options("capabilities.extracted")) { |child| check_capabilities(child, metrics, propagation) }
      end
    end
    inert = settled || fail("Expected callback span")
    inert.start_span(options("capabilities.inert")) { |child| check_capabilities(child, metrics, propagation) }
  end

  private def self.ordered_measurements(fixture : AdapterFixture) : Nil
    return unless metrics = fixture.metrics
    metrics.counter("bytes", InstrumentOptions.new(description: "Encoded bytes", unit: "By"))
      .add(12, Telemetry.attributes(direction: "out"))
    active = metrics.up_down_counter("active")
    active.add(1)
    active.add(-1)
    histogram = metrics.histogram("duration", InstrumentOptions.new(unit: "ms", boundaries: [1.0, 10.0]))
    fixture.context.start_span(options("measured")) { |span| histogram.record(5, Telemetry.attributes(method: "read"), span) }
    measurements = fixture.recorded_metrics
    check_equal(measurements.map { |measurement| {measurement.kind, measurement.name, measurement.value} }, [
      {MetricKind::Counter, "bytes", 12.0},
      {MetricKind::UpDownCounter, "active", 1.0},
      {MetricKind::UpDownCounter, "active", -1.0},
      {MetricKind::Histogram, "duration", 5.0},
    ], "measurements")
    check_equal(measurements[0].attributes, Telemetry.attributes(direction: "out"), "counter attributes")
    check_equal(measurements[0].description, "Encoded bytes", "counter description")
    check_equal(measurements[0].unit, "By", "counter unit")
    check_equal(measurements[3].boundaries, [1.0, 10.0], "histogram boundaries")
    check_equal(measurements[3].context, find_span(fixture.recorded_spans, "measured").context, "histogram exemplar")
  end

  private def self.copied_metadata(fixture : AdapterFixture) : Nil
    return unless metrics = fixture.metrics
    boundaries = [1.0, 10.0]
    histogram = metrics.histogram("snapshot", InstrumentOptions.new(description: "Original", boundaries: boundaries))
    boundaries << 100.0
    tags = ["original"]
    histogram.record(-1, Attributes{"tags" => tags})
    tags << "changed"
    measurements = fixture.recorded_metrics
    check_equal(measurements.size, 1, "measurement count")
    check_equal(measurements[0].attributes, Telemetry.attributes(tags: ["original"]), "measurement attributes")
    check_equal(measurements[0].boundaries, [1.0, 10.0], "histogram boundaries")
    check_equal(measurements[0].description, "Original", "histogram description")
    check_equal(measurements[0].context, nil, "measurement context")
  end

  private def self.initial_and_late_links(fixture : AdapterFixture) : Nil
    target = fixture.context.start_span(options("target")) { |span| span }
    reasons = ["initial"]
    links = [SpanLink.new(target, Attributes{"reason" => reasons})]
    fixture.context.start_span(options("linked", links: links)) do |span|
      reasons << "mutated"
      span.add_link(SpanLink.new(target, Telemetry.attributes(reason: "late")))
      span.add_link(SpanLink.new(NOOP_TELEMETRY_CONTEXT))
    end
    spans = fixture.recorded_spans
    linked = find_span(spans, "linked")
    target_context = find_span(spans, "target").context
    check_equal(linked.parent_id, nil, "linked parent id")
    check_equal(linked.parent_context, nil, "linked parent context")
    check_equal(linked.links, [
      RecordedLink.new(target_context, Telemetry.attributes(reason: ["initial"])),
      RecordedLink.new(target_context, Telemetry.attributes(reason: "late")),
    ], "links")
  end

  private def self.late_links(fixture : AdapterFixture) : Nil
    source = fixture.context.start_span(options("link-source")) { |span| span }
    source.add_link(SpanLink.new(source))
    check_equal(find_span(fixture.recorded_spans, "link-source").links, [] of RecordedLink, "late links")
  end

  private def self.json_roundtrip(fixture : AdapterFixture) : Nil
    return unless propagation = fixture.propagation
    fixture.context.start_span(options("sender")) do |span|
      carrier = propagation.inject(span) || fail("Expected a carrier")
      wire = roundtrip(carrier)
      parent = propagation.extract(wire)
      wire.each_key { |key| wire[key] = "mutated" }
      parent.start_span(options("receiver")) { 42 }
      check_equal(propagation.inject(span), carrier, "reinjected carrier")
    end
    spans = fixture.recorded_spans
    check_equal(find_span(spans, "receiver").parent_context, find_span(spans, "sender").context, "receiver parent")
  end

  private def self.fallback_roots(fixture : AdapterFixture) : Nil
    return unless propagation = fixture.propagation
    check_equal(propagation.inject(NOOP_TELEMETRY_CONTEXT), nil, "no-op carrier")
    [nil, Carrier.new, Carrier{"unknown" => "format"}].each_with_index do |carrier, index|
      result = propagation.extract(carrier).start_span(options("fallback-#{index}")) { 42 }
      check_equal(result, 42, "fallback result")
    end
    fixture.recorded_spans.each { |span| check_equal(span.parent_context, nil, "fallback parent") }
  end

  private def self.multiple_hops(fixture : AdapterFixture, factory : AdapterFactory) : Nil
    return unless propagation = fixture.propagation
    with_fixture(factory) do |receiver|
      with_fixture(factory) do |worker|
        receiver_propagation = receiver.propagation || fail("Expected propagation on each fixture")
        worker_propagation = worker.propagation || fail("Expected propagation on each fixture")
        sender_carrier = fixture.context.start_span(options("sender")) { |span| propagation.inject(span) }
        sender_carrier || fail("Expected a sender carrier")
        receiver_carrier = receiver_propagation.extract(roundtrip(sender_carrier))
          .start_span(options("receiver")) { |span| receiver_propagation.inject(span) }
        receiver_carrier || fail("Expected a receiver carrier")
        worker_propagation.extract(roundtrip(receiver_carrier)).start_span(options("worker")) { }
        check_equal(find_span(receiver.recorded_spans, "receiver").parent_context, sender_carrier, "receiver parent")
        check_equal(find_span(worker.recorded_spans, "worker").parent_context, receiver_carrier, "worker parent")
      end
    end
  end

  private def self.admits_once(fixture : AdapterFixture) : Nil
    calls = 0
    expected = {"value" => 42}
    result = fixture.context.start_span(options("success")) do
      calls += 1
      expected
    end
    check_equal(calls, 1, "admissions")
    check_same(result, expected, "callback result")
    span = find_span(fixture.recorded_spans, "success")
    check_equal(span.status, SpanStatus.ok, "status")
    check_equal(span.settled, true, "settled")
  end

  private def self.rejections(fixture : AdapterFixture) : Nil
    sync_error = Exception.new("sync")
    rejects_with_same(sync_error) do
      fixture.context.start_span(options("sync-error")) { raise sync_error }
    end
    async_error = ConformanceRejection.new("async")
    rejects_with_same(async_error) do
      fixture.context.start_span(options("async-error")) do
        Fiber.yield
        raise async_error
      end
    end
    spans = fixture.recorded_spans
    %w[sync-error async-error].each { |name| check(find_span(spans, name).status.error?, "#{name} status") }
  end

  private def self.explicit_status(fixture : AdapterFixture) : Nil
    fixture.context.start_span(options("last-status")) do |span|
      span.status = SpanStatus.error("Expected", "first")
      span.status = SpanStatus.ok
    end
    thrown = Exception.new("after explicit status")
    rejects_with_same(thrown) do
      fixture.context.start_span(options("explicit-before-throw")) do |span|
        span.status = SpanStatus.ok
        raise thrown
      end
    end
    rejected = Exception.new("after async explicit status")
    rejects_with_same(rejected) do
      fixture.context.start_span(options("explicit-before-rejection")) do |span|
        span.status = SpanStatus.error("Expected", "async failure")
        Fiber.yield
        raise rejected
      end
    end
    fixture.context.start_span(options("expected-failure")) do |span|
      span.status = SpanStatus.error("Expected", "returned failure")
      {ok: false}
    end
    spans = fixture.recorded_spans
    check_equal(find_span(spans, "last-status").status, SpanStatus.ok, "last status")
    check_equal(find_span(spans, "explicit-before-throw").status, SpanStatus.ok, "status before throw")
    check_equal(find_span(spans, "explicit-before-rejection").status, SpanStatus.error("Expected", "async failure"), "status before rejection")
    check_equal(find_span(spans, "expected-failure").status, SpanStatus.error("Expected", "returned failure"), "returned failure")
  end

  private def self.merged_recording(fixture : AdapterFixture) : Nil
    fixture.context.start_span(options("recording", Telemetry.attributes(start: "value", overwrite: "start"))) do |span|
      span.merge_attributes(Telemetry.attributes(count: 1, overwrite: "middle"))
      span.merge_attributes(Telemetry.attributes(overwrite: "end"))
      span.add_event("first", Telemetry.attributes(index: 1))
      span.add_event("second", Telemetry.attributes(index: 2))
    end
    span = find_span(fixture.recorded_spans, "recording")
    check_equal(span.attributes, Telemetry.attributes(start: "value", overwrite: "end", count: 1), "attributes")
    check_equal(span.events, [
      RecordedEvent.new("first", Telemetry.attributes(index: 1)),
      RecordedEvent.new("second", Telemetry.attributes(index: 2)),
    ], "events")
  end

  private def self.inert_after_settlement(fixture : AdapterFixture) : Nil
    settled = fixture.context.start_span(options("settled", Telemetry.attributes(value: "initial"))) { |span| span }
    settled.merge_attributes(Telemetry.attributes(value: "late"))
    settled.add_event("late", Telemetry.attributes(value: true))
    settled.status = SpanStatus.error
    admitted = false
    result = settled.start_span(options("late-child")) do
      admitted = true
      7
    end
    check_equal(admitted, true, "late child admitted")
    check_equal(result, 7, "late child result")
    spans = fixture.recorded_spans
    check_equal(spans.size, 1, "recorded spans")
    check_equal(spans[0].attributes, Telemetry.attributes(value: "initial"), "attributes")
    check_equal(spans[0].events, [] of RecordedEvent, "events")
    check_equal(spans[0].status, SpanStatus.ok, "status")
  end

  private def self.parentage(fixture : AdapterFixture) : Nil
    gate = Channel(Nil).new
    done = Channel(Nil).new(1)
    fixture.context.start_span(options("parent")) do |parent|
      spawn do
        parent.start_span(options("first-child")) { gate.receive }
      ensure
        done.send(nil)
      end
      Fiber.yield
      check_equal(parent.start_span(options("second-child")) { "done" }, "done", "second child result")
      gate.send(nil)
      done.receive
    end
    spans = fixture.recorded_spans
    parent = find_span(spans, "parent")
    first = find_span(spans, "first-child")
    second = find_span(spans, "second-child")
    check_equal(parent.parent_id, nil, "parent parent id")
    check_equal(first.parent_id, parent.id, "first child parent")
    check_equal(second.parent_id, parent.id, "second child parent")
    ordered = {second.end_sequence, first.end_sequence, parent.end_sequence}
    first_end = ordered[1] || fail("Expected end sequences")
    check((ordered[0] || fail("Expected end sequences")) < first_end, "second child settles first")
    check(first_end < (ordered[2] || fail("Expected end sequences")), "first child settles before its parent")
  end
end
