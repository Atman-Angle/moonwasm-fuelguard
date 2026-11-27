///|
// Close the source call graph from every loop-containing function. An indirect
// call can reach any eligible element target, and a host call can re-enter an
// export. Expanding either edge set once is sufficient for this closure.
fn join_hot_functions(
  source : @lib.Module,
  semantic : SemanticPlan,
  stack : StackSites,
) -> Array[Bool] {
  let module_index = semantic.module_index
  let hot = Array::make(module_index.function_count(), false)
  let pending = []
  for function in semantic.functions {
    if function.loop_count > 0 {
      pending.push(function.function_index)
    }
  }
  let mut indirect_seen = false
  let mut host_seen = false
  while pending.pop() is Some(index) {
    if hot[index] {
      continue
    }
    hot[index] = true
    if index < module_index.imported_function_count {
      if !host_seen {
        host_seen = true
        pending.append(module_index.export_function_indices)
      }
      continue
    }
    for (instruction, _) in stack.calls[index] {
      match instruction {
        @lib.Call(target) => pending.push(func_number(target))
        @lib.CallIndirect(_, _) if !indirect_seen => {
          indirect_seen = true
          let targets = audit_table_targets(source) catch {
            // Stack planning still reports the invalid table. Cold selection
            // makes no assumptions about targets it could not resolve.
            _ => return Array::make(hot.length(), true)
          }
          pending.append(targets)
        }
        _ => ()
      }
    }
  }
  hot
}

///|
// A cold call site passes just the site and compact profile. Use the same
// signed debit as the inline guard and the same failure replay.
fn join_shared_definition(state : FuelState) -> (@lib.RecType, @lib.Func) {
  let site = @lib.Instruction::local_get(@lib.LocalIdx::new(0U))
  let profile = @lib.Instruction::local_get(@lib.LocalIdx::new(1U))
  let balance = @lib.LocalIdx::new(2U)
  let body = [
    @lib.Instruction::global_get(state.fuel_global),
    profile,
    stack_amount(JOIN_TOTAL_MASK),
    @lib.Instruction::i64_and(),
    @lib.Instruction::i64_sub(),
    @lib.Instruction::local_tee(balance),
    stack_amount(0L),
    @lib.Instruction::i64_lt_s(),
    @lib.Instruction::if_(
      @lib.BlockType::void_(),
      [
        site,
        @lib.Instruction::local_get(balance),
        profile,
        @lib.Instruction::call(state.join_failure.unwrap()),
      ],
      None,
    ),
    @lib.Instruction::local_get(balance),
    @lib.Instruction::global_set(state.fuel_global),
  ]
  let signature = @lib.CompType::func(
    [@lib.ValType::i32(), @lib.ValType::i64()],
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
