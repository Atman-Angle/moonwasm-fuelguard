///|
pub fn decode_wasm(bytes : Bytes) -> Result[@lib.Module, InstrumentError] {
  match @binary.decode_module(bytes) {
    Ok(wasm_module) => Ok(wasm_module)
    Err(error) => Err(DecodeFailed(Show::to_string(error)))
  }
}

///|
pub fn validate_wasm(
  wasm_module : @lib.Module,
  stage : String,
) -> Result[Unit, InstrumentError] {
  match @validate.validate_module(wasm_module) {
    Ok(_) => Ok(())
    Err(error) => Err(ValidationFailed(stage, Show::to_string(error)))
  }
}

///|
pub fn encode_wasm(
  wasm_module : @lib.Module,
  stage~ : (String) -> Unit = fn(_) { () },
) -> Result[Bytes, InstrumentError] {
  stage("validate_before_encode")
  match validate_wasm(wasm_module, "before encode") {
    Ok(_) => {
      stage("encode")
      match @binary.encode_module(wasm_module) {
        Ok(bytes) => Ok(bytes)
        Err(error) => Err(EncodeFailed(Show::to_string(error)))
      }
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

///|
pub fn decode_input(
  bytes : Bytes,
  profile : InputProfile,
  stage~ : (String) -> Unit = fn(_) { () },
) -> Result[@lib.Module, InstrumentError] {
  stage("preflight")
  if profile is ProductionV1 || profile is FuelGrowthV1 {
    match preflight_production_wasm(bytes) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  stage("decode")
  decode_wasm(bytes)
}
