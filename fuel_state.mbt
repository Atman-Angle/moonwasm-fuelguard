///|
#warnings("-unused_field")
priv struct FuelState {
  wasm_module : @lib.Module
  fuel_global : @lib.GlobalIdx
  trap_global : @lib.GlobalIdx
}

///|
///
/// Appends the two runtime globals used by fuel metering and exports the trap
/// code global. Imported globals shift the new indices, so both indices are
/// computed from the import and definition counts instead of from an empty
/// global section.
#warnings("-unused_value")
fn add_fuel_state(
  wasm_module : @lib.Module,
  budget : Int32,
) -> Result[FuelState, InstrumentError] {
  if has_export(wasm_module, trap_export_name) {
    return Err(ExportNameConflict(trap_export_name))
  }
  let fuel_index = imported_global_count(wasm_module) +
    defined_global_count(wasm_module)
  let trap_index = fuel_index + 1
  let fuel_global = @lib.Global::new(
    @lib.GlobalType::new(@lib.ValType::i32(), true),
    @lib.Expr::new([@lib.Instruction::i32_const(@lib.I32::new(budget))]),
  )
  let trap_global = @lib.Global::new(
    @lib.GlobalType::new(@lib.ValType::i32(), true),
    @lib.Expr::new([@lib.Instruction::i32_const(@lib.I32::new(0))]),
  )
  let globals = match wasm_module.global_sec {
    Some(@lib.GlobalSec(existing)) => {
      let out : Array[@lib.Global] = Array(capacity=existing.length() + 2)
      for item in existing {
        out.push(item)
      }
      out
    }
    None => []
  }
  globals.push(fuel_global)
  globals.push(trap_global)
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
  let output = wasm_module
    .with_global_sec(@lib.GlobalSec::new(globals))
    .with_export_sec(@lib.ExportSec::new(exports))
  match validate_wasm(output, "fuel state") {
    Ok(_) => {
      let fuel_global = @lib.GlobalIdx::new(fuel_index.reinterpret_as_uint())
      let trap_global = @lib.GlobalIdx::new(trap_index.reinterpret_as_uint())
      Ok({ wasm_module: output, fuel_global, trap_global, })
    }
    Err(error) => Err(error)
  }
}
