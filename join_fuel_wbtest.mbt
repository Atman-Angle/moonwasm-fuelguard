///|
test "join spans follow targeted exits and conditional fallthrough" {
  let block = @lib.Instruction::block(
    @lib.BlockType::void_(),
    @lib.Expr::new([
      stack_const(0),
      @lib.Instruction::br_if(@lib.LabelIdx::new(0U)),
      @lib.Instruction::nop(),
    ]),
  )
  let body = @lib.Expr::new([
    @lib.Instruction::nop(),
    block,
    @lib.Instruction::nop(),
  ])
  let spans = plan_join_spans(body, 6)
  assert_eq(spans.map(fn(span) { span.map(fn(s) { s.count }).unwrap_or(0) }), [
    4, 0, 0, 0, 1, 1,
  ])
}

///|
test "join span continues through an if with one lexical fallthrough" {
  let choice = @lib.Instruction::if_(
    @lib.BlockType::void_(),
    [@lib.Instruction::return_()],
    Some([@lib.Instruction::nop()]),
  )
  let body = @lib.Expr::new([stack_const(0), choice, @lib.Instruction::nop()])
  let spans = plan_join_spans(body, 5)
  assert_eq(spans.map(fn(span) { span.map(fn(s) { s.count }).unwrap_or(0) }), [
    2, 0, 1, 2, 0,
  ])
}

///|
test "join spans pack weighted barriers, cap runs and isolate grow" {
  let input = [
    stack_const(0),
    @lib.Instruction::i32_load(
      @lib.MemArg::new(@lib.U32::new(0U), None, @lib.U64::new(0UL)),
    ),
    @lib.Instruction::drop(),
  ]
  input.append(Array::make(18, @lib.Instruction::nop()))
  input.append([
    @lib.Instruction::memory_grow(@lib.MemIdx::new(0U)),
    @lib.Instruction::nop(),
  ])
  let spans = plan_join_spans(@lib.Expr::new(input), 23)
  let first = spans[0].unwrap()
  assert_eq(first.count, 19)
  assert_eq(first.total, 21L)
  assert_eq(first.weights & 511L, 1L | (3L << 3) | (1L << 6))
  assert_eq(spans[19].unwrap().count, 2)
  assert_eq(spans[21].unwrap().total, 8L)
  assert_eq(spans[21].unwrap().weights, 6L)
  assert_eq(spans[22].unwrap().count, 1)
}

///|
test "fuel-v2 spans cross static and dynamic operations until control transfers" {
  let input = Array::make(23, @lib.Instruction::nop())
  input.append([
    @lib.Instruction::memory_grow(@lib.MemIdx::new(0U)),
    @lib.Instruction::drop(),
    @lib.Instruction::return_(),
    @lib.Instruction::nop(),
  ])
  let spans = plan_join_spans(@lib.Expr::new(input), 27, fuel_v2=true)
  assert_eq(spans[0].unwrap().count, 26)
  assert_eq(spans[0].unwrap().total, 33L)
  assert_eq(spans[0].unwrap().weights, 0L)
  assert_true(spans[23] is None)
  assert_eq(spans[26].unwrap().count, 1)
}

///|
test "fuel-v2 emits a single inline debit for a long span and site-only failure" {
  let source = function_module([], [], Array::make(25, @lib.Instruction::nop()))
  let fuel = FuelConfig::new(24L).unwrap()
  let guards = GuardConfig::new().unwrap()
  let stack = Some(StackConfig::new(5000L, 32L).unwrap())
  let pipeline = Pipeline::builtin(
    InstrumentConfig::new(fuel, guards, stack~, codegen=FuelV2),
  )
  let module_ = pipeline.run(source).unwrap().output()
  let body = output_body(module_, 0)
  assert_eq(body.length(), 8 + 25)
  assert_eq(body[1], stack_amount(25L))
  assert_true(
    body[7]
    is @lib.If(
      _,
      [],
      Some([@lib.I32Const(@lib.I32(1)), @lib.Call(@lib.FuncIdx(1U))]),
    ),
  )
  assert_eq(output_body(module_, 1).length(), 5)
  let bytes = encode_wasm(module_).unwrap()
  assert_true(verify_production_artifact(bytes) is Ok(_))
  assert_true(
    verify_builtin_artifact(bytes, ProductionV1, codegen=FuelV2) is Ok(_),
  )
  assert_true(
    verify_builtin_artifact(bytes, ProductionV1, codegen=JoinSpanCompactV2)
    is Err(_),
  )
}

///|
test "join-span model and old codegen markers cannot be interchanged" {
  let source = function_module([], [], [@lib.Instruction::nop()])
  let fuel = FuelConfig::new(MAX_FUEL).unwrap()
  let guards = GuardConfig::new().unwrap()
  let stack = Some(StackConfig::new(5000L, 32L).unwrap())
  let join = InstrumentConfig::new(fuel, guards, stack~, codegen=JoinSpan)
  let baseline = InstrumentConfig::new(fuel, guards, stack~, codegen=P2Prefix)
  let joined = run_builtin(join, source, false, false, fn(_) { () })
    .unwrap()
    .output()
  assert_eq(output_locals(joined, 0).length(), 0)
  assert_eq(output_body(joined, 0).length(), 9)
  assert_true(output_body(joined, 0)[7] is @lib.If(_, _, None))
  assert_eq(defined_function_count(joined), 2)
  let join_bytes = encode_wasm(joined).unwrap()
  let old_bytes = encode_wasm(
    run_builtin(baseline, source, false, false, fn(_) { () }).unwrap().output(),
  ).unwrap()
  assert_true(
    verify_builtin_artifact(join_bytes, ProductionV1, codegen=JoinSpan) is Ok(_),
  )
  assert_true(
    verify_builtin_artifact(old_bytes, ProductionV1, codegen=JoinSpan) is Err(_),
  )
  assert_true(
    verify_builtin_artifact(join_bytes, ProductionV1, codegen=P2Prefix)
    is Err(_),
  )
}

///|
test "join replay publishes paid balance before both diagnostics and trap" {
  let source = function_module([], [], [@lib.Instruction::nop()])
  let state = add_fuel_state(source, 1L).unwrap()
  let (_, @lib.Func(_, @lib.Expr(body))) = join_failure_definition(state)
  let suffix = body[body.length() - 7:]
  assert_eq(suffix.to_owned(), [
    @lib.Instruction::local_get(@lib.LocalIdx::new(1U)),
    @lib.Instruction::global_set(state.fuel_global),
    stack_const(1),
    @lib.Instruction::global_set(state.trap_global),
    @lib.Instruction::local_get(@lib.LocalIdx::new(0U)),
    @lib.Instruction::global_set(state.trap_site_global),
    @lib.Instruction::unreachable_(),
  ])
}
