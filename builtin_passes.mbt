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
impl Pass for GuardPass with fn apply(_, _) {
  Err(NotImplemented("GuardPass"))
}
