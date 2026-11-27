///|
test "fuel-v1 distinguishes weights, boundaries and unsupported opcodes" {
  assert_eq(fuel_v1_version, "fuel-v1")
  let rejected = [
    "v128.load", "v128.store", "v128.and", "v128.or", "v128.any_true", "i8x16.eq",
    "i8x16.all_true", "i8x16.shuffle", "i16x8.splat", "i16x8.eq", "i16x8.sub", "i16x8.le_u",
    "i16x8.lt_u", "i16x8.bitmask", "i32x4.extract_lane", "i64x2.extract_lane",
  ]
  for opcode in rejected {
    assert_true(fuel_v1_rule(opcode) is None)
  }
  assert_true(fuel_v1_rule("v128.const") is None)
  assert_true(fuel_v1_rule("i32.atomic.load") is None)
  assert_true(fuel_v1_rule("call_ref") is None)
}

///|
test "fuel-v1 widens unsigned lengths and charges only the dynamic increment" {
  guard fuel_v1_rule("memory.grow") is Some(rule) else { fail("missing grow") }
  assert_eq(rule.base, 8L)
  assert_eq(rule.dynamic_surcharge(0U), Some(0L))
  assert_eq(rule.dynamic_surcharge(1U), Some(64L))
  assert_eq(rule.dynamic_surcharge(4_294_967_295U), Some(274_877_906_880L))
}

///|
test "fuel-v1 dynamic rule groups use their specified unit" {
  let vectors = [
    ("memory.copy", 4L, 1L),
    ("memory.fill", 4L, 1L),
    ("memory.init", 4L, 1L),
    ("table.copy", 4L, 2L),
    ("table.fill", 4L, 2L),
    ("table.init", 4L, 2L),
    ("memory.grow", 8L, 64L),
    ("table.grow", 8L, 4L),
  ]
  for vector in vectors {
    let (opcode, base, rate) = vector
    guard fuel_v1_rule(opcode) is Some(rule) else { fail(opcode) }
    assert_eq(rule.base, base)
    assert_true(rule.boundary is Barrier)
    assert_eq(rule.dynamic_surcharge(1U), Some(rate))
    assert_true(rule.dynamic_surcharge(4_294_967_295U) is Some(_))
  }
}

///|
test "fuel-v1 rejects mathematical i64 overflow before multiplication or addition" {
  let max = 9_223_372_036_854_775_807L
  assert_eq(fuel_v1_checked_cost(1L, 2L, max / 2L), Some(max))
  assert_eq(fuel_v1_checked_cost(2L, 2L, max / 2L), None)
  assert_eq(fuel_v1_checked_cost(0L, 2L, max / 2L + 1L), None)
  assert_eq(fuel_v1_checked_cost(max, 0L, max), Some(max))
  assert_eq(fuel_v1_checked_cost(0L, 1L, -1L), None)
}

///|
test "fuel-v2 dynamic charge emits a same-site Fuel trap before overflowing math" {
  let out : Array[@lib.Instruction] = []
  let fuel = @lib.GlobalIdx::new(0U)
  let code = @lib.GlobalIdx::new(1U)
  let site = @lib.GlobalIdx::new(2U)
  let length = @lib.LocalIdx::new(1U)
  append_dynamic_charge(
    out,
    {
      wasm_module: @lib.Module::new(),
      fuel_global: fuel,
      trap_global: code,
      trap_site_global: site,
      charge_helper: None,
      prefix_failure: None,
      join_failure: None,
      join_shared: None,
      compact_join: false,
      fuel_v2: true,
      coalesce_join_publications: false,
    },
    @lib.LocalIdx::new(0U),
    length,
    { base: 1L, per_unit: 2_147_483_649L, boundary: Barrier, },
    @lib.Instruction::i32_const(@lib.I32::new(37)),
  )
  guard out[:]
    is [
      @lib.LocalGet(operand),
      @lib.I64Const(@lib.I64(limit)),
      @lib.I64GtU,
      @lib.If(_, failure, None),
      @lib.GlobalGet(balance),
      ..,
    ] else {
    fail("expected an unsigned overflow check before debit")
  }
  assert_eq(operand, length)
  assert_eq(limit, 4_294_967_294L)
  assert_eq(balance, fuel)
  assert_eq(failure, [
    @lib.Instruction::i32_const(@lib.I32::new(1)),
    @lib.Instruction::global_set(code),
    @lib.Instruction::i32_const(@lib.I32::new(37)),
    @lib.Instruction::global_set(site),
    @lib.Instruction::unreachable_(),
  ])
}

///|
test "fuel-v2 omits dynamic overflow guard when every wasm32 length is safe" {
  let out : Array[@lib.Instruction] = []
  let fuel = @lib.GlobalIdx::new(0U)
  let length = @lib.LocalIdx::new(1U)
  append_dynamic_charge(
    out,
    {
      wasm_module: @lib.Module::new(),
      fuel_global: fuel,
      trap_global: @lib.GlobalIdx::new(1U),
      trap_site_global: @lib.GlobalIdx::new(2U),
      charge_helper: None,
      prefix_failure: None,
      join_failure: None,
      join_shared: None,
      compact_join: false,
      fuel_v2: true,
      coalesce_join_publications: false,
    },
    @lib.LocalIdx::new(0U),
    length,
    { base: 8L, per_unit: 64L, boundary: Barrier, },
    @lib.Instruction::i32_const(@lib.I32::new(37)),
  )
  guard out[:]
    is [
      @lib.GlobalGet(balance),
      @lib.LocalGet(first),
      @lib.I64Const(@lib.I64(64L)),
      @lib.I64Mul,
      @lib.I64Sub,
      @lib.LocalTee(_),
      @lib.I64Const(@lib.I64(0L)),
      @lib.I64LtS,
      ..,
    ] else {
    fail("safe wasm32 dynamic fee should debit the single computed surcharge")
  }
  assert_eq(balance, fuel)
  assert_eq(first, length)
  assert_eq(
    out.filter(fn(instruction) { instruction is @lib.I64Mul }).length(),
    1,
  )
}

///|
test "P1 overflow guards the unsigned length before calling charge" {
  let out : Array[@lib.Instruction] = []
  let state = {
    ..add_fuel_state(@lib.Module::new(), 100L).unwrap(),
    charge_helper: Some(func_index(1)),
    prefix_failure: None,
  }
  let length = @lib.LocalIdx::new(1U)
  let site = @lib.Instruction::i32_const(@lib.I32::new(37))
  append_dynamic_charge(
    out,
    state,
    @lib.LocalIdx::new(0U),
    length,
    { base: 1L, per_unit: 2_147_483_649L, boundary: Barrier, },
    site,
  )
  guard out[:]
    is [
      @lib.LocalGet(operand),
      @lib.I64Const(@lib.I64(limit)),
      @lib.I64GtU,
      @lib.If(_, failure, None),
      @lib.LocalGet(debit_operand),
      @lib.I64Const(@lib.I64(rate)),
      @lib.I64Mul,
      @lib.I32Const(@lib.I32(id)),
      @lib.Call(helper),
    ] else {
    fail("expected overflow check followed by a shared debit")
  }
  assert_eq(operand, length)
  assert_eq(debit_operand, length)
  assert_eq(limit, 4_294_967_294L)
  assert_eq(rate, 2_147_483_649L)
  assert_eq(id, 37)
  assert_eq(helper, func_index(1))
  assert_eq(
    failure,
    charge_trap(state.trap_global, state.trap_site_global, TrapCode::Fuel, site),
  )
}
