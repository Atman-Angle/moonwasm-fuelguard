/// Dynamic surcharge templates shared by S07 and the later Growth pass.

///|
priv struct DynamicLocals {
  length : @lib.LocalIdx
  widened_length : @lib.LocalIdx
}

///|
fn dynamic_key_is_supported(key : String) -> Bool {
  match key {
    "memory.copy"
    | "memory.fill"
    | "memory.init"
    | "table.copy"
    | "table.init"
    | "table.fill" => true
    _ => false
  }
}

///|
fn charge_trap(
  trap_global : @lib.GlobalIdx,
  trap_site_global : @lib.GlobalIdx,
  code : TrapCode,
  site : @lib.Instruction,
) -> Array[@lib.Instruction] {
  [
    @lib.Instruction::i32_const(@lib.I32::new(code.to_code())),
    @lib.Instruction::global_set(trap_global),
    site,
    @lib.Instruction::global_set(trap_site_global),
    @lib.Instruction::unreachable_(),
  ]
}

///|
fn append_dynamic_charge(
  out : Array[@lib.Instruction],
  state : FuelState,
  fuel_temp : @lib.LocalIdx,
  widened_length : @lib.LocalIdx,
  rule : FuelV1Rule,
  site : @lib.Instruction,
  cache~ : @lib.LocalIdx? = None,
) -> Unit {
  if rule.per_unit == 0L {
    return
  }
  let maximum = 9_223_372_036_854_775_807L
  let limit = (maximum - rule.base) / rule.per_unit
  if rule.dynamic_surcharge(4_294_967_295U) is None {
    out.push(@lib.Instruction::local_get(widened_length))
    out.push(@lib.Instruction::i64_const(@lib.I64::new(limit)))
    out.push(@lib.Instruction::i64_gt_u())
    let overflow_body = charge_trap(
      state.trap_global,
      state.trap_site_global,
      TrapCode::Fuel,
      site,
    )
    out.push(
      @lib.Instruction::if_(@lib.BlockType::void_(), overflow_body, None),
    )
  }
  if state.charge_helper is Some(helper) {
    out.append([
      @lib.Instruction::local_get(widened_length),
      @lib.Instruction::i64_const(@lib.I64::new(rule.per_unit)),
      @lib.Instruction::i64_mul(),
      site,
      @lib.Instruction::call(helper),
    ])
    return
  }
  match cache {
    Some(balance_local) => out.push(@lib.Instruction::local_get(balance_local))
    None => out.push(@lib.Instruction::global_get(state.fuel_global))
  }
  out.push(@lib.Instruction::local_get(widened_length))
  out.push(@lib.Instruction::i64_const(@lib.I64::new(rule.per_unit)))
  out.push(@lib.Instruction::i64_mul())
  // The checked upper bound makes the surcharge representable. Subtract once
  // and inspect the signed result instead of multiplying the surcharge twice.
  out.push(@lib.Instruction::i64_sub())
  out.push(@lib.Instruction::local_tee(fuel_temp))
  out.push(@lib.Instruction::i64_const(@lib.I64::new(0L)))
  out.push(@lib.Instruction::i64_lt_s())
  out.push(
    @lib.Instruction::if_(
      @lib.BlockType::void_(),
      charge_trap(
        state.trap_global,
        state.trap_site_global,
        TrapCode::Fuel,
        site,
      ),
      None,
    ),
  )
  out.push(@lib.Instruction::local_get(fuel_temp))
  match cache {
    Some(balance_local) => out.push(@lib.Instruction::local_set(balance_local))
    None => out.push(@lib.Instruction::global_set(state.fuel_global))
  }
}

///|
fn append_dynamic_operation(
  out : Array[@lib.Instruction],
  original : @lib.Instruction,
  locals : DynamicLocals,
  state : FuelState,
  fuel_temp : @lib.LocalIdx,
  rule : FuelV1Rule,
  site : Int32,
  cache~ : @lib.LocalIdx? = None,
) -> Unit {
  // Keep the first two operands on the stack, including the externref for table.fill.
  out.push(@lib.Instruction::local_set(locals.length))
  out.push(@lib.Instruction::local_get(locals.length))
  out.push(@lib.Instruction::i64_extend_i32u())
  out.push(@lib.Instruction::local_set(locals.widened_length))
  append_dynamic_charge(
    out,
    state,
    fuel_temp,
    locals.widened_length,
    rule,
    @lib.Instruction::i32_const(@lib.I32::new(site)),
    cache~,
  )
  out.push(@lib.Instruction::local_get(locals.length))
  out.push(original)
}
