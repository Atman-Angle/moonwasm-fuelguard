///|
pub enum InstrumentError {
  InvalidFuelBudget(Int32)
  InvalidMemoryLimit(Int32)
  InvalidTableLimit(Int32)
  DecodeFailed(String)
  EncodeFailed(String)
  ValidationFailed(String, String)
  UnsupportedFeature(String)
  ExportNameConflict(String)
  InvalidTrapCode(Int32)
  NotImplemented(String)
}

///|
pub fn InstrumentError::message(self : Self) -> String {
  match self {
    InvalidFuelBudget(budget) =>
      "fuel budget must be in 1..=2147483647, got \{budget}"
    InvalidMemoryLimit(limit) =>
      "memory limit must be in 0..=65536 pages, got \{limit}"
    InvalidTableLimit(limit) => "table limit must be non-negative, got \{limit}"
    DecodeFailed(reason) => "failed to decode wasm: \{reason}"
    EncodeFailed(reason) => "failed to encode wasm: \{reason}"
    ValidationFailed(stage, reason) =>
      "wasm validation failed at \{stage}: \{reason}"
    UnsupportedFeature(feature) => "unsupported input: \{feature}"
    ExportNameConflict(name) => "export name already exists: \{name}"
    InvalidTrapCode(code) => "invalid trap code: \{code}"
    NotImplemented(component) => "\{component} is not implemented yet"
  }
}
