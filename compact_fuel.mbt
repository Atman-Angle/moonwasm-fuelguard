///|
fn prefix_failure_definition(state : FuelState) -> (@lib.RecType, @lib.Func) {
  let site = @lib.Instruction::local_get(@lib.LocalIdx::new(0U))
  let budget = @lib.Instruction::local_get(@lib.LocalIdx::new(1U))
  let prefix = @lib.Instruction::local_get(@lib.LocalIdx::new(2U))
  let paid = @lib.LocalIdx::new(3U)
  let body = [
    budget,
    prefix,
    budget,
    prefix,
    @lib.Instruction::i64_lt_u(),
    @lib.Instruction::select(),
    @lib.Instruction::local_set(paid),
    budget,
    @lib.Instruction::local_get(paid),
    @lib.Instruction::i64_sub(),
    @lib.Instruction::global_set(state.fuel_global),
    @lib.Instruction::i32_const(@lib.I32::new(TrapCode::Fuel.to_code())),
    @lib.Instruction::global_set(state.trap_global),
    site,
    @lib.Instruction::local_get(paid),
    @lib.Instruction::i32_wrap_i64(),
    @lib.Instruction::i32_add(),
    @lib.Instruction::global_set(state.trap_site_global),
    @lib.Instruction::unreachable_(),
  ]
  let signature = @lib.CompType::func(
    [@lib.ValType::i32(), @lib.ValType::i64(), @lib.ValType::i64()],
    [],
  )
  (
    @lib.RecType::new(@lib.SubType::comp_type(signature)),
    @lib.Func::new(
      @lib.Locals::from_types([@lib.ValType::i64()]),
      @lib.Expr::new(body),
    ),
  )
}

///|
fn append_prefix_charge(
  out : Array[@lib.Instruction],
  state : FuelState,
  helper : @lib.FuncIdx,
  temp : @lib.LocalIdx,
  first_site : Int32,
  prefix : Int64,
  total : Int64,
) -> Unit {
  let cost = @lib.Instruction::i64_const(@lib.I64::new(total))
  let budget = @lib.Instruction::local_get(temp)
  let failure = @lib.Instruction::if_(
    @lib.BlockType::void_(),
    [
      @lib.Instruction::i32_const(@lib.I32::new(first_site)),
      budget,
      @lib.Instruction::i64_const(@lib.I64::new(prefix)),
      @lib.Instruction::call(helper),
    ],
    None,
  )
  out.append([
    @lib.Instruction::global_get(state.fuel_global),
    @lib.Instruction::local_tee(temp),
    cost,
    @lib.Instruction::i64_lt_s(),
    failure,
    budget,
    cost,
    @lib.Instruction::i64_sub(),
    @lib.Instruction::global_set(state.fuel_global),
  ])
}

///|
// A span contains unit-cost non-trapping operations and at most one terminal
// instruction. Neither a nested body nor a dynamic surcharge is part of it.
fn prefix_charge_span(
  instructions : Array[@lib.Instruction],
  start : Int32,
  first : FuelV1Rule,
) -> (Int32, Int64, Int64) {
  let mut rule = first
  for index in start..<instructions.length() {
    let prefix = (index - start).to_int64()
    if !(rule.boundary is Prefix && rule.base == 1L && rule.per_unit == 0L) {
      return (index + 1, prefix, prefix + rule.base)
    }
    let next = index + 1
    if next == instructions.length() {
      return (next, prefix + 1L, prefix + 1L)
    }
    guard fuel_v1_rule(instruction_key(instructions[next])) is Some(next_rule) &&
      next_rule.base > 0L else {
      return (next, prefix + 1L, prefix + 1L)
    }
    rule = next_rule
  }
  abort("empty prefix charge span")
}
