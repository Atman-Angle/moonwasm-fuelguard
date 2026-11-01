///|
test "fuel config rejects zero" {
  assert_true(FuelConfig::new(0) is Err(_))
}

///|
test "fuel config rejects negative values" {
  assert_true(FuelConfig::new(-1) is Err(_))
}

///|
test "fuel config accepts positive value" {
  assert_true(FuelConfig::new(1_000_000) is Ok(_))
}

///|
test "memory guard rejects values above 65536 pages" {
  assert_true(GuardConfig::new(max_memory_pages=Some(65_537)) is Err(_))
}

///|
test "guard config accepts optional limits" {
  assert_true(
    GuardConfig::new(max_memory_pages=Some(64), max_table_elements=Some(1024))
    is Ok(_),
  )
}

///|
test "trap codes round trip" {
  assert_eq(TrapCode::NoTrap.to_code(), 0)
  assert_eq(TrapCode::Fuel.to_code(), 1)
  assert_eq(TrapCode::Memory.to_code(), 2)
  assert_eq(TrapCode::Table.to_code(), 3)
}

///|
test "unknown trap code is rejected" {
  assert_true(TrapCode::from_code(9) is Err(_))
}

///|
test "builtin pipeline reaches the first pass" {
  let fuel = FuelConfig::new(100).unwrap()
  let guards = GuardConfig::new().unwrap()
  let pipeline : Pipeline = Pipeline::builtin(
    InstrumentConfig::new(fuel, guards),
  )
  assert_true(
    pipeline.run(@lib.Module::new()) is Err(NotImplemented("FuelPass")),
  )
}

///|
test "empty module passes input policy" {
  assert_true(check_input(@lib.Module::new()) is Ok(_))
}

///|
fn mem_type() -> @lib.MemType {
  @lib.MemType::new(@lib.Limits::i32(1U, None))
}

///|
fn table_type() -> @lib.TableType {
  @lib.TableType::new(
    @lib.RefType::abs(@lib.AbsHeapType::func()),
    @lib.Limits::i32(1U, None),
  )
}

///|
fn mem_import(module_name : String, field_name : String) -> @lib.Import {
  @lib.Import::new(
    @lib.Name::from_string(module_name),
    @lib.Name::from_string(field_name),
    @lib.ExternType::mem(mem_type()),
  )
}

///|
fn table_import(module_name : String, field_name : String) -> @lib.Import {
  @lib.Import::new(
    @lib.Name::from_string(module_name),
    @lib.Name::from_string(field_name),
    @lib.ExternType::table(table_type()),
  )
}

///|
test "multiple memories are rejected" {
  let wasm_module = @lib.Module::new(
    mem_sec=Some(@lib.MemSec::new([mem_type(), mem_type()])),
  )
  assert_true(check_input(wasm_module) is Err(UnsupportedFeature(_)))
}

///|
test "multiple tables are rejected" {
  let wasm_module = @lib.Module::new(
    table_sec=Some(
      @lib.TableSec::new([
        @lib.Table::new(table_type(), None),
        @lib.Table::new(table_type(), None),
      ]),
    ),
  )
  assert_true(check_input(wasm_module) is Err(UnsupportedFeature(_)))
}

///|
test "imported memory counts toward the memory limit" {
  let imported_only = @lib.Module::new(
    import_sec=Some(@lib.ImportSec::new([mem_import("env", "memory")])),
  )
  assert_true(check_input(imported_only) is Ok(_))
  let imported_and_defined = @lib.Module::new(
    import_sec=Some(@lib.ImportSec::new([mem_import("env", "memory")])),
    mem_sec=Some(@lib.MemSec::new([mem_type()])),
  )
  assert_true(check_input(imported_and_defined) is Err(UnsupportedFeature(_)))
}

///|
test "imported table counts toward the table limit" {
  let imported_only = @lib.Module::new(
    import_sec=Some(@lib.ImportSec::new([table_import("env", "table")])),
  )
  assert_true(check_input(imported_only) is Ok(_))
  let imported_and_defined = @lib.Module::new(
    import_sec=Some(@lib.ImportSec::new([table_import("env", "table")])),
    table_sec=Some(@lib.TableSec::new([@lib.Table::new(table_type(), None)])),
  )
  assert_true(check_input(imported_and_defined) is Err(UnsupportedFeature(_)))
}

///|
test "zero and one memory are accepted" {
  assert_true(check_input(@lib.Module::new()) is Ok(_))
  let one_memory = @lib.Module::new(
    mem_sec=Some(@lib.MemSec::new([mem_type()])),
  )
  assert_true(check_input(one_memory) is Ok(_))
}

///|
test "zero and one table are accepted" {
  assert_true(check_input(@lib.Module::new()) is Ok(_))
  let one_table = @lib.Module::new(
    table_sec=Some(@lib.TableSec::new([@lib.Table::new(table_type(), None)])),
  )
  assert_true(check_input(one_table) is Ok(_))
}

///|
test "non-function GC type is rejected" {
  let wasm_module = @lib.Module::new(
    type_sec=Some(
      @lib.TypeSec::new([
        @lib.RecType::new(@lib.SubType::comp_type(@lib.CompType::struct_([]))),
      ]),
    ),
  )
  assert_true(check_input(wasm_module) is Err(UnsupportedFeature(_)))
}

///|
test "function type is accepted" {
  let wasm_module = @lib.Module::new(
    type_sec=Some(
      @lib.TypeSec::new([
        @lib.RecType::new(@lib.SubType::comp_type(@lib.CompType::func([], []))),
      ]),
    ),
  )
  assert_true(check_input(wasm_module) is Ok(_))
}

///|
test "function type inside a rec group is accepted" {
  let wasm_module = @lib.Module::new(
    type_sec=Some(
      @lib.TypeSec::new([
        @lib.RecType::group([
          @lib.SubType::comp_type(@lib.CompType::func([], [])),
          @lib.SubType::comp_type(@lib.CompType::func([], [])),
        ]),
      ]),
    ),
  )
  assert_true(check_input(wasm_module) is Ok(_))
}

///|
test "rec group containing a struct type is rejected" {
  let wasm_module = @lib.Module::new(
    type_sec=Some(
      @lib.TypeSec::new([
        @lib.RecType::group([
          @lib.SubType::comp_type(@lib.CompType::func([], [])),
          @lib.SubType::comp_type(@lib.CompType::struct_([])),
        ]),
      ]),
    ),
  )
  assert_true(check_input(wasm_module) is Err(UnsupportedFeature(_)))
}

///|
test "reserved trap export is rejected" {
  let wasm_module = @lib.Module::new(
    export_sec=Some(
      @lib.ExportSec::new([
        @lib.Export::new(
          @lib.Name::from_string(trap_export_name),
          @lib.ExternIdx::global(@lib.GlobalIdx::new(0U)),
        ),
      ]),
    ),
  )
  assert_true(check_input(wasm_module) is Err(ExportNameConflict(_)))
}

///|
test "non-reserved export names are accepted" {
  let wasm_module = @lib.Module::new(
    export_sec=Some(
      @lib.ExportSec::new([
        @lib.Export::new(
          @lib.Name::from_string("main"),
          @lib.ExternIdx::global(@lib.GlobalIdx::new(0U)),
        ),
      ]),
    ),
  )
  assert_true(check_input(wasm_module) is Ok(_))
}
