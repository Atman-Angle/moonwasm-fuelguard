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
impl Pass for FuelPass with fn apply(self, wasm_module) {
  apply_fuel(self.config, wasm_module)
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
impl Pass for GuardPass with fn apply(self, wasm_module) {
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
