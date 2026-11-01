///|
pub fn decode_wasm(bytes : Bytes) -> Result[@lib.Module, InstrumentError] {
  match @binary.decode_module(bytes) {
    Ok(wasm_module) => Ok(wasm_module)
    Err(error) => Err(DecodeFailed(error.to_string()))
  }
}

///|
pub fn validate_wasm(
  wasm_module : @lib.Module,
  stage : String,
) -> Result[Unit, InstrumentError] {
  match @validate.validate_module(wasm_module) {
    Ok(_) => Ok(())
    Err(error) => Err(ValidationFailed(stage, error.to_string()))
  }
}

///|
pub fn encode_wasm(wasm_module : @lib.Module) -> Result[Bytes, InstrumentError] {
  match validate_wasm(wasm_module, "before encode") {
    Ok(_) =>
      match @binary.encode_module(wasm_module) {
        Ok(bytes) => Ok(bytes)
        Err(error) => Err(EncodeFailed(error.to_string()))
      }
    Err(error) => Err(error)
  }
}

///|
pub fn decode_checked(bytes : Bytes) -> Result[@lib.Module, InstrumentError] {
  match decode_wasm(bytes) {
    Ok(wasm_module) =>
      match validate_wasm(wasm_module, "input") {
        Ok(_) =>
          match check_input(wasm_module) {
            Ok(_) => Ok(wasm_module)
            Err(error) => Err(error)
          }
        Err(error) => Err(error)
      }
    Err(error) => Err(error)
  }
}
