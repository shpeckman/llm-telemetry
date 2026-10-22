# src/llm-telemetry/testing/store_conformance.cr
module LLM::Telemetry::Testing
  alias StoreTest = StoreFactory -> Nil

  SPAN_ID_FORMAT = /^[0-9a-f-]{36}:[1-9][0-9]*$/

  def self.store_conformance(factory : StoreFactory) : Array(Case)
    tests = [
      {"returns only settled traces, complete span snapshots, and detached results", ->settled_traces(StoreFactory)},
      {"filters by first-span name and start, any error, and all attributes on one span", ->filters(StoreFactory)},
      {"pages complete traces without duplicates when trace starts tie", ->paging(StoreFactory)},
      {"inherits remote trace IDs and preserves remote parents and cross-trace links", ->remote_parents(StoreFactory)},
      {"accepts external string identities without imposing an ID format", ->external_identities(StoreFactory)},
      {"queries metric names, inclusive interval bounds, typed attribute equality, and detached values", ->metric_queries(StoreFactory)},
    ] of {String, StoreTest}
    tests.map { |(name, test)| Case.new("store", name, store_run(factory, test)) }
  end

  private def self.store_run(factory : StoreFactory, test : StoreTest) : Proc(Nil)
    -> { test.call(factory); nil }
  end

  private def self.with_store(factory : StoreFactory, clock : ManualClock, &)
    fixture = factory.call(clock)
    begin
      yield fixture
    ensure
      fixture.close
    end
  end

  private def self.query_values(**values) : Hash(String, QueryValue)
    result = {} of String => QueryValue
    values.each { |key, value| result[key.to_s] = value.is_a?(Int) ? value.to_i64 : value }
    result
  end

  private def self.first_names(store : TelemetryStore, query : TraceQuery) : Array(String?)
    store.find_traces(query).traces.map(&.spans.first?.try(&.name))
  end

  private def self.settled_traces(factory : StoreFactory) : Nil
    clock = ManualClock.new(20_000_i64)
    with_store(factory, clock) do |fixture|
      gate = Channel(Nil).new
      done = Channel(Nil).new(1)
      spawn do
        fixture.context.start_span(options("root", Telemetry.attributes(tags: ["original"]))) do |root|
          root.add_event("event", Telemetry.attributes(tags: ["original"]))
          gate.receive
          root.start_span(options("child")) { }
        end
      ensure
        done.send(nil)
      end
      Fiber.yield
      fixture.flush
      check_equal(fixture.store.find_traces.traces, [] of StoredTrace, "unsettled traces")
      check_equal(fixture.store.get_trace("missing"), nil, "missing trace")
      gate.send(nil)
      done.receive
      fixture.flush
      trace = fixture.store.find_traces.traces.first? || fail("Expected a trace")
      root = trace.spans.find(&.name.==("root")) || fail("Expected the root span")
      child = trace.spans.find(&.name.==("child")) || fail("Expected the child span")
      check(SPAN_ID_FORMAT.matches?(root.id), "root id format: #{root.id}")
      check_equal(root.trace_id, root.id, "root trace id")
      check_equal(root.parent_id, nil, "root parent")
      check_equal(child.parent_id, root.id, "child parent")
      check_equal(child.trace_id, root.trace_id, "child trace id")
      check_equal(root.started_ms, 20_000.0, "root start")
      check(root.ended_ms >= root.started_ms, "root ends after it starts")
      check(root.events[0].time_ms >= 0, "event time")
      root.attributes["tags"] = ["changed"]
      root.events[0].attributes["tags"] = ["changed"]
      fresh = fixture.store.get_trace(trace.trace_id).try(&.spans.find(&.id.==(root.id))) || fail("Expected a fresh root")
      check_equal(fresh.attributes["tags"]?, ["original"], "detached attributes")
      check_equal(fresh.events[0].attributes["tags"]?, ["original"], "detached event attributes")
    end
  end

  private def self.filters(factory : StoreFactory) : Nil
    clock = ManualClock.new(10_000_i64)
    with_store(factory, clock) do |fixture|
      fixture.context.start_span(options("old")) do |root|
        clock.now_ms = 30_000
        root.start_span(options("recent-child", Telemetry.attributes(left: 1))) { }
        root.start_span(options("split", Telemetry.attributes(right: 2))) { }
      end
      clock.now_ms = 20_000
      fixture.context.start_span(options("wanted")) do |root|
        clock.now_ms = 20_001
        attributes = Attributes{"left" => 1_i64, "right" => 2_i64, "valid" => true, %(odd."key") => "value"}
        root.start_span(options("failure", attributes)) { |child| child.status = SpanStatus.error }
      end
      clock.now_ms = 40_000
      fixture.context.start_span(options("new", Telemetry.attributes(valid: 1))) { }
      fixture.flush
      store = fixture.store
      wanted = TraceQuery.new(name: "wanted", attributes: query_values(left: 1, right: 2), errors: true,
        start_min: 20_000.0, start_max: 20_000.0)
      check_equal(first_names(store, wanted), ["wanted"], "combined filters")
      check_equal(first_names(store, TraceQuery.new(name: "failure")), [] of String?, "name of a non-first span")
      check_equal(first_names(store, TraceQuery.new(attributes: query_values(left: 1, right: 2))), ["wanted"], "attributes on one span")
      odd = {"valid" => true.as(QueryValue), %(odd."key") => "value".as(QueryValue)}
      check_equal(first_names(store, TraceQuery.new(attributes: odd)), ["wanted"], "boolean and quoted key attributes")
      check_equal(first_names(store, TraceQuery.new(attributes: query_values(valid: 1))), ["new"], "numeric attribute")
      check_equal(first_names(store, TraceQuery.new(errors: true)), ["wanted"], "errors")
      check_equal(first_names(store, TraceQuery.new(start_min: 20_000.0)), ["new", "wanted"], "start minimum")
      check_equal(first_names(store, TraceQuery.new(start_max: 10_000.0)), ["old"], "start maximum")
    end
  end

  private def self.paging(factory : StoreFactory) : Nil
    clock = ManualClock.new(20_000_i64)
    with_store(factory, clock) do |fixture|
      25.times do |index|
        clock.now_ms = 20_000
        fixture.context.start_span(options("root", Telemetry.attributes(index: index))) do |root|
          clock.now_ms = 20_001
          root.start_span(options("child")) { }
        end
      end
      fixture.flush
      store = fixture.store
      first = store.find_traces
      check_equal(first.traces.size, 20, "first page size")
      check(!first.cursor.nil?, "first page cursor")
      rest = store.find_traces(TraceQuery.new(cursor: first.cursor))
      check_equal(rest.traces.size, 5, "second page size")
      check_equal(rest.cursor, nil, "second page cursor")
      all = store.find_traces(TraceQuery.new(limit: 100)).traces
      check_equal(first.traces + rest.traces, all, "pages")
      check(all.all?(&.spans.size.==(2)), "complete traces")
      ids = [] of String
      cursor = nil.as(String?)
      loop do
        page = store.find_traces(TraceQuery.new(name: "root", limit: 3, cursor: cursor))
        ids.concat(page.traces.map(&.trace_id))
        break unless cursor = page.cursor
      end
      check_equal(ids, all.map(&.trace_id), "small pages")
    end
  end

  private def self.remote_parents(factory : StoreFactory) : Nil
    clock = ManualClock.new(20_000_i64)
    with_store(factory, clock) do |sender|
      with_store(factory, clock) do |receiver|
        carrier = sender.context.start_span(options("sender")) { |span| sender.propagation.inject(span) }
        carrier || fail("Expected a carrier")
        sender.flush
        sent = sender.store.find_traces.traces.first? || fail("Expected the sent trace")
        sent_span = sent.spans[0]
        remote = receiver.propagation.extract(roundtrip(carrier))
        remote.start_span(options("receiver")) { }
        links = [SpanLink.new(remote, Telemetry.attributes(reason: "background"))]
        receiver.context.start_span(options("linked", links: links)) { }
        receiver.flush
        continued = receiver.store.get_trace(sent.trace_id) || fail("Expected the continued trace")
        check_equal(continued.spans.size, 1, "continued spans")
        span = continued.spans[0]
        check_equal(span.trace_id, sent.trace_id, "continued trace id")
        check_equal(span.parent_id, sent_span.id, "continued parent")
        check_equal(span.name, "receiver", "continued name")
        check(span.id != sent_span.id, "continued span has its own id")
        linked = receiver.store.find_traces(TraceQuery.new(name: "linked")).traces.first? || fail("Expected the linked trace")
        check(linked.trace_id != sent.trace_id, "linked trace is a new trace")
        check_equal(linked.spans[0].links, [StoredLink.new(sent.trace_id, sent_span.id, Telemetry.attributes(reason: "background"))], "links")
        carrier.each_key do |key|
          incomplete = carrier.dup
          incomplete.delete(key)
          receiver.propagation.extract(incomplete).start_span(options("fallback")) { }
        end
        receiver.flush
        fallbacks = receiver.store.find_traces(TraceQuery.new(name: "fallback")).traces
        check_equal(fallbacks.size, carrier.size, "fallback traces")
        check(fallbacks.all? { |trace| trace.spans[0].parent_id.nil? && trace.trace_id == trace.spans[0].id }, "fallbacks are roots")
      end
    end
  end

  private def self.external_identities(factory : StoreFactory) : Nil
    with_store(factory, ManualClock.new(20_000_i64)) do |fixture|
      carrier = fixture.context.start_span(options("source")) { |span| fixture.propagation.inject(span) }
      carrier || fail("Expected a carrier")
      external = carrier.to_h { |key, _| {key, "external-#{key}"} }
      parent = fixture.propagation.extract(external)
      check_equal(fixture.propagation.inject(parent), external, "reinjected external carrier")
      parent.start_span(options("continued")) { }
      fixture.flush
      trace = fixture.store.find_traces(TraceQuery.new(name: "continued")).traces.first? || fail("Expected the continued trace")
      check(trace.trace_id.starts_with?("external-"), "external trace id")
      check(trace.spans[0].parent_id.try(&.starts_with?("external-")) == true, "external parent id")
    end
  end

  private def self.metric_queries(factory : StoreFactory) : Nil
    clock = ManualClock.new(20_001_i64)
    with_store(factory, clock) do |fixture|
      counter = fixture.metrics.counter("hits", InstrumentOptions.new(unit: "By"))
      counter.add(2, Telemetry.attributes(method: "read", valid: true))
      counter.add(3, Telemetry.attributes(valid: true, method: "read"))
      counter.add(11, Telemetry.attributes(method: "write", valid: 1))
      fixture.metrics.counter("other").add(100, Telemetry.attributes(method: "read", valid: true))
      clock.now_ms = 30_001
      counter.add(7, Telemetry.attributes(method: "read", valid: true))
      clock.now_ms = 40_001
      fixture.flush
      store = fixture.store
      query = MetricQuery.new("hits", start_min: 20_000_i64, start_max: 20_000_i64,
        attributes: {"method" => "read".as(QueryValue), "valid" => true.as(QueryValue)})
      rows = store.find_metrics(query)
      check_equal(rows.sum(&.count), 2_i64, "count")
      check_equal(rows.sum(&.sum), 5.0, "sum")
      check_equal(rows.min_of?(&.min), 2.0, "min")
      check_equal(rows.max_of?(&.max), 3.0, "max")
      check(rows.all? { |row| row.kind.counter? && row.unit == "By" && row.interval_ms == 20_000 }, "row identity")
      rows[0].attributes["method"] = "changed"
      check_equal(store.find_metrics(query).first?.try(&.attributes["method"]?), "read", "detached attributes")
      check_equal(store.find_metrics(MetricQuery.new("missing")), [] of StoredMetric, "missing metric")
      check_equal(store.find_metrics(MetricQuery.new("hits", attributes: query_values(valid: 1))).sum(&.sum), 11.0, "numeric attribute")
      check_equal(store.find_metrics(MetricQuery.new("hits", start_min: 30_000_i64)).sum(&.sum), 7.0, "interval minimum")
    end
  end
end
