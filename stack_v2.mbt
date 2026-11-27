///|
priv struct StackV2 {
  balance : @lib.GlobalIdx
  indirect_site : @lib.GlobalIdx
  fail : @lib.FuncIdx
  step : Int64
  signs : Int64
  imported : Int32
  plan : StackPlan
}

///|
fn StackV2::debit(self : Self, cost : Int64) -> Array[@lib.Instruction] {
  [stack_amount(self.step + cost), @lib.Instruction::i64_sub()]
}

///|
fn StackV2::reserve(
  self : Self,
  out : Array[@lib.Instruction],
  source : @lib.Instruction,
  site : @lib.Instruction,
  cost : Int64,
  scratch : @lib.LocalIdx,
  check : Bool,
  publish : Bool,
) -> Unit {
  if !check && !publish {
    return
  }
  out.push(source)
  out.append(self.debit(cost))
  if check {
    out.append([
      @lib.Instruction::local_tee(scratch),
      stack_amount(self.signs),
      @lib.Instruction::i64_and(),
      @lib.Instruction::i64_eqz(),
      @lib.Instruction::if_(
        @lib.BlockType::void_(),
        [],
        Some([
          @lib.Instruction::local_get(scratch),
          site,
          @lib.Instruction::call(self.fail),
        ]),
      ),
    ])
    if publish {
      out.push(@lib.Instruction::local_get(scratch))
    }
  }
  if publish {
    out.push(@lib.Instruction::global_set(self.balance))
  }
}

///|
fn StackV2::body(
  self : Self,
  body : Array[@lib.Instruction],
  calls : Array[(@lib.Instruction, Int32)],
  cursor : Ref[Int32],
  entry_balance : @lib.Instruction,
  scratch : @lib.LocalIdx,
  inherited_bound : Int64,
  reachable_at_entry : Bool,
) -> (Array[@lib.Instruction], Int64, Bool) raise StackAuditError {
  let out = []
  let mut bound = inherited_bound
  let mut reachable = reachable_at_entry
  for instruction in body {
    match instruction {
      @lib.Call(target) if func_number(target) <
        self.plan.sites.entries.length() => {
        let site = verify_stack_call(instruction, calls, cursor)
        let index = func_number(target)
        if reachable {
          let cost = self.plan.costs[index]
          let local_target = index >= self.imported
          let publish = !local_target ||
            !self.plan.sites.calls[index].is_empty()
          self.reserve(
            out,
            entry_balance,
            stack_const(site),
            cost,
            scratch,
            !local_target || cost > bound,
            publish,
          )
          if cost > bound {
            bound = cost
          }
        }
        out.push(instruction)
        if reachable && index < self.imported {
          out.append([entry_balance, @lib.Instruction::global_set(self.balance)])
        }
      }
      @lib.CallIndirect(_, _) => {
        let site = verify_stack_call(instruction, calls, cursor)
        if reachable {
          out.append([
            entry_balance,
            @lib.Instruction::global_set(self.balance),
            stack_const(site),
            @lib.Instruction::global_set(self.indirect_site),
          ])
        }
        out.push(instruction)
      }
      @lib.Block(ty, @lib.Expr(child)) =>
        out.push(
          @lib.Instruction::block(
            ty,
            @lib.Expr::new(
              self.body(
                child, calls, cursor, entry_balance, scratch, bound, reachable,
              ).0,
            ),
          ),
        )
      @lib.Loop(ty, @lib.Expr(child)) =>
        out.push(
          @lib.Instruction::loop_(
            ty,
            @lib.Expr::new(
              self.body(
                child, calls, cursor, entry_balance, scratch, bound, reachable,
              ).0,
            ),
          ),
        )
      @lib.If(ty, yes, no) => {
        let (left, left_bound, left_falls) = self.body(
          yes, calls, cursor, entry_balance, scratch, bound, reachable,
        )
        let (right, right_bound, right_falls) = match no {
          Some(other) => {
            let (code, next, falls) = self.body(
              other, calls, cursor, entry_balance, scratch, bound, reachable,
            )
            (Some(code), next, falls)
          }
          None => (None, bound, reachable)
        }
        out.push(@lib.Instruction::if_(ty, left, right))
        if reachable &&
          !contains_branch_instruction(yes) &&
          !no.map(contains_branch_instruction).unwrap_or(false) {
          match (left_falls, right_falls) {
            (true, true) =>
              bound = if left_bound < right_bound {
                left_bound
              } else {
                right_bound
              }
            (true, false) => bound = left_bound
            (false, true) => bound = right_bound
            (false, false) => reachable = false
          }
        }
      }
      @lib.Br(_) | @lib.BrTable(_, _) | @lib.Return | @lib.Unreachable => {
        reachable = false
        out.push(instruction)
      }
      _ => out.push(instruction)
    }
  }
  (out, bound, reachable)
}

///|
fn StackV2::wrapper(self : Self, wrapper : StackWrapper) -> @lib.Func {
  let @lib.FuncType(params, _) = wrapper.signature
  let scratch = @lib.LocalIdx::new(params.length().reinterpret_as_uint())
  let out = []
  let external = wrapper.entry_site is Some(_)
  let entry = @lib.LocalIdx::new((params.length() + 1).reinterpret_as_uint())
  let from_global = @lib.Instruction::global_get(self.balance)
  let site = match wrapper.entry_site {
    Some(site) => {
      out.append([from_global, @lib.Instruction::local_set(entry)])
      stack_const(site)
    }
    None => @lib.Instruction::global_get(self.indirect_site)
  }
  self.reserve(
    out,
    if external {
      @lib.Instruction::local_get(entry)
    } else {
      from_global
    },
    site,
    self.plan.costs[wrapper.target],
    scratch,
    true,
    wrapper.target < self.imported ||
    !self.plan.sites.calls[wrapper.target].is_empty(),
  )
  for index in 0..<params.length() {
    out.push(
      @lib.Instruction::local_get(
        @lib.LocalIdx::new(index.reinterpret_as_uint()),
      ),
    )
  }
  out.push(@lib.Instruction::call(func_index(wrapper.target)))
  let locals = [@lib.ValType::i64()]
  if external {
    locals.push(@lib.ValType::i64())
    out.append([
      @lib.Instruction::local_get(entry),
      @lib.Instruction::global_set(self.balance),
    ])
  }
  @lib.Func::new(@lib.Locals::from_types(locals), @lib.Expr::new(out))
}

///|
fn stack_v2_failure_definition(
  fuel : FuelState,
  units_sign : Int64,
) -> (@lib.RecType, @lib.Func) {
  let body = [
    stack_const(4),
    stack_const(5),
    @lib.Instruction::local_get(@lib.LocalIdx::new(0U)),
    stack_amount(units_sign),
    @lib.Instruction::i64_and(),
    @lib.Instruction::i64_eqz(),
    @lib.Instruction::i32_eqz(),
    @lib.Instruction::select(),
    @lib.Instruction::global_set(fuel.trap_global),
    @lib.Instruction::local_get(@lib.LocalIdx::new(1U)),
    @lib.Instruction::global_set(fuel.trap_site_global),
    @lib.Instruction::unreachable_(),
  ]
  let signature = @lib.CompType::func(
    [@lib.ValType::i64(), @lib.ValType::i32()],
    [],
  )
  (
    @lib.RecType::new(@lib.SubType::comp_type(signature)),
    @lib.Func::new(@lib.Locals::empty(), @lib.Expr::new(body)),
  )
}

///|
fn stack_v2_layout(
  plan : StackPlan,
) -> (Int64, Int64, Int64, Int64) raise StackAuditError {
  let mut max_cost = plan.max_units
  for cost in plan.costs {
    if cost > max_cost {
      max_cost = cost
    }
  }
  guard max_cost > 0L && plan.max_depth > 0L else {
    raise StackError("Stack v2 limits and frame costs must be positive")
  }
  let unit_bits = 64 - max_cost.clz()
  let depth_bits = 64 - plan.max_depth.clz()
  if unit_bits + depth_bits + 1 > 63 {
    raise StackError("packed Stack v2 counters exceed the i64 lane layout")
  }
  let units_sign = 1L << unit_bits
  let step = units_sign << 1
  let signs = units_sign | (step << depth_bits)
  let initial = plan.max_units + plan.max_depth * step
  if initial <= 0L || signs == 0L {
    raise StackError("invalid packed Stack v2 initial state")
  }
  (step, units_sign, signs, initial)
}

///|
fn emit_stack_v2(
  grown : @lib.Module,
  source : @lib.Module,
  fuel : FuelState,
  sources : Array[FuelFunctionPlan],
  plan : StackPlan,
) -> @lib.Module raise StackAuditError {
  let global_base = imported_global_count(grown) + defined_global_count(grown)
  let (step, units_sign, signs, initial) = stack_v2_layout(plan)
  let emitter : StackV2 = {
    balance: stack_global(global_base),
    indirect_site: stack_global(global_base + 1),
    fail: func_index(plan.first_function + plan.wrappers.length()),
    step,
    signs,
    imported: imported_functions(source),
    plan,
  }
  let @lib.GlobalSec(existing_globals) = grown.global_sec.unwrap()
  let globals = existing_globals.copy()
  globals.append([
    stack_counter(initial),
    @lib.Global::new(
      @lib.GlobalType::new(@lib.ValType::i32(), true),
      @lib.Expr::new([stack_const(0)]),
    ),
  ])
  let code = match grown.code_sec {
    Some(@lib.CodeSec(existing_code)) => existing_code.copy()
    None => []
  }
  for index, row in sources {
    let calls = plan.sites.calls[emitter.imported + index]
    if calls.is_empty() {
      continue
    }
    let @lib.Func(locals, @lib.Expr(body)) = code[index]
    let new_locals = locals.copy()
    let local_base = row.scratch_index + row.appended_locals.length()
    let scratch = @lib.LocalIdx::new(local_base.reinterpret_as_uint())
    new_locals.push(@lib.ValType::i64())
    let out = []
    let entry = if calls.any(fn(call) {
        match call.0 {
          @lib.Call(target) =>
            func_number(target) < emitter.imported ||
            !plan.sites.calls[func_number(target)].is_empty()
          @lib.CallIndirect(_, _) => true
          _ => false
        }
      }) {
      let entry = @lib.LocalIdx::new((local_base + 1).reinterpret_as_uint())
      new_locals.push(@lib.ValType::i64())
      out.append([
        @lib.Instruction::global_get(emitter.balance),
        @lib.Instruction::local_set(entry),
      ])
      @lib.Instruction::local_get(entry)
    } else {
      @lib.Instruction::global_get(emitter.balance)
    }
    let cursor = Ref(0)
    let (rewritten, _, _) = emitter.body(
      body, calls, cursor, entry, scratch, 0L, true,
    )
    if cursor.val != calls.length() {
      raise StackError("Stack v2 lost a source call")
    }
    out.append(rewritten)
    code[index] = @lib.Func::new(new_locals, @lib.Expr::new(out))
  }
  let types = match grown.type_sec {
    Some(@lib.TypeSec(entries)) => entries.copy()
    None => []
  }
  let signatures = match grown.func_sec {
    Some(@lib.FuncSec(entries)) => entries.copy()
    None => []
  }
  let external = Array::make(plan.sites.entries.length(), None)
  let indirect = Array::make(plan.sites.entries.length(), None)
  let env = @validate.Env::new().with_module(source)
  for index, wrapper in plan.wrappers {
    guard env.get_functypeidx_by_funcidx(func_index(wrapper.target)) is Some(_) else {
      raise StackError("Stack v2 wrapper is missing its source type")
    }
    let reference = Some(func_index(plan.first_function + index))
    if wrapper.entry_site is Some(_) {
      external[wrapper.target] = reference
    } else {
      indirect[wrapper.target] = reference
    }
    guard env.get_functypeidx_by_funcidx(func_index(wrapper.target)) is Some(ty) else {
      raise StackError("Stack v2 wrapper is missing its original type")
    }
    signatures.push(ty)
    code.push(emitter.wrapper(wrapper))
  }
  let (failure_type, failure_function) = stack_v2_failure_definition(
    fuel, units_sign,
  )
  signatures.push(@lib.TypeIdx::new(type_count(grown).reinterpret_as_uint()))
  types.push(failure_type)
  code.push(failure_function)
  let output = grown
    .with_global_sec(@lib.GlobalSec::new(globals))
    .with_type_sec(@lib.TypeSec::new(types))
    .with_func_sec(@lib.FuncSec::new(signatures))
    .with_code_sec(@lib.CodeSec::new(code))
  rewrite_stack_references(output, external, indirect)
}

///|
fn apply_stack_v2(
  grown : @lib.Module,
  source : @lib.Module,
  fuel : FuelState,
  sources : Array[FuelFunctionPlan],
  plan : StackPlan,
  config : StackConfig,
  stage : (String) -> Unit,
) -> Result[PassResult, InstrumentError] {
  try {
    let output = emit_stack_v2(grown, source, fuel, sources, plan)
    stage("validate_stack")
    if validate_wasm(output, "StackPass") is Err(error) {
      return Err(error)
    }
    Ok(
      PassResult::new("StackPass", output, notes=[
        "stack: \{stack_model_version}, units=\{config.max_units}, depth=\{config.max_depth}",
      ]),
    )
  } catch {
    StackError(reason) => Err(StackAnalysisFailed(reason))
  }
}
