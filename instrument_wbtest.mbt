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
test "multiple memories are rejected" {
  let wasm_module = @lib.Module::new(
    mem_sec=Some(
      @lib.MemSec::new([
        @lib.MemType::new(@lib.Limits::i32(1U, None)),
        @lib.MemType::new(@lib.Limits::i32(1U, None)),
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
