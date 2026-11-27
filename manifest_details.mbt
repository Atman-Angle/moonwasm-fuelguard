///|
pub const BUILTIN_CODEGEN_VERSION = "inline-per-instruction-v1"

///|
pub const SHARED_CODEGEN_VERSION = "p1-helper-v1"

///|
pub const HYBRID_CODEGEN_VERSION = "p2-hybrid-loop-inline-sites21-v1"

///|
pub const PREFIX_CODEGEN_VERSION = "p2-prefix-exact-v1"

///|
pub const JOIN_CODEGEN_VERSION = "join-span-debit-first-v1"

///|
pub const CACHED_JOIN_CODEGEN_VERSION = "join-span-packed-cache-v1"

///|
pub const COMPACT_JOIN_CODEGEN_VERSION = "join-span-compact-v1"

///|
pub const COMPACT_JOIN_V2_CODEGEN_VERSION = "join-span-compact-v2"

///|
pub const FUEL_V2_CODEGEN_VERSION = "fuel-v2-inline-v1"

///|
pub const GROWTH_MODEL_VERSION = "growth-v1"

///|
fn[T : ToJson] manifest_optional(value : T?) -> Json {
  match value {
    Some(item) => Json(item)
    None => Json::null()
  }
}

///|
fn builtin_manifest_details(
  config : InstrumentConfig,
  profile : String,
) -> Json {
  let guards = config.guard_config()
  let imports = guards.allowed_import_pairs()
  imports.sort()
  let allowed_imports : Array[Json] = []
  for i, name in imports {
    if i == 0 || imports[i - 1] != name {
      allowed_imports.push({ "module": Json(name.0), "name": Json(name.1) })
    }
  }
  let limits = config.stack_config()
  {
    "profile": Json(profile),
    "fuel_model": Json(config.codegen().fuel_model()),
    "stack_model": manifest_optional(
      if config.profile() is Legacy {
        None
      } else {
        Some(stack_model_version)
      },
    ),
    "growth_model": Json(GROWTH_MODEL_VERSION),
    "diagnostics_abi": Json(diagnostics_abi_version),
    "codegen": Json(config.codegen().version()),
    "config": {
      "fuel": Json(config.fuel().budget()),
      "max_stack_units": manifest_optional(
        limits.map(fn(value) { value.max_units }),
      ),
      "max_call_depth": manifest_optional(
        limits.map(fn(value) { value.max_depth }),
      ),
      "max_memory_pages": manifest_optional(guards.max_memory_pages()),
      "max_table_elements": manifest_optional(guards.max_table_elements()),
      "allowed_imports": Json(allowed_imports),
    },
  }
}
