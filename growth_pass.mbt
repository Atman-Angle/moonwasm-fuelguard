///|
priv struct GrowthHelper {
  function_index : @lib.FuncIdx
  limit : Int32?
  is_table : Bool
}

///|
priv struct GrowthPlan {
  memory : GrowthHelper?
  table : GrowthHelper?
  sites : Array[Array[(GrowthHelper, Int32)]]
}

///|
fn GrowthPlan::helper_count(self : Self) -> Int32 {
  (if self.memory is Some(_) { 1 } else { 0 }) +
  (if self.table is Some(_) { 1 } else { 0 })
}

///|
fn is_extern_table(table : @lib.TableType) -> Bool {
  let @lib.TableType(ref_type, _) = table
  @lib.ValType::ref_type(ref_type) == @lib.ValType::externref()
}

///|
fn plan_growth(
  wasm : @lib.Module,
  semantic : SemanticPlan,
  config : GuardConfig?,
  fuel_plan : Array[FuelFunctionPlan],
  metering_only~ : Bool = false,
  fuel_helpers~ : Int32 = 0,
) -> Result[GrowthPlan, InstrumentError] {
  let memories = match wasm.mem_sec {
    Some(@lib.MemSec(values)) => values
    None => []
  }
  let tables = match wasm.table_sec {
    Some(@lib.TableSec(values)) => values
    None => []
  }
  let extern_table = tables.length() == 1 &&
    tables[0] is @lib.Table(ty, _) &&
    is_extern_table(ty)
  let mut grows_memory = false
  let mut grows_table = false
  let bodies = match wasm.code_sec {
    Some(@lib.CodeSec(values)) => values
    None => []
  }
  for i, _ in semantic.functions {
    let @lib.Func(_, body) = bodies[i]
    let mut unsupported_table_mutation = false
    visit_instructions(body, fn(instruction) {
      match instruction_key(instruction) {
        "memory.grow" => grows_memory = true
        "table.grow" => grows_table = true
        "table.copy" | "table.fill" | "table.init" | "table.set" =>
          if !extern_table {
            unsupported_table_mutation = true
          }
        _ => ()
      }
    })
    if unsupported_table_mutation {
      return Err(
        UnsupportedFeature("table mutation requires a defined externref table"),
      )
    }
  }
  let (memory_limit, table_limit) = match config {
    Some(value) => (value.max_memory_pages(), value.max_table_elements())
    None => (None, None)
  }
  if grows_memory && memory_limit is None {
    return Err(UnsupportedFeature("memory.grow requires --max-memory-pages"))
  }
  if grows_table && (!extern_table || table_limit is None) {
    return Err(
      UnsupportedFeature(
        "table.grow requires a defined externref table and --max-table-elements",
      ),
    )
  }
  if memory_limit is Some(limit) {
    if imported_memory_count(wasm) != 0 || memories.length() > 1 {
      return Err(
        UnsupportedFeature(
          "memory growth protection requires a single defined memory",
        ),
      )
    }
    for memory in memories {
      match memory {
        @lib.MemType(@lib.I32Limits(initial, _), false) =>
          if initial > limit.reinterpret_as_uint() {
            return Err(InitialResourceLimit("memory pages", initial, limit))
          }
        _ =>
          return Err(
            UnsupportedFeature(
              "memory growth protection requires unshared wasm32 memory",
            ),
          )
      }
    }
  }
  if table_limit is Some(limit) {
    if imported_table_count(wasm) != 0 || tables.length() > 1 {
      return Err(
        UnsupportedFeature(
          "table growth protection requires a single defined table",
        ),
      )
    }
    for table in tables {
      match table {
        @lib.Table(@lib.TableType(_, @lib.I32Limits(initial, _)), _) =>
          if initial > limit.reinterpret_as_uint() {
            return Err(InitialResourceLimit("table elements", initial, limit))
          }
        _ =>
          return Err(
            UnsupportedFeature("table growth protection requires a table32"),
          )
      }
    }
  }
  let mut next = semantic.module_index.function_count() + fuel_helpers
  let memory = if grows_memory {
    let entry = {
      function_index: @lib.FuncIdx::new(next.reinterpret_as_uint()),
      limit: if metering_only {
        None
      } else {
        memory_limit
      },
      is_table: false,
    }
    next += 1
    Some(entry)
  } else {
    None
  }
  let table = if grows_table {
    Some({
      function_index: @lib.FuncIdx::new(next.reinterpret_as_uint()),
      limit: if metering_only {
        None
      } else {
        table_limit
      },
      is_table: true,
    })
  } else {
    None
  }
  let sites = Array::makei(semantic.functions.length(), fn(_) { [] })
  for i, _ in semantic.functions {
    let mut site = fuel_plan[i].site_start
    let @lib.Func(_, body) = bodies[i]
    visit_instructions(body, fn(instruction) {
      let key = instruction_key(instruction)
      let cost = fuel_v1_rule(key).map(fn(rule) { rule.base }).unwrap_or(0L)
      if cost > 0L {
        site += 1
      }
      let helper = match key {
        "memory.grow" => memory
        "table.grow" => table
        _ => None
      }
      if helper is Some(target) {
        sites[i].push((target, site))
      }
    })
  }
  Ok({ memory, table, sites, })
}

///|
fn GrowthHelper::generate(
  self : Self,
  state : FuelState,
) -> (@lib.RecType, @lib.Func) {
  // Wasm's table.grow takes [externref, delta]. The added site is last.
  let (params, size, grow, code, rule_key) = if self.is_table {
    let idx = @lib.TableIdx::new(0U)
    (
      [@lib.ValType::externref(), @lib.ValType::i32(), @lib.ValType::i32()],
      @lib.Instruction::table_size(idx),
      @lib.Instruction::table_grow(idx),
      TrapCode::Table,
      "table.grow",
    )
  } else {
    let idx = @lib.MemIdx::new(0U)
    (
      [@lib.ValType::i32(), @lib.ValType::i32()],
      @lib.Instruction::memory_size(idx),
      @lib.Instruction::memory_grow(idx),
      TrapCode::Memory,
      "memory.grow",
    )
  }
  let count = params.length().reinterpret_as_uint()
  let delta = @lib.LocalIdx::new(count - 2U)
  let site = @lib.Instruction::local_get(@lib.LocalIdx::new(count - 1U))
  let current = @lib.LocalIdx::new(count)
  let widened = @lib.LocalIdx::new(count + 1U)
  let fuel_temp = @lib.LocalIdx::new(count + 2U)
  let body = []
  if self.limit is Some(cap) {
    let limit = @lib.Instruction::i32_const(@lib.I32::new(cap))
    let fail = @lib.Instruction::if_(
      @lib.BlockType::void_(),
      charge_trap(state.trap_global, state.trap_site_global, code, site),
      None,
    )
    body.append([
      size,
      @lib.Instruction::local_tee(current),
      limit,
      @lib.Instruction::i32_gt_u(),
      fail,
      @lib.Instruction::local_get(delta),
      limit,
      @lib.Instruction::local_get(current),
      @lib.Instruction::i32_sub(),
      @lib.Instruction::i32_gt_u(),
      fail,
    ])
  }
  body.append([
    @lib.Instruction::local_get(delta),
    @lib.Instruction::i64_extend_i32u(),
    @lib.Instruction::local_set(widened),
  ])
  append_dynamic_charge(
    body,
    state,
    fuel_temp,
    widened,
    fuel_v1_rule(rule_key).unwrap(),
    site,
  )
  if self.is_table {
    body.push(@lib.Instruction::local_get(@lib.LocalIdx::new(0U)))
  }
  body.push(@lib.Instruction::local_get(delta))
  body.push(grow)
  let locals = [@lib.ValType::i32(), @lib.ValType::i64()]
  if state.charge_helper is None {
    locals.push(@lib.ValType::i64())
  }
  let locals = @lib.Locals::from_types(locals)
  let signature = @lib.CompType::func(params, [@lib.ValType::i32()])
  (
    @lib.RecType::new(@lib.SubType::comp_type(signature)),
    @lib.Func::new(locals, @lib.Expr::new(body)),
  )
}

///|
fn emit_growth(
  state : FuelState,
  plan : GrowthPlan,
  type_count : Int32,
  stage~ : (String) -> Unit = fn(_) { () },
) -> Result[PassResult, InstrumentError] {
  emit_growth_checked(state, plan, type_count, stage~) catch {
    StageRewriteError(reason) => Err(PipelineAuditFailed(reason))
  }
}

///|
fn emit_growth_checked(
  state : FuelState,
  plan : GrowthPlan,
  type_count : Int32,
  stage~ : (String) -> Unit = fn(_) { () },
) -> Result[PassResult, InstrumentError] raise StageRewriteError {
  let wasm = state.wasm_module
  let code = match wasm.code_sec {
    Some(@lib.CodeSec(bodies)) => bodies.copy()
    None => []
  }
  for i, sites in plan.sites {
    if sites.length() == 0 {
      continue
    }
    let @lib.Func(locals, @lib.Expr(body)) = code[i]
    let next = Ref(0)
    let rewritten = rewrite_generated_stage(body, fn(
      instruction,
      out,
    ) raise StageRewriteError {
      let is_table = match instruction {
        @lib.MemoryGrow(_) => false
        @lib.TableGrow(_) => true
        _ => return false
      }
      guard next.val < sites.length() else {
        raise StageRewriteError("unexpected grow in FuelPass output")
      }
      let (helper, site) = sites[next.val]
      if helper.is_table != is_table {
        raise StageRewriteError("grow order diverged from the source plan")
      }
      next.val += 1
      out.push(@lib.Instruction::i32_const(@lib.I32::new(site)))
      out.push(@lib.Instruction::call(helper.function_index))
      true
    })
    if next.val != sites.length() {
      raise StageRewriteError("FuelPass dropped a planned grow site")
    }
    code[i] = @lib.Func::new(locals, @lib.Expr::new(rewritten))
  }
  let types = match wasm.type_sec {
    Some(@lib.TypeSec(values)) => values.copy()
    None => []
  }
  let functions = match wasm.func_sec {
    Some(@lib.FuncSec(values)) => values.copy()
    None => []
  }
  let mut next_type = type_count.reinterpret_as_uint()
  for entry in [plan.memory, plan.table] {
    if entry is Some(helper) {
      let (signature, body) = helper.generate(state)
      types.push(signature)
      functions.push(@lib.TypeIdx::new(next_type))
      code.push(body)
      next_type += 1U
    }
  }
  let helpers = next_type - type_count.reinterpret_as_uint()
  let output = if helpers == 0U {
    wasm
  } else {
    wasm
    .with_type_sec(@lib.TypeSec::new(types))
    .with_func_sec(@lib.FuncSec::new(functions))
    .with_code_sec(@lib.CodeSec::new(code))
  }
  stage("validate_growth")
  match validate_wasm(output, "GrowthPass") {
    Ok(_) =>
      Ok(
        PassResult::new("GrowthPass", output, notes=[
          "growth: helpers=\{helpers}",
        ]),
      )
    Err(error) => Err(error)
  }
}
