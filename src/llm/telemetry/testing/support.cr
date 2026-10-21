# src/llm/telemetry/testing/support.cr
module LLM::Telemetry::Testing
  class ConformanceFailure < Exception
  end

  class ConformanceRejection < Exception
  end

  struct Case
    getter group : String
    getter name : String

    def initialize(@group : String, @name : String, @body : Proc(Nil)); end

    def run : Nil
      @body.call
    end
  end

  abstract class AdapterFixture
    abstract def context : TelemetryContext
    abstract def recorded_spans : Array(RecordedSpan)

    def propagation : Propagation?
      nil
    end

    def metrics : Metrics?
      nil
    end

    def recorded_metrics : Array(RecordedMeasurement)
      raise ConformanceFailure.new("Metrics fixtures require a normalized measurement reader")
    end

    def close : Nil
    end
  end

  abstract class StoreFixture
    abstract def context : TelemetryContext
    abstract def store : TelemetryStore

    def flush : Nil
    end

    def close : Nil
    end

    def metrics : Metrics
      context.metrics || raise ConformanceFailure.new("Store fixtures require metrics on their context")
    end

    def propagation : Propagation
      context.propagation || raise ConformanceFailure.new("Store fixtures require propagation on their context")
    end
  end

  alias AdapterFactory = -> AdapterFixture
  alias StoreFactory = ManualClock -> StoreFixture

  class ManualClock < Clock
    property now_ms : Int64
    property elapsed_ms : Float64

    class Timer
      getter interval_ms : Int64
      getter callback : Proc(Nil)
      property due_ms : Int64 = 0_i64
      property? active : Bool = true

      def initialize(@interval_ms : Int64, @callback : Proc(Nil)); end
    end

    @timers = [] of Timer
    @ticks = 0_i64

    def initialize(@now_ms : Int64 = 0_i64, @elapsed_ms : Float64 = 0.0); end

    def every(interval : Time::Span, &callback : ->) : Proc(Nil)
      timer = Timer.new(interval.total_milliseconds.to_i64.clamp(1_i64, Int64::MAX), callback)
      timer.due_ms = @ticks + timer.interval_ms
      @timers << timer
      canceller(timer)
    end

    def advance(milliseconds : Int) : Nil
      target = @ticks + milliseconds
      while timer = next_due(target)
        step(timer.due_ms)
        timer.due_ms += timer.interval_ms
        timer.callback.call
      end
      step(target)
    end

    def timers : Int32
      @timers.count(&.active?)
    end

    private def step(tick : Int64) : Nil
      delta = tick - @ticks
      @ticks = tick
      @now_ms += delta
      @elapsed_ms += delta
    end

    private def next_due(target : Int64) : Timer?
      @timers.select { |timer| timer.active? && timer.due_ms <= target }.min_by?(&.due_ms)
    end

    private def canceller(timer : Timer) : Proc(Nil)
      -> { timer.active = false; @timers.delete(timer); nil }
    end
  end

  def self.fail(message : String) : NoReturn
    raise ConformanceFailure.new(message)
  end

  def self.check(condition : Bool, message : String) : Nil
    fail(message) unless condition
  end

  def self.check_equal(actual, expected, what : String) : Nil
    fail("#{what}: expected #{expected.inspect}, got #{actual.inspect}") unless actual == expected
  end

  def self.check_same(actual, expected, what : String) : Nil
    fail("#{what}: expected the identical object") unless identical?(actual, expected)
  end

  private def self.identical?(actual, expected) : Bool
    if actual.nil?
      expected.nil?
    elsif expected.nil?
      false
    else
      actual.same?(expected)
    end
  end

  def self.find_span(spans : Array(RecordedSpan), name : String) : RecordedSpan
    spans.find(&.name.==(name)) || fail("Expected recorded span #{name}")
  end

  def self.rejects_with_same(expected : Exception, &) : Nil
    begin
      yield
    rescue error
      check(error.same?(expected), "Expected the identical rejection, got #{error.inspect}")
      return
    end
    fail("Expected operation to reject")
  end

  def self.options(name : String, attributes : Attributes? = nil, links : Array(SpanLink)? = nil) : SpanOptions
    SpanOptions.new(name, attributes, links)
  end

  def self.roundtrip(carrier : Carrier) : Carrier
    Carrier.from_json(carrier.to_json)
  end
end
