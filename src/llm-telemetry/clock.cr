# src/llm-telemetry/clock.cr
module LLM::Telemetry
  abstract class Clock
    abstract def now_ms : Int64
    abstract def elapsed_ms : Float64
    abstract def every(interval : Time::Span, &callback : ->) : Proc(Nil)
  end

  class SystemClock < Clock
    @origin = Time.instant

    def now_ms : Int64
      Time.utc.to_unix_ms
    end

    def elapsed_ms : Float64
      (Time.instant - @origin).total_milliseconds
    end

    def every(interval : Time::Span, &callback : ->) : Proc(Nil)
      stop = Channel(Nil).new
      spawn { tick(interval, stop, callback) }
      stopper(stop)
    end

    private def tick(interval : Time::Span, stop : Channel(Nil), callback : ->) : Nil
      loop do
        select
        when stop.receive?
          return
        when timeout(interval)
          callback.call
        end
      end
    end

    private def stopper(stop : Channel(Nil)) : Proc(Nil)
      -> { stop.close; nil }
    end
  end

  SYSTEM_CLOCK = SystemClock.new
end
