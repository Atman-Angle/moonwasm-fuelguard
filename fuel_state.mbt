///|
priv struct FuelState {
  wasm_module : @lib.Module
  fuel_global : @lib.GlobalIdx
  trap_global : @lib.GlobalIdx
  trap_site_global : @lib.GlobalIdx
  charge_helper : @lib.FuncIdx?
  prefix_failure : @lib.FuncIdx?
  join_failure : @lib.FuncIdx?
  join_shared : @lib.FuncIdx?
  compact_join : Bool
  fuel_v2 : Bool
  coalesce_join_publications : Bool
}

///|
///
/// Appends the i64 budget and two diagnostic globals used by fuel metering.
/// Imported globals shift the new indices, so all indices are computed from the
/// import and definition counts instead of from an empty global section.
fn add_fuel_state(
  wasm_module : @lib.Module,
  budget : Int64,
  stage~ : (String) -> Unit = fn(_) { () },
) -> Result[FuelState, InstrumentError] {
  if has_export(wasm_module, trap_export_name) {
    return Err(ExportNameConflict(trap_export_name))
  }
  if has_export(wasm_module, trap_site_export_name) {
    return Err(ExportNameConflict(trap_site_export_name))
  }
  let fuel_index = imported_global_count(wasm_module) +
    defined_global_count(wasm_module)
  let trap_index = fuel_index + 1
  let trap_site_index = fuel_index + 2
  let fuel_global = @lib.Global::new(
    @lib.GlobalType::new(@lib.ValType::i64(), true),
    @lib.Expr::new([@lib.Instruction::i64_const(@lib.I64::new(budget))]),
  )
  let trap_global = @lib.Global::new(
    @lib.GlobalType::new(@lib.ValType::i32(), true),
    @lib.Expr::new([@lib.Instruction::i32_const(@lib.I32::new(0))]),
  )
  let trap_site_global = @lib.Global::new(
    @lib.GlobalType::new(@lib.ValType::i32(), true),
    @lib.Expr::new([@lib.Instruction::i32_const(@lib.I32::new(0))]),
  )
  let globals = match wasm_module.global_sec {
    Some(@lib.GlobalSec(existing)) => {
      let out : Array[@lib.Global] = Array(capacity=existing.length() + 3)
      for item in existing {
        out.push(item)
      }
      out
    }
    None => []
  }
  globals.push(fuel_global)
  globals.push(trap_global)
  globals.push(trap_site_global)
  let exports = match wasm_module.export_sec {
    Some(@lib.ExportSec(existing)) => {
      let out : Array[@lib.Export] = Array(capacity=existing.length() + 1)
      for item in existing {
        out.push(item)
      }
      out
    }
    None => []
  }
  exports.push(
    @lib.Export::new(
      @lib.Name::from_string(trap_export_name),
      @lib.ExternIdx::global(
        @lib.GlobalIdx::new(trap_index.reinterpret_as_uint()),
      ),
    ),
  )
  exports.push(
    @lib.Export::new(
      @lib.Name::from_string(trap_site_export_name),
      @lib.ExternIdx::global(
        @lib.GlobalIdx::new(trap_site_index.reinterpret_as_uint()),
      ),
    ),
  )
  let output = wasm_module
    .with_global_sec(@lib.GlobalSec::new(globals))
    .with_export_sec(@lib.ExportSec::new(exports))
  stage("validate_fuel_state")
  match validate_wasm(output, "fuel state") {
    Ok(_) => {
      let fuel_global = @lib.GlobalIdx::new(fuel_index.reinterpret_as_uint())
      let trap_global = @lib.GlobalIdx::new(trap_index.reinterpret_as_uint())
      let trap_site_global = @lib.GlobalIdx::new(
        trap_site_index.reinterpret_as_uint(),
      )
      Ok({
        wasm_module: output,
        fuel_global,
        trap_global,
        trap_site_global,
        charge_helper: None,
        prefix_failure: None,
        join_failure: None,
        join_shared: None,
        compact_join: false,
        fuel_v2: false,
        coalesce_join_publications: false,
      })
    }
    Err(error) => Err(error)
  }
}
