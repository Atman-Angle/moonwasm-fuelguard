///|
pub struct Pipeline {
  passes : Array[&Pass]
}

///|
pub fn Pipeline::new(passes : Array[&Pass]) -> Self {
  { passes, }
}

///|
pub fn Pipeline::builtin(config : InstrumentConfig) -> Self {
  Pipeline::new([
    FuelPass::new(config.fuel()) as &Pass,
    GuardPass::new(config.guard_config()) as &Pass,
  ])
}

///|
pub fn Pipeline::run(
  self : Self,
  wasm_module : @lib.Module,
) -> Result[PassResult, InstrumentError] {
  match validate_wasm(wasm_module, "input") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match check_input(wasm_module) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let mut current = wasm_module
  let notes : Array[String] = []
  for pass in self.passes {
    let result = match pass.apply(current) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    let stage = result.pass_name()
    match validate_wasm(result.output(), stage) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    notes.append(result.notes())
    current = result.output()
  }
  match validate_wasm(current, "before encode") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  Ok(PassResult::new("pipeline", current, notes~))
}
