///|
pub enum InstrumentError {
  InvalidFuelBudget(Int64)
  InvalidMemoryLimit(Int32)
  InvalidTableLimit(Int32)
  ImportNotAllowed(String, String)
  InputLimitExceeded(String, Int64, Int32)
  InitialResourceLimit(String, UInt32, Int32)
  DecodeFailed(String)
  EncodeFailed(String)
  ValidationFailed(String, String)
  UnsupportedFeature(String)
  ExportNameConflict(String)
  InvalidStackLimits(Int64, Int64)
  StackAnalysisFailed(String)
  PipelineAuditFailed(String)
  InvalidTrapCode(Int32)
  NotImplemented(String)
}

///|
pub fn InstrumentError::message(self : Self) -> String {
  match self {
    InvalidFuelBudget(budget) =>
      "fuel budget must be in 1..=9223372036854775807, got \{budget}"
    InvalidMemoryLimit(limit) =>
      "memory limit must be in 0..=65536 pages, got \{limit}"
    InvalidTableLimit(limit) =>
      "table limit must be in 0..=65536 elements, got \{limit}"
    ImportNotAllowed(mod_name, name) =>
      "import not allowed: module=\{mod_name}, name=\{name}"
    InputLimitExceeded(label, actual, limit) =>
      "\{label} \{actual} exceeds input limit \{limit}"
    InitialResourceLimit(resource, initial, limit) =>
      "initial \{resource} \{initial} exceeds configured limit \{limit}"
    DecodeFailed(reason) => "failed to decode wasm: \{reason}"
    EncodeFailed(reason) => "failed to encode wasm: \{reason}"
    ValidationFailed(stage, reason) =>
      "wasm validation failed at \{stage}: \{reason}"
    UnsupportedFeature(feature) => "unsupported input: \{feature}"
    ExportNameConflict(name) => "export name already exists: \{name}"
    InvalidStackLimits(units, depth) =>
      "--max-stack-units and --max-call-depth must be positive 31-bit integers in 1..=\{MAX_PACKED_STACK_COUNTER} (units=\{units}, depth=\{depth})"
    StackAnalysisFailed(reason) => "stack audit failed: \{reason}"
    PipelineAuditFailed(reason) => "pipeline audit failed: \{reason}"
    InvalidTrapCode(code) => "invalid trap code: \{code}"
    NotImplemented(component) => "\{component} is not implemented yet"
  }
}
