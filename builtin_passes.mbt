///|
pub struct FuelPass {
  config : FuelConfig
}

///|
pub fn FuelPass::new(config : FuelConfig) -> Self {
  { config, }
}

///|
pub fn FuelPass::config(self : Self) -> FuelConfig {
  self.config
}

///|
pub impl Pass for FuelPass with fn apply(self, wasm_module) {
  let semantic = analyze_semantic(wasm_module)
  let plan = plan_fuel(semantic, None, wasm_module)
  match plan_growth(wasm_module, semantic, None, plan) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match emit_fuel(self.config, wasm_module, plan, semantic.sites.length()) {
    Ok((state, note)) =>
      Ok(PassResult::new("FuelPass", state.wasm_module, notes=[note]))
    Err(error) => Err(error)
  }
}

///|
pub struct GuardPass {
  config : GuardConfig
}

///|
pub fn GuardPass::new(config : GuardConfig) -> Self {
  { config, }
}

///|
pub fn GuardPass::config(self : Self) -> GuardConfig {
  self.config
}

///|
pub impl Pass for GuardPass with fn apply(self, wasm_module) {
  let config = self.config
  if config.max_memory_pages() is None &&
    config.max_table_elements() is None &&
    config.allowed_imports().length() == 0 {
    Ok(
      PassResult::new("GuardPass", wasm_module, notes=[
        "guard: disabled (no memory, table, or import limits configured)",
      ]),
    )
  } else {
    Err(NotImplemented("GuardPass"))
  }
}

///|
pub extend FuelPass with Pass::{apply}

///|
pub extend GuardPass with Pass::{apply}
