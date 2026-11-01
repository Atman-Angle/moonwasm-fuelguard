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

///|
fn void_block(body : Array[@lib.Instruction]) -> @lib.Instruction {
  @lib.Instruction::block(@lib.BlockType::void_(), @lib.Expr::new(body))
}

///|
fn void_loop(body : Array[@lib.Instruction]) -> @lib.Instruction {
  @lib.Instruction::loop_(@lib.BlockType::void_(), @lib.Expr::new(body))
}

///|
fn block_body(instruction : @lib.Instruction) -> @lib.Expr {
  match instruction {
    @lib.Block(_, body) => body
    _ => abort("expected block instruction")
  }
}

///|
fn loop_body(instruction : @lib.Instruction) -> @lib.Expr {
  match instruction {
    @lib.Loop(_, body) => body
    _ => abort("expected loop instruction")
  }
}

///|
fn function_module(
  params : Array[@lib.ValType],
  local_types : Array[@lib.ValType],
  body : Array[@lib.Instruction],
) -> @lib.Module {
  @lib.Module::new(
    type_sec=Some(
      @lib.TypeSec::new([
        @lib.RecType::new(
          @lib.SubType::comp_type(@lib.CompType::func(params, [])),
        ),
      ]),
    ),
    func_sec=Some(@lib.FuncSec::new([@lib.TypeIdx::new(0U)])),
    code_sec=Some(
      @lib.CodeSec::new([
        @lib.Func::new(
          @lib.Locals::from_types(local_types),
          @lib.Expr::new(body),
        ),
      ]),
    ),
  )
}

///|
test "map_expr rebuilds nested instructions without mutating the source" {
  let source = @lib.Expr::new([
    void_block([void_loop([@lib.Instruction::nop()])]),
  ])
  let mapped = map_expr(source, fn(instruction) {
    match instruction {
      @lib.Nop => @lib.Instruction::i32_const(@lib.I32::new(7))
      _ => instruction
    }
  })
  let @lib.Expr(source_outer) = source
  assert_true(source_outer[0] is @lib.Block(_, _))
  let @lib.Expr(source_block) = block_body(source_outer[0])
  assert_true(source_block[0] is @lib.Loop(_, _))
  let @lib.Expr(source_loop) = loop_body(source_block[0])
  assert_true(source_loop[0] is @lib.Nop)
  let @lib.Expr(mapped_outer) = mapped
  let @lib.Expr(mapped_block) = block_body(mapped_outer[0])
  let @lib.Expr(mapped_loop) = loop_body(mapped_block[0])
  assert_true(mapped_loop[0] is @lib.I32Const(_))
}

///|
test "map_expr traverses if branches" {
  let source = @lib.Expr::new([
    @lib.Instruction::if_(
      @lib.BlockType::void_(),
      [@lib.Instruction::nop()],
      Some([@lib.Instruction::nop()]),
    ),
  ])
  let mapped = map_expr(source, fn(instruction) {
    match instruction {
      @lib.Nop => @lib.Instruction::i32_const(@lib.I32::new(1))
      _ => instruction
    }
  })
  let @lib.Expr(outer) = mapped
  match outer[0] {
    @lib.If(_, then_body, Some(else_body)) => {
      assert_true(then_body[0] is @lib.I32Const(_))
      assert_true(else_body[0] is @lib.I32Const(_))
    }
    _ => abort("expected if instruction")
  }
}

///|
test "count_loops counts nested loops across structured instructions" {
  let body = [
    void_block([
      void_loop([@lib.Instruction::nop()]),
      @lib.Instruction::if_(
        @lib.BlockType::void_(),
        [void_loop([])],
        Some([void_loop([void_loop([])])]),
      ),
    ]),
    void_loop([void_block([void_loop([])])]),
  ]
  assert_eq(count_loops_in_instructions(body), 6)
  let wasm_module = function_module([], [], body)
  assert_eq(count_loops(wasm_module), 6)
}

///|
test "count_loops counts loops inside try bodies and catches" {
  let body = [
    @lib.Instruction::try_(
      @lib.BlockType::void_(),
      @lib.Expr::new([void_loop([])]),
      [
        @lib.LegacyCatch::tagged(
          @lib.TagIdx::new(0U),
          @lib.Expr::new([void_loop([])]),
        ),
        @lib.LegacyCatch::all(@lib.Expr::new([void_loop([])])),
      ],
    ),
    @lib.Instruction::try_table(
      @lib.BlockType::void_(),
      [],
      @lib.Expr::new([void_loop([])]),
    ),
  ]
  assert_eq(count_loops_in_instructions(body), 4)
}

///|
test "count_loops is zero for loop-free modules and empty modules" {
  assert_eq(count_loops(@lib.Module::new()), 0)
  assert_eq(count_loops(function_module([], [], [])), 0)
  assert_eq(count_loops(function_module([], [], [@lib.Instruction::nop()])), 0)
}

///|
test "defined function and imported index counts avoid offset errors" {
  let wasm_module = @lib.Module::new(
    type_sec=Some(
      @lib.TypeSec::new([
        @lib.RecType::new(@lib.SubType::comp_type(@lib.CompType::func([], []))),
      ]),
    ),
    import_sec=Some(
      @lib.ImportSec::new([
        @lib.Import::new(
          @lib.Name::from_string("env"),
          @lib.Name::from_string("f"),
          @lib.ExternType::func(@lib.TypeIdx::new(0U)),
        ),
        @lib.Import::new(
          @lib.Name::from_string("env"),
          @lib.Name::from_string("g"),
          @lib.ExternType::global(
            @lib.GlobalType::new(@lib.ValType::i32(), false),
          ),
        ),
        mem_import("env", "memory"),
        table_import("env", "table"),
      ]),
    ),
    func_sec=Some(
      @lib.FuncSec::new([@lib.TypeIdx::new(0U), @lib.TypeIdx::new(0U)]),
    ),
    code_sec=Some(
      @lib.CodeSec::new([
        @lib.Func::new(@lib.Locals::empty(), @lib.Expr::new([])),
        @lib.Func::new(@lib.Locals::empty(), @lib.Expr::new([])),
      ]),
    ),
  )
  assert_eq(imported_function_count(wasm_module), 1)
  assert_eq(imported_global_count(wasm_module), 1)
  assert_eq(defined_function_count(wasm_module), 2)
  assert_eq(defined_code_count(wasm_module), 2)
  assert_eq(defined_global_count(wasm_module), 0)
}

///|
test "function local counts include parameters and body locals" {
  let wasm_module = function_module(
    [@lib.ValType::i32(), @lib.ValType::i64()],
    [@lib.ValType::i32(), @lib.ValType::i32(), @lib.ValType::f64()],
    [],
  )
  assert_eq(function_param_count(wasm_module, 0), 2)
  assert_eq(function_body_local_count(wasm_module, 0), 3)
}

///|
test "type group flattening finds the referenced function type" {
  let wasm_module = @lib.Module::new(
    type_sec=Some(
      @lib.TypeSec::new([
        @lib.RecType::group([
          @lib.SubType::comp_type(@lib.CompType::func([], [])),
          @lib.SubType::comp_type(
            @lib.CompType::func([@lib.ValType::i32()], []),
          ),
        ]),
      ]),
    ),
    func_sec=Some(@lib.FuncSec::new([@lib.TypeIdx::new(1U)])),
    code_sec=Some(
      @lib.CodeSec::new([
        @lib.Func::new(@lib.Locals::empty(), @lib.Expr::new([])),
      ]),
    ),
  )
  assert_eq(function_param_count(wasm_module, 0), 1)
}

///|
test "local counts are zero for missing functions" {
  assert_eq(function_param_count(@lib.Module::new(), 0), 0)
  assert_eq(function_body_local_count(@lib.Module::new(), 0), 0)
  assert_eq(function_body_local_count(function_module([], [], []), 3), 0)
}

///|
test "fuel state appends mutable i32 globals with configured budget" {
  let state = add_fuel_state(@lib.Module::new(), 100).unwrap()
  let @lib.GlobalSec(globals) = state.wasm_module.global_sec.unwrap()
  assert_eq(globals.length(), 2)
  let @lib.Global(
    @lib.GlobalType(fuel_type, fuel_mutable),
    @lib.Expr(fuel_init)
  ) = globals[0]
  assert_eq(fuel_type, @lib.ValType::i32())
  assert_true(fuel_mutable)
  assert_eq(fuel_init, [@lib.Instruction::i32_const(@lib.I32::new(100))])
  let @lib.Global(
    @lib.GlobalType(trap_type, trap_mutable),
    @lib.Expr(trap_init)
  ) = globals[1]
  assert_eq(trap_type, @lib.ValType::i32())
  assert_true(trap_mutable)
  assert_eq(trap_init, [@lib.Instruction::i32_const(@lib.I32::new(0))])
  assert_eq(state.fuel_global, @lib.GlobalIdx::new(0U))
  assert_eq(state.trap_global, @lib.GlobalIdx::new(1U))
}

///|
test "fuel state exports the trap code global under the reserved name" {
  let state = add_fuel_state(@lib.Module::new(), 10).unwrap()
  let @lib.ExportSec(exports) = state.wasm_module.export_sec.unwrap()
  assert_eq(exports.length(), 1)
  let @lib.Export(name, index) = exports[0]
  assert_eq(name, @lib.Name::from_string(trap_export_name))
  let global = match index {
    @lib.GlobalExternIdx(global) => global
    _ => abort("expected a global export")
  }
  assert_eq(global, @lib.GlobalIdx::new(1U))
}

///|
test "fuel state output passes validation" {
  let state = add_fuel_state(@lib.Module::new(), 10).unwrap()
  assert_true(validate_wasm(state.wasm_module, "test") is Ok(_))
}

///|
test "fuel state rejects an existing reserved export" {
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
  assert_true(add_fuel_state(wasm_module, 10) is Err(ExportNameConflict(_)))
}

///|
test "fuel state indices account for imported globals" {
  let wasm_module = @lib.Module::new(
    import_sec=Some(
      @lib.ImportSec::new([
        @lib.Import::new(
          @lib.Name::from_string("env"),
          @lib.Name::from_string("g"),
          @lib.ExternType::global(
            @lib.GlobalType::new(@lib.ValType::i32(), false),
          ),
        ),
      ]),
    ),
  )
  let state = add_fuel_state(wasm_module, 10).unwrap()
  assert_eq(state.fuel_global, @lib.GlobalIdx::new(1U))
  assert_eq(state.trap_global, @lib.GlobalIdx::new(2U))
  let @lib.ExportSec(exports) = state.wasm_module.export_sec.unwrap()
  let @lib.Export(_, index) = exports[0]
  let global = match index {
    @lib.GlobalExternIdx(global) => global
    _ => abort("expected a global export")
  }
  assert_eq(global, @lib.GlobalIdx::new(2U))
  let @lib.GlobalSec(globals) = state.wasm_module.global_sec.unwrap()
  assert_eq(globals.length(), 2)
  assert_true(validate_wasm(state.wasm_module, "test") is Ok(_))
}

///|
test "fuel state keeps existing globals and exports" {
  let wasm_module = @lib.Module::new(
    global_sec=Some(
      @lib.GlobalSec::new([
        @lib.Global::new(
          @lib.GlobalType::new(@lib.ValType::i32(), false),
          @lib.Expr::new([@lib.Instruction::i32_const(@lib.I32::new(5))]),
        ),
      ]),
    ),
    export_sec=Some(
      @lib.ExportSec::new([
        @lib.Export::new(
          @lib.Name::from_string("answer"),
          @lib.ExternIdx::global(@lib.GlobalIdx::new(0U)),
        ),
      ]),
    ),
  )
  let state = add_fuel_state(wasm_module, 42).unwrap()
  assert_eq(state.fuel_global, @lib.GlobalIdx::new(1U))
  assert_eq(state.trap_global, @lib.GlobalIdx::new(2U))
  let @lib.GlobalSec(globals) = state.wasm_module.global_sec.unwrap()
  assert_eq(globals.length(), 3)
  let @lib.ExportSec(exports) = state.wasm_module.export_sec.unwrap()
  assert_eq(exports.length(), 2)
  assert_true(has_export(state.wasm_module, "answer"))
  assert_true(has_export(state.wasm_module, trap_export_name))
}

///|
test "fuel state leaves the source module unchanged" {
  let wasm_module = @lib.Module::new(
    global_sec=Some(
      @lib.GlobalSec::new([
        @lib.Global::new(
          @lib.GlobalType::new(@lib.ValType::i32(), false),
          @lib.Expr::new([@lib.Instruction::i32_const(@lib.I32::new(5))]),
        ),
      ]),
    ),
  )
  let _ = add_fuel_state(wasm_module, 10).unwrap()
  let @lib.GlobalSec(source_globals) = wasm_module.global_sec.unwrap()
  assert_eq(source_globals.length(), 1)
  assert_true(wasm_module.export_sec is None)
}
