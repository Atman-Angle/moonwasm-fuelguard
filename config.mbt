///|
const MAX_FUEL : Int64 = 9_223_372_036_854_775_807L

///|
const MAX_MEMORY_PAGES : Int32 = 65_536

///|
pub struct FuelConfig {
  budget : Int64
}

///|
pub fn FuelConfig::new(budget : Int64) -> Result[Self, InstrumentError] {
  if budget <= 0 || budget > MAX_FUEL {
    Err(InvalidFuelBudget(budget))
  } else {
    Ok({ budget, })
  }
}

///|
pub fn FuelConfig::budget(self : Self) -> Int64 {
  self.budget
}

///|
pub struct GuardConfig {
  max_memory_pages : Int32?
  max_table_elements : Int32?
  imports : Array[(String, String)]
}

///|
pub fn GuardConfig::new(
  max_memory_pages~ : Int32? = None,
  max_table_elements~ : Int32? = None,
  allowed_imports~ : Array[String] = [],
  allowed_import_pairs~ : Array[(String, String)] = [],
) -> Result[Self, InstrumentError] {
  match max_memory_pages {
    Some(limit) =>
      if limit < 0 || limit > MAX_MEMORY_PAGES {
        return Err(InvalidMemoryLimit(limit))
      }
    None => ()
  }
  match max_table_elements {
    Some(limit) =>
      if limit < 0 || limit > 65_536 {
        return Err(InvalidTableLimit(limit))
      }
    None => ()
  }
  let imports = allowed_import_pairs.copy()
  for raw in allowed_imports {
    let parts = raw.split(".").collect()
    if parts.length() != 2 || parts[0].length() == 0 || parts[1].length() == 0 {
      return Err(
        UnsupportedFeature(
          "ambiguous allow-import '\{raw}'; use exactly one dot between nonempty names",
        ),
      )
    }
    imports.push((parts[0].to_owned(), parts[1].to_owned()))
  }
  Ok({ max_memory_pages, max_table_elements, imports, })
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
  self.imports.map(fn(pair) { "\{pair.0}.\{pair.1}" })
}

///|
pub fn GuardConfig::allowed_import_pairs(
  self : Self,
) -> Array[(String, String)] {
  self.imports.copy()
}

///|
pub struct InstrumentConfig {
  fuel : FuelConfig
  guard_config : GuardConfig
  profile : InputProfile
  stack : StackConfig?
  codegen : CodegenLayout
}

///|
pub fn InstrumentConfig::new(
  fuel : FuelConfig,
  guard_config : GuardConfig,
  profile~ : InputProfile = ProductionV1,
  stack~ : StackConfig? = None,
  codegen? : CodegenLayout,
) -> Self {
  let codegen = codegen.unwrap_or(
    if profile is ProductionV1 {
      FuelV2
    } else {
      P0
    },
  )
  { fuel, guard_config, profile, stack, codegen, }
}

///|
pub fn InstrumentConfig::fuel(self : Self) -> FuelConfig {
  self.fuel
}

///|
pub fn InstrumentConfig::guard_config(self : Self) -> GuardConfig {
  self.guard_config
}

///|
pub(all) enum InputProfile {
  ProductionV1
  FuelGrowthV1
  Legacy
}

///|
pub fn InstrumentConfig::profile(self : Self) -> InputProfile {
  self.profile
}

///|
pub(all) enum CodegenLayout {
  P0
  P1
  P2
  P2Prefix
  JoinSpan
  JoinSpanCached
  JoinSpanCompact
  JoinSpanCompactV2
  FuelV2
}

///|
pub fn CodegenLayout::version(self : Self) -> String {
  match self {
    P0 => BUILTIN_CODEGEN_VERSION
    P1 => SHARED_CODEGEN_VERSION
    P2 => HYBRID_CODEGEN_VERSION
    P2Prefix => PREFIX_CODEGEN_VERSION
    JoinSpan => JOIN_CODEGEN_VERSION
    JoinSpanCached => CACHED_JOIN_CODEGEN_VERSION
    JoinSpanCompact => COMPACT_JOIN_CODEGEN_VERSION
    JoinSpanCompactV2 => COMPACT_JOIN_V2_CODEGEN_VERSION
    FuelV2 => FUEL_V2_CODEGEN_VERSION
  }
}

///|
pub fn CodegenLayout::fuel_model(self : Self) -> String {
  if self is FuelV2 {
    FUEL_V2_VERSION
  } else if self.uses_join_spans() {
    JOIN_FUEL_VERSION
  } else {
    fuel_v1_version
  }
}

///|
fn CodegenLayout::uses_join_spans(self : Self) -> Bool {
  self is (JoinSpan | JoinSpanCached | FuelV2) || self.uses_compact_join()
}

///|
fn CodegenLayout::uses_fuel_cache(self : Self) -> Bool {
  self is (JoinSpanCached | FuelV2) || self.uses_compact_join()
}

///|
fn CodegenLayout::uses_compact_join(self : Self) -> Bool {
  self is (JoinSpanCompact | JoinSpanCompactV2)
}

///|
pub fn InstrumentConfig::codegen(self : Self) -> CodegenLayout {
  self.codegen
}

///|
pub struct StackConfig {
  max_units : Int64
  max_depth : Int64
}

///|
const MAX_PACKED_STACK_COUNTER : Int64 = 0x7fff_ffffL

///|
pub fn StackConfig::new(
  max_units : Int64,
  max_depth : Int64,
) -> Result[StackConfig, InstrumentError] {
  if max_units <= 0L ||
    max_units > MAX_PACKED_STACK_COUNTER ||
    max_depth <= 0L ||
    max_depth > MAX_PACKED_STACK_COUNTER {
    Err(InvalidStackLimits(max_units, max_depth))
  } else {
    Ok({ max_units, max_depth, })
  }
}

///|
pub fn InstrumentConfig::stack_config(self : Self) -> StackConfig? {
  self.stack
}
