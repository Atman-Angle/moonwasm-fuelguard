///|
priv struct StackSites {
  entries : Array[Int32]
  starts : Array[Int32]
  ends : Array[Int32]
  calls : Array[Array[(@lib.Instruction, Int32)]]
  count : Int32
}

///|
fn func_number(index : @lib.FuncIdx) -> Int32 {
  let @lib.FuncIdx(value) = index
  value.reinterpret_as_int()
}

///|
fn func_index(index : Int32) -> @lib.FuncIdx {
  @lib.FuncIdx::new(index.reinterpret_as_uint())
}

///|
fn stack_source_calls(
  instructions : Array[@lib.Instruction],
  site : Ref[Int32],
  calls : Array[(@lib.Instruction, Int32)],
) -> Unit {
  for instruction in instructions {
    if fuel_v1_rule(instruction_key(instruction)) is Some(rule) &&
      rule.base > 0L {
      site.val += 1
    }
    match instruction {
      @lib.Call(_) | @lib.CallIndirect(_, _) =>
        calls.push((instruction, site.val))
      @lib.Block(_, @lib.Expr(child)) | @lib.Loop(_, @lib.Expr(child)) =>
        stack_source_calls(child, site, calls)
      @lib.If(_, yes, no) => {
        stack_source_calls(yes, site, calls)
        if no is Some(other) {
          stack_source_calls(other, site, calls)
        }
      }
      _ => ()
    }
  }
}

///|
fn plan_stack_sites(source : @lib.Module) -> StackSites {
  let imported = imported_functions(source)
  let code = match source.code_sec {
    Some(@lib.CodeSec(bodies)) => bodies
    None => []
  }
  let count = imported + code.length()
  let entries = Array::make(count, 0)
  let starts = Array::make(count, 0)
  let ends = Array::make(count, 0)
  let calls = Array::makei(count, fn(_) { [] })
  if source.export_sec is Some(@lib.ExportSec(exports)) {
    for @lib.Export(_, reference) in exports {
      if reference is @lib.FuncExternIdx(target) {
        entries[func_number(target)] = 1
      }
    }
  }
  if source.start_sec is Some(@lib.StartSec(target)) {
    entries[func_number(target)] = 1
  }
  let site = Ref(0)
  for i in 0..<count {
    if entries[i] != 0 {
      site.val += 1
      entries[i] = site.val
    }
    starts[i] = site.val
    if i >= imported {
      let @lib.Func(_, @lib.Expr(body)) = code[i - imported]
      stack_source_calls(body, site, calls[i])
    }
    ends[i] = site.val
  }
  { entries, starts, ends, calls, count: site.val, }
}

///|
priv struct StackGlobals {
  units : @lib.GlobalIdx
  depth : @lib.GlobalIdx
  code : @lib.GlobalIdx
  site : @lib.GlobalIdx
}

///|
const PACKED_STACK_SIGNS : Int64 = -9223372034707292160L

///|
const PACKED_STACK_DEPTH_STEP : Int64 = 1L << 32

///|
fn stack_counter(value : Int64) -> @lib.Global {
  @lib.Global::new(
    @lib.GlobalType::new(@lib.ValType::i64(), true),
    @lib.Expr::new([@lib.Instruction::i64_const(@lib.I64::new(value))]),
  )
}

///|
fn stack_global(index : Int32) -> @lib.GlobalIdx {
  @lib.GlobalIdx::new(index.reinterpret_as_uint())
}

///|
fn stack_const(value : Int32) -> @lib.Instruction {
  @lib.Instruction::i32_const(@lib.I32::new(value))
}

///|
fn stack_amount(value : Int64) -> @lib.Instruction {
  @lib.Instruction::i64_const(@lib.I64::new(value))
}

///|
fn StackGlobals::prepare_packed(
  self : Self,
  out : Array[@lib.Instruction],
) -> Unit {
  // The runner admits the two declared budgets before instantiation. A zero
  // depth global records that the first external entry already packed them.
  let depth = @lib.Instruction::global_get(self.depth)
  let zero = stack_amount(0L)
  out.append([
    depth,
    zero,
    @lib.Instruction::i64_ne(),
    @lib.Instruction::if_(
      @lib.BlockType::void_(),
      [
        depth,
        stack_amount(32L),
        @lib.Instruction::i64_shl(),
        @lib.Instruction::global_get(self.units),
        @lib.Instruction::i64_or(),
        @lib.Instruction::global_set(self.units),
        zero,
        @lib.Instruction::global_set(self.depth),
      ],
      None,
    ),
  ])
}

///|
fn StackGlobals::reserve(
  self : Self,
  out : Array[@lib.Instruction],
  cost : Int64,
  site : @lib.Instruction,
  leaf~ : Bool = false,
  checked~ : Bool = false,
) -> Unit {
  // The two nonnegative lanes are at most i32::MAX before subtraction.
  // A borrow out of the low lane already means Stack failure, regardless of
  // the resulting high lane. Without that borrow, the high lane checks Depth.
  let balance = @lib.Instruction::global_get(self.units)
  let store = @lib.Instruction::global_set(self.units)
  let debit = stack_amount(PACKED_STACK_DEPTH_STEP + cost)
  if checked {
    if !leaf {
      out.append([balance, debit, @lib.Instruction::i64_sub(), store])
    }
    return
  }
  out.append([balance, debit, @lib.Instruction::i64_sub()])
  if !leaf {
    out.append([store, balance])
  }
  let cold = [
    stack_const(TrapCode::Stack.to_code()),
    stack_const(TrapCode::Depth.to_code()),
    balance,
    @lib.Instruction::i32_wrap_i64(),
  ]
  if leaf {
    cold.append([stack_const(cost.to_int()), @lib.Instruction::i32_lt_u()])
  } else {
    cold.append([stack_const(0), @lib.Instruction::i32_lt_s()])
  }
  cold.push(@lib.Instruction::select())
  if !leaf {
    cold.append([balance, debit, @lib.Instruction::i64_add(), store])
  }
  cold.append([
    @lib.Instruction::global_set(self.code),
    site,
    @lib.Instruction::global_set(self.site),
    @lib.Instruction::unreachable_(),
  ])
  out.append([
    stack_amount(PACKED_STACK_SIGNS),
    @lib.Instruction::i64_and(),
    stack_amount(0L),
    @lib.Instruction::i64_ne(),
    @lib.Instruction::if_(@lib.BlockType::void_(), cold, None),
  ])
}

///|
fn StackGlobals::release(
  self : Self,
  out : Array[@lib.Instruction],
  cost : Int64,
  leaf~ : Bool = false,
) -> Unit {
  if !leaf {
    out.append([
      @lib.Instruction::global_get(self.units),
      stack_amount(PACKED_STACK_DEPTH_STEP + cost),
      @lib.Instruction::i64_add(),
      @lib.Instruction::global_set(self.units),
    ])
  }
}

///|
priv struct StackRewrite {
  original_count : Int32
  imported_count : Int32
  costs : Array[Int64]
  leaves : Array[Bool]
  globals : StackGlobals
  reuse_checked_bound : Bool
  indirect_types : Map[@lib.TypeIdx, @lib.TypeIdx]
}

///|
fn stack_indirect_call(
  site : Int32,
  temp : @lib.LocalIdx,
  ty : @lib.TypeIdx,
  table : @lib.TableIdx,
) -> Array[@lib.Instruction] {
  // [args..., slot] -> [args..., site, slot]. Wasm still resolves the target.
  [
    @lib.Instruction::local_set(temp),
    stack_const(site),
    @lib.Instruction::local_get(temp),
    @lib.Instruction::call_indirect(ty, table),
  ]
}

///|
fn contains_branch_instruction(instructions : Array[@lib.Instruction]) -> Bool {
  let found = Ref(false)
  visit_instructions(@lib.Expr::new(instructions), fn(instruction) {
    if instruction is (@lib.Br(_) | @lib.BrIf(_) | @lib.BrTable(_, _)) {
      found.val = true
    }
  })
  found.val
}

///|
fn StackRewrite::body(
  self : Self,
  body : Array[@lib.Instruction],
  calls : Array[(@lib.Instruction, Int32)],
  cursor : Ref[Int32],
  temp : @lib.LocalIdx?,
  inherited_bound : Int64,
  reachable_at_entry : Bool,
) -> (Array[@lib.Instruction], Int64, Bool) raise StackAuditError {
  let mut checked_bound = inherited_bound
  let mut reachable = reachable_at_entry
  let out = Array(capacity=body.length())
  for instruction in body {
    match instruction {
      @lib.Call(target) if func_number(target) < self.original_count => {
        let site = verify_stack_call(instruction, calls, cursor)
        if reachable {
          let index = func_number(target)
          let cost = self.costs[index]
          // A closed leaf cannot observe its private reservation or re-enter.
          // The caller still checks C and depth before entering its native frame.
          let leaf = self.leaves[index]
          // A dominating successful check proves this frame and one more
          // depth unit fit. A normal return restores the caller's counters.
          let checked = self.reuse_checked_bound &&
            index >= self.imported_count &&
            cost <= checked_bound
          self.globals.reserve(out, cost, stack_const(site), leaf~, checked~)
          if self.reuse_checked_bound && cost > checked_bound {
            checked_bound = cost
          }
          out.push(instruction)
          self.globals.release(out, cost, leaf~)
        } else {
          out.push(instruction)
        }
      }
      @lib.CallIndirect(type_index, table) => {
        let site = verify_stack_call(instruction, calls, cursor)
        if reachable {
          guard self.indirect_types.get(type_index) is Some(wrapped) else {
            raise StackError("missing indirect wrapper signature")
          }
          guard temp is Some(temp) else {
            raise StackError("indirect call scratch local is missing")
          }
          out.append(stack_indirect_call(site, temp, wrapped, table))
        } else {
          out.push(instruction)
        }
      }
      @lib.Block(ty, @lib.Expr(child)) =>
        out.push(
          @lib.Instruction::block(
            ty,
            @lib.Expr::new(
              self.body(child, calls, cursor, temp, checked_bound, reachable).0,
            ),
          ),
        )
      @lib.Loop(ty, @lib.Expr(child)) =>
        out.push(
          @lib.Instruction::loop_(
            ty,
            @lib.Expr::new(
              self.body(child, calls, cursor, temp, checked_bound, reachable).0,
            ),
          ),
        )
      @lib.If(ty, yes, no) => {
        let (then_body, then_bound, then_falls) = self.body(
          yes, calls, cursor, temp, checked_bound, reachable,
        )
        let (else_body, else_bound, else_falls) = match no {
          Some(other) => {
            let (body, bound, falls) = self.body(
              other, calls, cursor, temp, checked_bound, reachable,
            )
            (Some(body), bound, falls)
          }
          None => (None, checked_bound, reachable)
        }
        out.push(@lib.Instruction::if_(ty, then_body, else_body))
        let has_branch = contains_branch_instruction(yes) ||
          (match no {
            Some(body) => contains_branch_instruction(body)
            None => false
          })
        if reachable && !has_branch {
          match (then_falls, else_falls) {
            (true, true) =>
              checked_bound = if then_bound < else_bound {
                then_bound
              } else {
                else_bound
              }
            (true, false) => checked_bound = then_bound
            (false, true) => checked_bound = else_bound
            (false, false) => reachable = false
          }
        } else if reachable {
          checked_bound = inherited_bound
        }
      }
      @lib.Br(_) | @lib.BrTable(_, _) | @lib.Return | @lib.Unreachable => {
        out.push(instruction)
        reachable = false
      }
      _ => out.push(instruction)
    }
  }
  (out, checked_bound, reachable)
}

///|
fn verify_stack_call(
  actual : @lib.Instruction,
  calls : Array[(@lib.Instruction, Int32)],
  cursor : Ref[Int32],
) -> Int32 raise StackAuditError {
  if cursor.val >= calls.length() || calls[cursor.val].0 != actual {
    raise StackError("Fuel/Growth output diverged from original call sequence")
  }
  let site = calls[cursor.val].1
  cursor.val += 1
  site
}

///|
fn StackRewrite::wrapper(
  self : Self,
  target : Int32,
  signature : @lib.FuncType,
  entry_site : Int32?,
) -> @lib.Func {
  let @lib.FuncType(params, _) = signature
  let site = match entry_site {
    Some(value) => stack_const(value)
    None =>
      @lib.Instruction::local_get(
        @lib.LocalIdx::new(params.length().reinterpret_as_uint()),
      )
  }
  let body = []
  if entry_site is Some(_) {
    self.globals.prepare_packed(body)
  }
  let cost = self.costs[target]
  self.globals.reserve(body, cost, site)
  for i in 0..<params.length() {
    body.push(
      @lib.Instruction::local_get(@lib.LocalIdx::new(i.reinterpret_as_uint())),
    )
  }
  body.push(@lib.Instruction::call(func_index(target)))
  self.globals.release(body, cost)
  @lib.Func::new(@lib.Locals::empty(), @lib.Expr::new(body))
}

///|
fn append_indirect_type(
  env : @validate.Env,
  types : Array[@lib.RecType],
  first_type : Int32,
  map : Map[@lib.TypeIdx, @lib.TypeIdx],
  original : @lib.TypeIdx,
) -> @lib.TypeIdx raise StackAuditError {
  if map.get(original) is Some(index) {
    return index
  }
  guard env.resolve_functype(original) is Some(@lib.FuncType(params, results)) else {
    raise StackError("unresolved indirect signature")
  }
  let extended = params.copy()
  extended.push(@lib.ValType::i32())
  let type_index = @lib.TypeIdx::new(
    (first_type + types.length()).reinterpret_as_uint(),
  )
  types.push(
    @lib.RecType::new(
      @lib.SubType::comp_type(@lib.CompType::func(extended, results)),
    ),
  )
  map.set(original, type_index)
  type_index
}

///|
priv struct StackWrapper {
  target : Int32
  type_index : @lib.TypeIdx
  signature : @lib.FuncType
  entry_site : Int32?
}

///|
priv struct StackPlan {
  sites : StackSites
  costs : Array[Int64]
  max_units : Int64
  max_depth : Int64
  first_type : Int32
  first_function : Int32
  types : Array[@lib.RecType]
  indirect_types : Map[@lib.TypeIdx, @lib.TypeIdx]
  external : Array[@lib.FuncIdx?]
  indirect : Array[@lib.FuncIdx?]
  wrappers : Array[StackWrapper]
  indirect_locals : Array[@lib.LocalIdx?]
}

///|
fn plan_stack(
  original : @lib.Module,
  sites : StackSites,
  growth : GrowthPlan,
  fuel_plan : Array[FuelFunctionPlan],
  config : StackConfig,
  fuel_helpers~ : Int32 = 0,
) -> Result[StackPlan, InstrumentError] {
  plan_stack_checked(original, sites, growth, fuel_plan, config, fuel_helpers) catch {
    StackError(reason) => Err(StackAnalysisFailed(reason))
  }
}

///|
fn plan_stack_checked(
  original : @lib.Module,
  sites : StackSites,
  growth : GrowthPlan,
  fuel_plan : Array[FuelFunctionPlan],
  config : StackConfig,
  fuel_helpers : Int32,
) -> Result[StackPlan, InstrumentError] raise StackAuditError {
  let count = sites.entries.length()
  let costs = source_stack_costs(original)
  let env = @validate.Env::new().with_module(original)
  let helpers = fuel_helpers + growth.helper_count()
  let first_type = type_count(original) + helpers
  let first_function = count + helpers
  let types = []
  let indirect_types = Map([])
  for calls in sites.calls {
    for (instruction, _) in calls {
      if instruction is @lib.CallIndirect(ty, _) {
        ignore(append_indirect_type(env, types, first_type, indirect_types, ty))
      }
    }
  }
  let table_targets = Array::make(count, false)
  for target in audit_table_targets(original) {
    table_targets[target] = true
  }
  let external = Array::make(count, None)
  let indirect = Array::make(count, None)
  let wrappers = []
  for i in 0..<count {
    let entry = sites.entries[i]
    if entry == 0 && !table_targets[i] {
      continue
    }
    let signature = env.funcs[i]
    guard env.get_functypeidx_by_funcidx(func_index(i)) is Some(original_type) else {
      raise StackError("wrapper source type index is missing")
    }
    if entry > 0 {
      external[i] = Some(func_index(first_function + wrappers.length()))
      wrappers.push({
        target: i,
        type_index: original_type,
        signature,
        entry_site: Some(entry),
      })
    }
    if table_targets[i] {
      indirect[i] = Some(func_index(first_function + wrappers.length()))
      let type_index = append_indirect_type(
        env, types, first_type, indirect_types, original_type,
      )
      wrappers.push({ target: i, type_index, signature, entry_site: None, })
    }
  }
  let imported = imported_functions(original)
  let indirect_locals = fuel_plan.mapi(fn(i, function) {
    if sites.calls[imported + i].any(fn(call) {
        call.0 is @lib.CallIndirect(_, _)
      }) {
      Some(
        @lib.LocalIdx::new(
          (function.scratch_index + function.appended_locals.length()).reinterpret_as_uint(),
        ),
      )
    } else {
      None
    }
  })
  Ok({
    sites,
    costs,
    max_units: config.max_units,
    max_depth: config.max_depth,
    first_type,
    first_function,
    types,
    indirect_types,
    external,
    indirect,
    wrappers,
    indirect_locals,
  })
}

///|
fn apply_stack(
  metered : @lib.Module,
  fuel : FuelState,
  plan : StackPlan,
  config : StackConfig,
  reuse_checked_bound~ : Bool = false,
  stage~ : (String) -> Unit = fn(_) { () },
) -> Result[PassResult, InstrumentError] {
  build_stack_module(metered, fuel, plan, config, reuse_checked_bound, stage~) catch {
    StackError(reason) => Err(StackAnalysisFailed(reason))
  }
}

///|
fn build_stack_module(
  metered : @lib.Module,
  fuel : FuelState,
  plan : StackPlan,
  config : StackConfig,
  reuse_checked_bound : Bool,
  stage~ : (String) -> Unit = fn(_) { () },
) -> Result[PassResult, InstrumentError] raise StackAuditError {
  let sites = plan.sites
  let count = sites.entries.length()
  let imported = imported_functions(metered)
  let types = match metered.type_sec {
    Some(@lib.TypeSec(entries)) => entries.copy()
    None => []
  }
  let signatures = match metered.func_sec {
    Some(@lib.FuncSec(entries)) => entries.copy()
    None => []
  }
  let code = match metered.code_sec {
    Some(@lib.CodeSec(bodies)) => bodies.copy()
    None => []
  }
  if types.length() != plan.first_type ||
    imported + code.length() != plan.first_function {
    raise StackError(
      "GrowthPass output diverged from the planned append ranges",
    )
  }
  types.append(plan.types)
  let global_base = imported_global_count(metered) +
    defined_global_count(metered)
  let globals = StackGlobals::{
    units: stack_global(global_base),
    depth: stack_global(global_base + 1),
    code: fuel.trap_global,
    site: fuel.trap_site_global,
  }
  let rewrite = StackRewrite::{
    original_count: count,
    imported_count: if fuel.fuel_v2 {
      imported
    } else {
      0
    },
    costs: plan.costs,
    leaves: Array::makei(count, fn(i) {
      i >= imported && sites.calls[i].is_empty()
    }),
    globals,
    reuse_checked_bound,
    indirect_types: plan.indirect_types,
  }
  for i in imported..<count {
    if sites.calls[i].length() == 0 {
      continue
    }
    let @lib.Func(locals, @lib.Expr(body)) = code[i - imported]
    let new_locals = locals.copy()
    let temp = plan.indirect_locals[i - imported]
    if temp is Some(_) {
      new_locals.push(@lib.ValType::i32())
    }
    let cursor = Ref(0)
    let (updated, _, _) = rewrite.body(
      body,
      sites.calls[i],
      cursor,
      temp,
      0L,
      true,
    )
    if cursor.val != sites.calls[i].length() {
      raise StackError("Fuel/Growth dropped an original call")
    }
    code[i - imported] = @lib.Func::new(new_locals, @lib.Expr::new(updated))
  }
  for wrapper in plan.wrappers {
    signatures.push(wrapper.type_index)
    code.push(
      rewrite.wrapper(wrapper.target, wrapper.signature, wrapper.entry_site),
    )
  }
  let global_defs = match metered.global_sec {
    Some(@lib.GlobalSec(entries)) => entries.copy()
    None => raise StackError("Fuel/Growth diagnostic globals missing")
  }
  global_defs.push(stack_counter(config.max_units))
  global_defs.push(stack_counter(config.max_depth))
  let prepared = metered
    .with_type_sec(@lib.TypeSec::new(types))
    .with_func_sec(@lib.FuncSec::new(signatures))
    .with_code_sec(@lib.CodeSec::new(code))
    .with_global_sec(@lib.GlobalSec::new(global_defs))
  let output = rewrite_stack_references(prepared, plan.external, plan.indirect)
  stage("validate_stack")
  match validate_wasm(output, "StackPass") {
    Ok(_) =>
      Ok(
        PassResult::new("StackPass", output, notes=[
          "stack: \{stack_model_version}, units=\{config.max_units}, depth=\{config.max_depth}",
        ]),
      )
    Err(error) => Err(error)
  }
}
