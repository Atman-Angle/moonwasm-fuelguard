///|
fn fuel_pass_result(wasm_module : @lib.Module, budget : Int64) -> PassResult {
  let config = FuelConfig::new(budget).unwrap()
  match Pass::apply(FuelPass::new(config), wasm_module) {
    Ok(result) => result
    Err(error) => abort("fuel pass failed: \{error.message()}")
  }
}

///|

///|
fn output_body(
  wasm_module : @lib.Module,
  index : Int32,
) -> Array[@lib.Instruction] {
  let @lib.CodeSec(functions) = wasm_module.code_sec.unwrap()
  let @lib.Func(_, @lib.Expr(body)) = functions[index]
  body
}

///|
fn output_locals(wasm_module : @lib.Module, index : Int32) -> @lib.Locals {
  let @lib.CodeSec(functions) = wasm_module.code_sec.unwrap()
  let @lib.Func(locals, _) = functions[index]
  locals
}

///|
fn charge_indices(
  instructions : Array[@lib.Instruction],
  start : Int32,
) -> (@lib.GlobalIdx, @lib.LocalIdx, @lib.GlobalIdx)? {
  if start + 9 > instructions.length() {
    return None
  }
  match
    (
      instructions[start],
      instructions[start + 1],
      instructions[start + 2],
      instructions[start + 3],
      instructions[start + 4],
    ) {
    (
      @lib.GlobalGet(fuel),
      @lib.LocalTee(temp),
      @lib.I64Const(_),
      @lib.I64LtS,
      @lib.If(_, trap_body, None),
    ) =>
      if trap_body.length() == 5 {
        match trap_body[1] {
          @lib.GlobalSet(trap) => Some((fuel, temp, trap))
          _ => None
        }
      } else {
        None
      }
    _ => None
  }
}

///|
fn charge_site_count(instructions : Array[@lib.Instruction]) -> Int32 {
  let mut count = 0
  for index, instruction in instructions {
    if charge_indices(instructions, index) is Some(_) {
      count += 1
    }
    match instruction {
      @lib.Block(_, body) => {
        let @lib.Expr(inner) = body
        count += charge_site_count(inner)
      }
      @lib.Loop(_, body) => {
        let @lib.Expr(inner) = body
        count += charge_site_count(inner)
      }
      @lib.Try(_, body, _, _) | @lib.TryTable(_, _, body) => {
        let @lib.Expr(inner) = body
        count += charge_site_count(inner)
      }
      @lib.If(_, then_body, else_body) => {
        count += charge_site_count(then_body)
        match else_body {
          Some(body) => count += charge_site_count(body)
          None => ()
        }
      }
      _ => ()
    }
  }
  count
}

///|
test "fuel pass charges the function entry and adds one temp local" {
  let wasm_module = function_module([], [], [@lib.Instruction::nop()])
  let result = fuel_pass_result(wasm_module, 100)
  assert_eq(result.pass_name(), "FuelPass")
  let body = output_body(result.output(), 0)
  assert_eq(body.length(), 10)
  let charge = charge_indices(body, 0).unwrap()
  let (fuel, temp, trap) = charge
  assert_eq(fuel, @lib.GlobalIdx::new(0U))
  assert_eq(trap, @lib.GlobalIdx::new(1U))
  assert_eq(temp, @lib.LocalIdx::new(0U))
  assert_true(body[9] is @lib.Nop)
  let locals = output_locals(result.output(), 0)
  assert_eq(locals.length(), 1)
  assert_eq(locals[0], @lib.ValType::i64())
}

///|
test "fuel cache reload is skipped only for direct unmetered targets" {
  let metered_functions = [true, true, false]
  assert_true(
    call_can_change_fuel(
      @lib.Instruction::call(@lib.FuncIdx::new(0U)),
      metered_functions,
    ),
  )
  assert_true(
    call_can_change_fuel(
      @lib.Instruction::call(@lib.FuncIdx::new(1U)),
      metered_functions,
    ),
  )
  assert_false(
    call_can_change_fuel(
      @lib.Instruction::call(@lib.FuncIdx::new(2U)),
      metered_functions,
    ),
  )
  assert_true(
    call_can_change_fuel(
      @lib.Instruction::call(@lib.FuncIdx::new(3U)),
      metered_functions,
    ),
  )
  assert_true(
    call_can_change_fuel(
      @lib.Instruction::call_indirect(
        @lib.TypeIdx::new(0U),
        @lib.TableIdx::new(0U),
      ),
      metered_functions,
    ),
  )
}

///|
test "Fuel v2 cache can cover dynamic-cost functions with multiple spans" {
  assert_false(fuel_cache_profitable(1, 0, true))
  assert_false(fuel_cache_profitable(2, 1, false))
  assert_true(fuel_cache_profitable(3, 1, true))
  assert_true(fuel_cache_profitable(3, 0, false))
}

///|
test "fuel cache marks callers of metered functions as balance-changing" {
  let function_type = @lib.RecType::new(
    @lib.SubType::comp_type(@lib.CompType::func([], [])),
  )
  let wasm_module = @lib.Module::new(
    type_sec=Some(@lib.TypeSec::new([function_type])),
    func_sec=Some(
      @lib.FuncSec::new([@lib.TypeIdx::new(0U), @lib.TypeIdx::new(0U)]),
    ),
    code_sec=Some(
      @lib.CodeSec::new([
        @lib.Func::new(
          @lib.Locals::empty(),
          @lib.Expr::new([@lib.Instruction::call(@lib.FuncIdx::new(1U))]),
        ),
        @lib.Func::new(
          @lib.Locals::empty(),
          @lib.Expr::new([@lib.Instruction::nop()]),
        ),
      ]),
    ),
  )
  let changing = fuel_changing_functions(wasm_module, [false, true])
  assert_true(changing[0])
  assert_true(changing[1])
}

///|
test "fuel pass charges every loop body including nested loops" {
  let wasm_module = function_module([], [], [
    void_loop([@lib.Instruction::nop()]),
    void_loop([void_loop([])]),
  ])
  let result = fuel_pass_result(wasm_module, 100)
  let body = output_body(result.output(), 0)
  assert_eq(charge_site_count(body), 4)
  assert_true(body.any(fn(item) { item is @lib.Loop(_, _) }))
}

///|
test "fuel pass keeps parameter and existing local indices stable" {
  let wasm_module = function_module(
    [@lib.ValType::i32(), @lib.ValType::i64()],
    [@lib.ValType::i32(), @lib.ValType::f64()],
    [@lib.Instruction::nop()],
  )
  let result = fuel_pass_result(wasm_module, 100)
  let locals = output_locals(result.output(), 0)
  assert_eq(locals.length(), 3)
  assert_eq(locals[2], @lib.ValType::i64())
  let body = output_body(result.output(), 0)
  let (_, temp, _) = charge_indices(body, 0).unwrap()
  assert_eq(temp, @lib.LocalIdx::new(4U))
}

///|
test "fuel pass accounts for imported globals" {
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
          @lib.Name::from_string("g"),
          @lib.ExternType::global(
            @lib.GlobalType::new(@lib.ValType::i32(), false),
          ),
        ),
      ]),
    ),
    func_sec=Some(@lib.FuncSec::new([@lib.TypeIdx::new(0U)])),
    code_sec=Some(
      @lib.CodeSec::new([
        @lib.Func::new(
          @lib.Locals::empty(),
          @lib.Expr::new([@lib.Instruction::nop()]),
        ),
      ]),
    ),
  )
  let result = fuel_pass_result(wasm_module, 50)
  let body = output_body(result.output(), 0)
  let (fuel, _, trap) = charge_indices(body, 0).unwrap()
  assert_eq(fuel, @lib.GlobalIdx::new(1U))
  assert_eq(trap, @lib.GlobalIdx::new(2U))
}

///|
test "fuel pass does not charge imports and does not add imports" {
  let wasm_module = @lib.Module::new(
    type_sec=Some(
      @lib.TypeSec::new([
        @lib.RecType::new(
          @lib.SubType::comp_type(
            @lib.CompType::func([], [@lib.ValType::i32()]),
          ),
        ),
        @lib.RecType::new(
          @lib.SubType::comp_type(
            @lib.CompType::func([], [@lib.ValType::i32()]),
          ),
        ),
      ]),
    ),
    import_sec=Some(
      @lib.ImportSec::new([
        @lib.Import::new(
          @lib.Name::from_string("env"),
          @lib.Name::from_string("f"),
          @lib.ExternType::func(@lib.TypeIdx::new(0U)),
        ),
      ]),
    ),
    func_sec=Some(@lib.FuncSec::new([@lib.TypeIdx::new(1U)])),
    code_sec=Some(
      @lib.CodeSec::new([
        @lib.Func::new(
          @lib.Locals::empty(),
          @lib.Expr::new([@lib.Instruction::call(@lib.FuncIdx::new(0U))]),
        ),
      ]),
    ),
  )
  let result = fuel_pass_result(wasm_module, 50)
  let @lib.ImportSec(output_imports) = result.output().import_sec.unwrap()
  assert_eq(output_imports.length(), 1)
  let body = output_body(result.output(), 0)
  assert_eq(charge_site_count(body), 1)
  let called = match body[9] {
    @lib.Call(called) => called
    _ => abort("expected the original call after the entry charge")
  }
  assert_eq(called, @lib.FuncIdx::new(0U))
}

///|
test "fuel pass normal path reads and writes fuel once per site" {
  let wasm_module = function_module([], [], [@lib.Instruction::nop()])
  let result = fuel_pass_result(wasm_module, 100)
  let body = output_body(result.output(), 0)
  let mut reads = 0
  let mut writes = 0
  for instruction in body {
    match instruction {
      @lib.GlobalGet(fuel) => if fuel == @lib.GlobalIdx::new(0U) { reads += 1 }
      @lib.GlobalSet(fuel) => if fuel == @lib.GlobalIdx::new(0U) { writes += 1 }
      _ => ()
    }
  }
  assert_eq(reads, 1)
  assert_eq(writes, 1)
}

///|
test "fuel pass output validates and leaves the source module unchanged" {
  let wasm_module = function_module([], [], [
    void_loop([@lib.Instruction::nop()]),
  ])
  let result = fuel_pass_result(wasm_module, 100)
  assert_true(validate_wasm(result.output(), "test") is Ok(_))
  let source = output_body(wasm_module, 0)
  assert_eq(source.length(), 1)
  assert_true(source[0] is @lib.Loop(_, _))
  let source_locals = output_locals(wasm_module, 0)
  assert_eq(source_locals.length(), 0)
}

///|
test "fuel pass reports function and loop counts in notes" {
  let wasm_module = @lib.Module::new(
    type_sec=Some(
      @lib.TypeSec::new([
        @lib.RecType::new(@lib.SubType::comp_type(@lib.CompType::func([], []))),
      ]),
    ),
    func_sec=Some(
      @lib.FuncSec::new([@lib.TypeIdx::new(0U), @lib.TypeIdx::new(0U)]),
    ),
    code_sec=Some(
      @lib.CodeSec::new([
        @lib.Func::new(
          @lib.Locals::empty(),
          @lib.Expr::new([void_loop([]), void_loop([])]),
        ),
        @lib.Func::new(
          @lib.Locals::empty(),
          @lib.Expr::new([@lib.Instruction::nop()]),
        ),
      ]),
    ),
  )
  let result = fuel_pass_result(wasm_module, 77)
  let notes = result.notes()
  assert_eq(notes.length(), 1)
  assert_true(notes[0].contains("functions=2"))
  assert_true(notes[0].contains("loops=2"))
  assert_true(notes[0].contains("budget=77"))
  assert_eq(charge_site_count(output_body(result.output(), 0)), 2)
  assert_eq(charge_site_count(output_body(result.output(), 1)), 1)
}

///|
test "fuel pass handles a module without a code section" {
  let result = fuel_pass_result(@lib.Module::new(), 10)
  assert_true(validate_wasm(result.output(), "test") is Ok(_))
  let @lib.GlobalSec(globals) = result.output().global_sec.unwrap()
  assert_eq(globals.length(), 3)
  assert_true(result.output().export_sec is Some(_))
  assert_eq(count_loops(result.output()), 0)
}

///|
test "fuel v1 uses i64 static cost and records the site" {
  let rule = fuel_v1_rule("i32.add").unwrap()
  assert_eq(rule.base, 1L)
  let wasm_module = function_module([], [], [
    @lib.Instruction::i32_const(@lib.I32::new(1)),
    @lib.Instruction::i32_const(@lib.I32::new(2)),
    @lib.Instruction::i32_add(),
    @lib.Instruction::drop(),
  ])
  let result = fuel_pass_result(wasm_module, 10L)
  let body = output_body(result.output(), 0)
  assert_true(body.any(fn(item) { item is @lib.I64Const(_) }))
  assert_true(
    body.any(fn(item) {
      match item {
        @lib.I64Const(cost) => cost == @lib.I64::new(1L)
        _ => false
      }
    }),
  )
}

///|
test "fuel v1 accepts the i64 maximum and rejects grow without growth configuration" {
  assert_true(FuelConfig::new(9_223_372_036_854_775_807L) is Ok(_))
  assert_true(FuelConfig::new(-1L) is Err(_))
  let dynamic = function_module([], [], [
    @lib.Instruction::memory_grow(@lib.MemIdx::new(0U)),
  ])
  let config = FuelConfig::new(10L).unwrap()
  assert_true(
    Pass::apply(FuelPass::new(config), dynamic) is Err(UnsupportedFeature(_)),
  )
}
