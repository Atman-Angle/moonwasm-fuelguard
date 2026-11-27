///|
fn imported_memory_count(wasm_module : @lib.Module) -> Int32 {
  match wasm_module.import_sec {
    None => 0
    Some(@lib.ImportSec(imports)) => {
      let mut count = 0
      for entry in imports {
        if entry is @lib.Import(_, _, @lib.MemExternType(_)) {
          count += 1
        }
      }
      count
    }
  }
}

///|
fn imported_table_count(wasm_module : @lib.Module) -> Int32 {
  match wasm_module.import_sec {
    None => 0
    Some(@lib.ImportSec(imports)) => {
      let mut count = 0
      for entry in imports {
        if entry is @lib.Import(_, _, @lib.TableExternType(_)) {
          count += 1
        }
      }
      count
    }
  }
}

///|
fn defined_memory_count(wasm_module : @lib.Module) -> Int32 {
  match wasm_module.mem_sec {
    None => 0
    Some(@lib.MemSec(memories)) => memories.length()
  }
}

///|
fn defined_table_count(wasm_module : @lib.Module) -> Int32 {
  match wasm_module.table_sec {
    None => 0
    Some(@lib.TableSec(tables)) => tables.length()
  }
}

///|
fn has_export(wasm_module : @lib.Module, name : String) -> Bool {
  match wasm_module.export_sec {
    None => false
    Some(@lib.ExportSec(exports)) => {
      for item in exports {
        match item {
          @lib.Export(@lib.Name(export_name), _) =>
            if export_name.to_owned() == name {
              return true
            }
        }
      }
      false
    }
  }
}

///|
fn check_gc_types(wasm_module : @lib.Module) -> Result[Unit, InstrumentError] {
  match wasm_module.type_sec {
    None => Ok(())
    Some(@lib.TypeSec(rec_types)) => {
      for rec_type in rec_types {
        let subtypes = match rec_type {
          @lib.SingleRecType(subtype) => [subtype]
          @lib.GroupRecType(group) => group
        }
        for subtype in subtypes {
          match subtype.get_comptype() {
            @lib.FuncCompType(_, _) => ()
            _ => return Err(UnsupportedFeature("wasm-gc types"))
          }
        }
      }
      Ok(())
    }
  }
}

///|
pub fn check_input(wasm_module : @lib.Module) -> Result[Unit, InstrumentError] {
  let memory_count = imported_memory_count(wasm_module) +
    defined_memory_count(wasm_module)
  let table_count = imported_table_count(wasm_module) +
    defined_table_count(wasm_module)
  if memory_count > 1 {
    return Err(UnsupportedFeature("multiple memories"))
  }
  if table_count > 1 {
    return Err(UnsupportedFeature("multiple tables"))
  }
  if has_export(wasm_module, trap_export_name) {
    return Err(ExportNameConflict(trap_export_name))
  }
  if has_export(wasm_module, trap_site_export_name) {
    return Err(ExportNameConflict(trap_site_export_name))
  }
  for @lib.CustomSec(@lib.Name(name), _) in wasm_module.custom_secs {
    if name.to_owned() == instrument_marker {
      return Err(
        UnsupportedFeature("already instrumented or unknown FuelGuard marker"),
      )
    }
  }
  check_gc_types(wasm_module)
}

///|
let instrument_marker : String = "fuelguard.instrumented"
