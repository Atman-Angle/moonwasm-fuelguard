///|
fn analysis_fixture() -> @lib.Module {
  let fuel = function_module([], [], [
    @lib.Instruction::i32_const(1),
    @lib.Instruction::i32_const(2),
    @lib.Instruction::i32_add(),
    @lib.Instruction::drop(),
  ])
  fuel
}

///|
test "analysis is deterministic and preserves dense function indexes" {
  let input = analysis_fixture()
  let before = encode_wasm(input).unwrap()
  let first = analyze_semantic(input)
  let second = analyze_semantic(input)
  let after = encode_wasm(input).unwrap()
  assert_eq(before, after)
  assert_eq(first.functions.length(), 1)
  assert_eq(first.sites.length(), second.sites.length())
  assert_eq(first.sites[0].id, second.sites[0].id)
  assert_eq(first.sites[0].first_ordinal, 0)
  assert_eq(first.functions[0].instruction_count, 4)
  assert_eq(first.functions[0].instructions[2].key, "i32.add")
  assert_eq(first.module_index.function_type_indices[0], 0)
}

///|
test "production analysis can omit retained instruction facts" {
  let source = function_module([], [], [
    @lib.Instruction::i32_const(@lib.I32::new(1)),
    @lib.Instruction::if_(
      @lib.BlockType::void_(),
      [@lib.Instruction::i32_const(@lib.I32::new(2)), @lib.Instruction::drop()],
      Some([@lib.Instruction::nop()]),
    ),
    @lib.Instruction::loop_(
      @lib.BlockType::void_(),
      @lib.Expr::new([@lib.Instruction::nop()]),
    ),
  ])
  let full = analyze_semantic(source)
  let lean = analyze_semantic_impl(source, false, false, fn(_) { () })
  let @lib.CodeSec(functions) = source.code_sec.unwrap()
  let @lib.Func(_, body) = functions[0]
  let visited : Array[String] = []
  visit_instructions(body, fn(instruction) {
    visited.push(instruction_key(instruction))
  })
  assert_eq(visited, full.functions[0].instructions.map(fn(item) { item.key }))
  assert_eq(
    lean.functions[0].instruction_count,
    full.functions[0].instruction_count,
  )
  assert_eq(lean.functions[0].static_cost, full.functions[0].static_cost)
  assert_eq(lean.functions[0].loop_count, full.functions[0].loop_count)
  assert_eq(lean.functions[0].instructions.length(), 0)
}

///|
test "instrument plan freezes structure without changing old indexes" {
  let semantic = analyze_semantic(analysis_fixture())
  let plan = plan_instrumentation(semantic)
  assert_eq(plan.added_function_count, 0)
  assert_eq(plan.added_global_count, 0)
  assert_eq(plan.functions[0].function_index, 0)
  assert_eq(plan.functions[0].signature_type_index, 0)
  assert_eq(plan.functions[0].template_id, "p0")
  assert_eq(plan.functions[0].appended_local_count, 1)
  assert_true(plan.functions[0].output_capacity >= 4)
  assert_eq(plan.first_added_function_index, 1)
}
