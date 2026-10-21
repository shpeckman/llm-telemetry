# spec/spec_helper.cr
require "spec"
require "../src/llm-telemetry"

include LLM::Telemetry

def tick : Nil
  sleep 1.millisecond
end
