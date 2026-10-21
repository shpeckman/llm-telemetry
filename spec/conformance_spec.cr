# spec/conformance_spec.cr
require "./spec_helper"
require "../src/llm-telemetry/testing"

class MemoryAdapterFixture < LLM::Telemetry::Testing::AdapterFixture
  getter context : LLM::Telemetry::InMemoryTelemetryContext = LLM::Telemetry::InMemoryTelemetryContext.new

  def propagation : LLM::Telemetry::Propagation?
    context
  end

  def metrics : LLM::Telemetry::Metrics?
    context
  end

  def recorded_metrics : Array(LLM::Telemetry::RecordedMeasurement)
    context.recorded_metrics
  end

  def recorded_spans : Array(LLM::Telemetry::RecordedSpan)
    context.recorded_spans
  end
end

class MemoryStoreFixture < LLM::Telemetry::Testing::StoreFixture
  getter context : LLM::Telemetry::InMemoryTelemetryContext

  def initialize(clock : LLM::Telemetry::Clock)
    @context = LLM::Telemetry::InMemoryTelemetryContext.new(clock)
  end

  def store : LLM::Telemetry::TelemetryStore
    context
  end
end

describe "InMemoryTelemetryContext conformance" do
  LLM::Telemetry::Testing.adapter_conformance(-> { MemoryAdapterFixture.new.as(LLM::Telemetry::Testing::AdapterFixture) }).each do |test|
    it("#{test.group}: #{test.name}") { test.run }
  end
end

describe "in-memory telemetry store conformance" do
  factory = ->(clock : LLM::Telemetry::Testing::ManualClock) { MemoryStoreFixture.new(clock).as(LLM::Telemetry::Testing::StoreFixture) }
  LLM::Telemetry::Testing.store_conformance(factory).each do |test|
    it(test.name) { test.run }
  end
end

describe LLM::Telemetry::Testing::ManualClock do
  it "fires interval timers while advancing and stops cancelled timers" do
    clock = LLM::Telemetry::Testing::ManualClock.new(1_000_i64)
    fired = [] of Int64
    stop = clock.every(1.second) { fired << clock.now_ms }
    clock.advance(2_500)
    fired.should eq [2_000_i64, 3_000_i64]
    clock.now_ms.should eq 3_500
    clock.elapsed_ms.should eq 2_500.0
    stop.call
    clock.advance(5_000)
    fired.size.should eq 2
    clock.timers.should eq 0
  end

  it "schedules timers on its own ticks, independent of the wall time it is set to" do
    clock = LLM::Telemetry::Testing::ManualClock.new(20_001_i64)
    fired = [] of Int64
    clock.every(1.second) { fired << clock.now_ms }
    clock.advance(1_000)
    clock.now_ms = 50_001
    clock.advance(1_000)
    fired.should eq [21_001_i64, 51_001_i64]
  end
end

describe LLM::Telemetry::SystemClock do
  it "runs interval callbacks until stopped" do
    calls = Channel(Nil).new(8)
    stop = LLM::Telemetry::SYSTEM_CLOCK.every(5.milliseconds) { calls.send(nil) }
    calls.receive
    calls.receive
    stop.call
    LLM::Telemetry::SYSTEM_CLOCK.elapsed_ms.should be > 0
  end
end
