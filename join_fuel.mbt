///|
// Nineteen three-bit weights, followed by the total in the high seven bits.
// Zero terminates replay. Codes 1–5 are literal and 6 denotes grow's weight 8.
pub const JOIN_SPAN_LIMIT : Int32 = 19

///|
const JOIN_WEIGHT_BITS : Int32 = 57

///|
const JOIN_WEIGHT_MASK : Int64 = (1L << JOIN_WEIGHT_BITS) - 1L

///|
const JOIN_TOTAL_BITS : Int32 = 7

///|
const JOIN_TOTAL_MASK : Int64 = (1L << JOIN_TOTAL_BITS) - 1L

///|
priv struct JoinSpan {
  count : Int32
  total : Int64
  weights : Int64
}

///|
priv struct JoinPlanner {
  spans : Array[JoinSpan?]
  targets : Array[JoinTarget]
  fuel_v2 : Bool
  mut site : Int32
  mut active : JoinSpan
}

///|
priv struct JoinTarget {
  mut referenced : Bool
  mut reached : Bool
}

///|
fn JoinTarget::new() -> JoinTarget {
  { referenced: false, reached: false, }
}

///|
fn JoinPlanner::cut(self : Self) -> Unit {
  let count = self.active.count
  if count > 0 {
    self.spans[self.site - count] = Some(self.active)
    self.active = { count: 0, total: 0L, weights: 0L, }
  }
}

///|
fn JoinPlanner::target(
  self : Self,
  label : @lib.LabelIdx,
  reachable_from : Int32,
) -> Unit {
  let @lib.LabelIdx(depth) = label
  let index = self.targets.length() - 1 - depth.reinterpret_as_int()
  let target = self.targets[index]
  target.referenced = true
  if index >= reachable_from {
    target.reached = true
  }
}

///|
// The source was validated before planning. The depth stack resolves forward
// exits as each block closes. Loop backedges already enter at a mandatory cut.
fn JoinPlanner::body(
  self : Self,
  instructions : Array[@lib.Instruction],
  reachable_from : Int32,
) -> Bool {
  let mut falls_through = true
  for instruction in instructions {
    let key = instruction_key(instruction)
    guard fuel_v1_rule(key) is Some(rule) else {
      self.cut()
      continue
    }
    let boundary = join_boundary(key, rule, self.fuel_v2)
    if boundary is Dynamic {
      self.cut()
    }
    if rule.base > 0L {
      let { count, total, weights, } = self.active
      let code = if rule.base == 8L { 6L } else { rule.base }
      self.active = {
        count: count + 1,
        total: total + rule.base,
        weights: if self.fuel_v2 {
          0L
        } else {
          weights | (code << (3 * count))
        },
      }
      self.site += 1
      if !self.fuel_v2 && self.active.count == JOIN_SPAN_LIMIT {
        self.cut()
      }
    }
    // A dead suffix cannot reach a label already in scope. Nested structures
    // still compute their own relative reachability for their recorded spans.
    let floor = if falls_through {
      reachable_from
    } else {
      self.targets.length()
    }
    let next = match instruction {
      @lib.Block(_, @lib.Expr(child)) => {
        let targeted = JoinTarget::new()
        self.targets.push(targeted)
        let falls = self.body(child, floor)
        ignore(self.targets.pop())
        if targeted.referenced {
          self.cut()
        }
        falls || targeted.reached
      }
      @lib.Loop(_, @lib.Expr(child)) => {
        self.cut()
        self.targets.push(JoinTarget::new())
        let falls = self.body(child, floor)
        ignore(self.targets.pop())
        falls
      }
      @lib.If(_, yes, no) => {
        self.cut()
        let targeted = JoinTarget::new()
        self.targets.push(targeted)
        let then_falls = self.body(yes, floor)
        self.cut()
        let else_falls = match no {
          Some(other) => self.body(other, floor)
          None => true
        }
        ignore(self.targets.pop())
        // The explicit else can continue in source order when the then arm
        // cannot fall through and no branch can also enter at the if exit.
        if then_falls || targeted.referenced || no is None {
          self.cut()
        }
        then_falls || else_falls || targeted.reached
      }
      @lib.Br(label) => {
        self.target(label, floor)
        false
      }
      @lib.BrIf(label) => {
        self.target(label, floor)
        true
      }
      @lib.BrTable(labels, fallback) => {
        for label in labels {
          self.target(label, floor)
        }
        self.target(fallback, floor)
        false
      }
      @lib.Return | @lib.Unreachable => false
      _ => true
    }
    if boundary is (Transfer | Dynamic) {
      self.cut()
    }
    falls_through = falls_through && next
  }
  falls_through
}

///|
fn plan_join_spans(
  body : @lib.Expr,
  sites : Int32,
  fuel_v2~ : Bool = false,
) -> Array[JoinSpan?] {
  let @lib.Expr(instructions) = body
  let planner : JoinPlanner = {
    spans: Array::make(sites, None),
    targets: [JoinTarget::new()],
    fuel_v2,
    site: 0,
    active: { count: 0, total: 0L, weights: 0L, },
  }
  ignore(planner.body(instructions, 0))
  planner.cut()
  planner.spans
}

///|
fn append_join_charge(
  out : Array[@lib.Instruction],
  state : FuelState,
  helper : @lib.FuncIdx,
  first_site : Int32,
  span : JoinSpan,
  cache~ : @lib.LocalIdx? = None,
) -> Unit {
  let failure = [stack_const(first_site)]
  if !state.fuel_v2 {
    let profile = if state.compact_join {
      (span.weights << JOIN_TOTAL_BITS) | span.total
    } else {
      span.weights | (span.total << JOIN_WEIGHT_BITS)
    }
    if state.join_shared is Some(shared) {
      out.append([
        stack_const(first_site),
        stack_amount(profile),
        @lib.Instruction::call(shared),
      ])
      return
    }
    failure.push(
      match cache {
        Some(balance_local) => @lib.Instruction::local_get(balance_local)
        None => @lib.Instruction::global_get(state.fuel_global)
      },
    )
    failure.push(stack_amount(profile))
  }
  failure.push(@lib.Instruction::call(helper))
  let balance = match cache {
    Some(balance_local) => @lib.Instruction::local_get(balance_local)
    None => @lib.Instruction::global_get(state.fuel_global)
  }
  // B starts in [1, MAX_FUEL]. Successful debits leave B in [0, MAX_FUEL].
  // At most Int32 sites with weight at most 8 keep W representable.
  // With nonnegative B and positive W, B - W is negative exactly when B < W.
  out.append([balance, stack_amount(span.total), @lib.Instruction::i64_sub()])
  match cache {
    Some(balance_local) => out.push(@lib.Instruction::local_tee(balance_local))
    None => {
      out.push(@lib.Instruction::global_set(state.fuel_global))
      out.push(balance)
    }
  }
  out.append([
    stack_amount(0L),
    if state.fuel_v2 {
      @lib.Instruction::i64_ge_s()
    } else {
      @lib.Instruction::i64_lt_s()
    },
    if state.fuel_v2 {
      @lib.Instruction::if_(@lib.BlockType::void_(), [], Some(failure))
    } else {
      @lib.Instruction::if_(@lib.BlockType::void_(), failure, None)
    },
  ])
}

///|
fn reload_join_balance(
  out : Array[@lib.Instruction],
  state : FuelState,
  cache : @lib.LocalIdx,
) -> Unit {
  out.push(@lib.Instruction::global_get(state.fuel_global))
  out.push(@lib.Instruction::local_set(cache))
}

///|
fn publish_join_balance(
  out : Array[@lib.Instruction],
  state : FuelState,
  cache : @lib.LocalIdx,
) -> Unit {
  out.push(@lib.Instruction::local_get(cache))
  out.push(@lib.Instruction::global_set(state.fuel_global))
}

///|
// The global must contain the prepaid balance at calls, native traps and
// function exits. An implicit-function-label branch can also return.
fn join_cache_checkpoint(
  instruction : @lib.Instruction,
  key : String,
  rule : FuelV1Rule,
  depth : Int32,
) -> Bool {
  let root = @lib.LabelIdx::new(depth.reinterpret_as_uint())
  match instruction {
    @lib.Br(label) | @lib.BrIf(label) => label == root
    @lib.BrTable(labels, fallback) => fallback == root || labels.contains(root)
    _ =>
      (rule.boundary is Barrier && key != "global.set") ||
      key == "memory.size" ||
      key == "table.size"
  }
}

///|
fn join_failure_definition(state : FuelState) -> (@lib.RecType, @lib.Func) {
  if state.fuel_v2 {
    let signature = @lib.CompType::func([@lib.ValType::i32()], [])
    let body = charge_trap(
      state.trap_global,
      state.trap_site_global,
      TrapCode::Fuel,
      @lib.Instruction::local_get(@lib.LocalIdx::new(0U)),
    )
    return (
      @lib.RecType::new(@lib.SubType::comp_type(signature)),
      @lib.Func::new(@lib.Locals::from_types([]), @lib.Expr::new(body)),
    )
  }
  let site = @lib.LocalIdx::new(0U)
  let budget = @lib.LocalIdx::new(1U)
  let profile = @lib.LocalIdx::new(2U)
  let step = @lib.LocalIdx::new(3U)
  let get_site = @lib.Instruction::local_get(site)
  let get_budget = @lib.Instruction::local_get(budget)
  let get_profile = @lib.Instruction::local_get(profile)
  let get_step = @lib.Instruction::local_get(step)
  let total = if state.compact_join {
    [stack_amount(JOIN_TOTAL_MASK), @lib.Instruction::i64_and()]
  } else {
    [stack_amount(JOIN_WEIGHT_BITS.to_int64()), @lib.Instruction::i64_shr_u()]
  }
  let weights = if state.compact_join {
    [stack_amount(JOIN_TOTAL_BITS.to_int64()), @lib.Instruction::i64_shr_u()]
  } else {
    [stack_amount(JOIN_WEIGHT_MASK), @lib.Instruction::i64_and()]
  }
  // Recover the pre-debit budget from the signed balance and packed total.
  let body = [
    get_budget,
    get_profile,
    ..total,
    @lib.Instruction::i64_add(),
    @lib.Instruction::local_set(budget),
    get_profile,
    ..weights,
    @lib.Instruction::local_set(profile),
    @lib.Instruction::block(
      @lib.BlockType::void_(),
      @lib.Expr::new([
        @lib.Instruction::loop_(
          @lib.BlockType::void_(),
          @lib.Expr::new([
            get_profile,
            stack_amount(7L),
            @lib.Instruction::i64_and(),
            @lib.Instruction::local_tee(step),
            @lib.Instruction::i64_eqz(),
            @lib.Instruction::br_if(@lib.LabelIdx::new(1U)),
            stack_amount(8L),
            get_step,
            get_step,
            stack_amount(6L),
            @lib.Instruction::i64_eq(),
            @lib.Instruction::select(),
            @lib.Instruction::local_set(step),
            get_step,
            get_budget,
            @lib.Instruction::i64_gt_u(),
            @lib.Instruction::br_if(@lib.LabelIdx::new(1U)),
            get_budget,
            get_step,
            @lib.Instruction::i64_sub(),
            @lib.Instruction::local_set(budget),
            get_site,
            stack_const(1),
            @lib.Instruction::i32_add(),
            @lib.Instruction::local_set(site),
            get_profile,
            stack_amount(3L),
            @lib.Instruction::i64_shr_u(),
            @lib.Instruction::local_set(profile),
            @lib.Instruction::br(@lib.LabelIdx::new(0U)),
          ]),
        ),
      ]),
    ),
    get_budget,
    @lib.Instruction::global_set(state.fuel_global),
  ]
  body.append(
    charge_trap(
      state.trap_global,
      state.trap_site_global,
      TrapCode::Fuel,
      get_site,
    ),
  )
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
