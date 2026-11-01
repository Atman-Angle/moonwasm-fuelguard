///|
const MAX_FUEL : Int32 = 2_147_483_647

///|
const MAX_MEMORY_PAGES : Int32 = 65_536

///|
pub struct FuelConfig {
  budget : Int32
}

///|
pub fn FuelConfig::new(budget : Int32) -> Result[Self, InstrumentError] {
  if budget <= 0 || budget > MAX_FUEL {
    Err(InvalidFuelBudget(budget))
  } else {
    Ok({ budget, })
  }
}

///|
pub fn FuelConfig::budget(self : Self) -> Int32 {
  self.budget
}

///|
pub struct GuardConfig {
  max_memory_pages : Int32?
  max_table_elements : Int32?
  allowed_imports : Array[String]
}

///|
pub fn GuardConfig::new(
  max_memory_pages~ : Int32? = None,
  max_table_elements~ : Int32? = None,
  allowed_imports~ : Array[String] = [],
) -> Result[Self, InstrumentError] {
  match max_memory_pages {
    Some(limit) =>
      if limit < 0 || limit > MAX_MEMORY_PAGES {
        return Err(InvalidMemoryLimit(limit))
      }
    None => ()
  }
  match max_table_elements {
    Some(limit) => if limit < 0 { return Err(InvalidTableLimit(limit)) }
    None => ()
  }
  Ok({ max_memory_pages, max_table_elements, allowed_imports, })
}

///|
pub fn GuardConfig::max_memory_pages(self : Self) -> Int32? {
  self.max_memory_pages
}

///|
pub fn GuardConfig::max_table_elements(self : Self) -> Int32? {
  self.max_table_elements
}

///|
pub fn GuardConfig::allowed_imports(self : Self) -> Array[String] {
  self.allowed_imports
}

///|
pub struct InstrumentConfig {
  fuel : FuelConfig
  guard_config : GuardConfig
}

///|
pub fn InstrumentConfig::new(
  fuel : FuelConfig,
  guard_config : GuardConfig,
) -> Self {
  { fuel, guard_config, }
}

///|
pub fn InstrumentConfig::fuel(self : Self) -> FuelConfig {
  self.fuel
}

///|
pub fn InstrumentConfig::guard_config(self : Self) -> GuardConfig {
  self.guard_config
}
