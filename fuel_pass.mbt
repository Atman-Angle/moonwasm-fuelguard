/// FuelGuard static metering templates.

///|
fn fuel_charge_instructions(
  fuel_global : @lib.GlobalIdx,
  temp_local : @lib.LocalIdx,
  trap_global : @lib.GlobalIdx,
  trap_site_global : @lib.GlobalIdx,
  cost : @lib.Instruction,
  site : @lib.Instruction,
) -> Array[@lib.Instruction] {
  [
    @lib.Instruction::global_get(fuel_global),
    @lib.Instruction::local_tee(temp_local),
    cost,
    @lib.Instruction::i64_lt_s(),
    @lib.Instruction::if_(
      @lib.BlockType::void_(),
      charge_trap(trap_global, trap_site_global, TrapCode::Fuel, site),
      None,
    ),
    @lib.Instruction::local_get(temp_local),
    cost,
    @lib.Instruction::i64_sub(),
    @lib.Instruction::global_set(fuel_global),
  ]
}

///|
fn append_charge(
  out : Array[@lib.Instruction],
  state : FuelState,
  temp_local : @lib.LocalIdx,
  cost : Int64,
  site : Int32,
) -> Unit {
  let cost = @lib.Instruction::i64_const(@lib.I64::new(cost))
  let site = @lib.Instruction::i32_const(@lib.I32::new(site))
  match state.charge_helper {
    Some(helper) => out.append([cost, site, @lib.Instruction::call(helper)])
    None =>
      out.append(
        fuel_charge_instructions(
          state.fuel_global,
          temp_local,
          state.trap_global,
          state.trap_site_global,
          cost,
          site,
        ),
      )
  }
}

///|
fn charge_helper_definition(state : FuelState) -> (@lib.RecType, @lib.Func) {
  if state.join_failure is Some(_) {
    return join_failure_definition(state)
  }
  if state.prefix_failure is Some(_) {
    return prefix_failure_definition(state)
  }
  let signature = @lib.CompType::func(
    [@lib.ValType::i64(), @lib.ValType::i32()],
    [],
  )
  let body = fuel_charge_instructions(
    state.fuel_global,
    @lib.LocalIdx::new(2U),
    state.trap_global,
    state.trap_site_global,
    @lib.Instruction::local_get(@lib.LocalIdx::new(0U)),
    @lib.Instruction::local_get(@lib.LocalIdx::new(1U)),
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
fn call_can_change_fuel(
  instruction : @lib.Instruction,
  metered_functions : Array[Bool],
) -> Bool {
  match instruction {
    @lib.Call(target) => {
      let index = func_number(target)
      index >= metered_functions.length() || metered_functions[index]
    }
    @lib.CallIndirect(_, _) => true
    _ => false
  }
}

///|
fn fuel_cache_profitable(
  span_count : Int32,
  dynamic_operation_count : Int32,
  fuel_v2 : Bool,
) -> Bool {
  span_count >= 2 && (fuel_v2 || dynamic_operation_count == 0)
}

///|
fn fuel_changing_functions(
  wasm_module : @lib.Module,
  initially_changing : Array[Bool],
) -> Array[Bool] {
  let imported = imported_functions(wasm_module)
  let functions = match wasm_module.code_sec {
    Some(@lib.CodeSec(values)) => values
    None => []
  }
  let changing = Array::make(imported + functions.length(), false)
  for index, value in initially_changing {
    changing[imported + index] = value
  }
  for index in 0..<imported {
    changing[index] = true
  }
  let mut changed = true
  while changed {
    changed = false
    for index, @lib.Func(_, @lib.Expr(body)) in functions {
      let function_index = imported + index
      if changing[function_index] {
        continue
      }
      let reaches_changing = Ref(false)
      visit_instructions(@lib.Expr::new(body), fn(instruction) {
        match instruction {
          @lib.Call(target) => {
            let target_index = func_number(target)
            if target_index >= changing.length() || changing[target_index] {
              reaches_changing.val = true
            }
          }
          @lib.CallIndirect(_, _) => reaches_changing.val = true
          _ => ()
        }
      })
      if reaches_changing.val {
        changing[function_index] = true
        changed = true
      }
    }
  }
  changing
}

///|
fn rewrite_expr(
  body : @lib.Expr,
  state : FuelState,
  temp_local : @lib.LocalIdx,
  site_id : Ref[Int32],
  dynamic_locals : DynamicLocals?,
  join_span_at : (Int32) -> JoinSpan?,
  metered_functions : Array[Bool],
  cache~ : @lib.LocalIdx? = None,
  depth~ : Int32 = 0,
) -> Result[@lib.Expr, InstrumentError] {
  let @lib.Expr(instructions) = body
  let out : Array[@lib.Instruction] = []
  if depth == 0 && cache is Some(balance_local) {
    reload_join_balance(out, state, balance_local)
  }
  // At nested entries and structured joins, different predecessors may
  // leave different published balances. Require a checkpoint before reuse.
  let mut balance_dirty = depth != 0
  let mut covered_until = 0
  for index, instruction in instructions {
    let key = instruction_key(instruction)
    guard fuel_v1_rule(key) is Some(rule) else {
      return Err(UnsupportedFeature("opcode outside fuel-v1 pricing allowlist"))
    }
    let cost = rule.base
    if cost > 0L {
      site_id.val += 1
      if state.join_failure is Some(helper) {
        if join_span_at(site_id.val) is Some(span) {
          append_join_charge(out, state, helper, site_id.val, span, cache~)
          balance_dirty = true
        }
      } else if state.prefix_failure is Some(helper) {
        if index >= covered_until {
          let (end, prefix, total) = prefix_charge_span(
            instructions, index, rule,
          )
          append_prefix_charge(
            out,
            state,
            helper,
            temp_local,
            site_id.val,
            prefix,
            total,
          )
          covered_until = end
        }
      } else {
        append_charge(out, state, temp_local, cost, site_id.val)
      }
    }
    // Fuel charges the source grow site. Growth lowers it in the next pass.
    if instruction is @lib.MemoryGrow(_) || instruction is @lib.TableGrow(_) {
      if cache is Some(balance_local) {
        publish_join_balance(out, state, balance_local)
      }
      out.push(instruction)
      if cache is Some(balance_local) {
        reload_join_balance(out, state, balance_local)
        balance_dirty = false
      }
      continue
    }
    let rewritten : @lib.Instruction = match instruction {
      @lib.Block(block_type, child) =>
        @lib.Instruction::block(
          block_type,
          match
            rewrite_expr(
              child,
              state,
              temp_local,
              site_id,
              dynamic_locals,
              join_span_at,
              metered_functions,
              cache~,
              depth=depth + 1,
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          },
        )
      @lib.Loop(block_type, child) =>
        @lib.Instruction::loop_(
          block_type,
          match
            rewrite_expr(
              child,
              state,
              temp_local,
              site_id,
              dynamic_locals,
              join_span_at,
              metered_functions,
              cache~,
              depth=depth + 1,
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          },
        )
      @lib.If(block_type, then_body, else_body) => {
        let then_out = match
          rewrite_expr(
            @lib.Expr::new(then_body),
            state,
            temp_local,
            site_id,
            dynamic_locals,
            join_span_at,
            metered_functions,
            cache~,
            depth=depth + 1,
          ) {
          Ok(@lib.Expr(value)) => value
          Err(error) => return Err(error)
        }
        let else_out = match else_body {
          Some(value) =>
            match
              rewrite_expr(
                @lib.Expr::new(value),
                state,
                temp_local,
                site_id,
                dynamic_locals,
                join_span_at,
                metered_functions,
                cache~,
                depth=depth + 1,
              ) {
              Ok(@lib.Expr(result)) => Some(result)
              Err(error) => return Err(error)
            }
          None => None
        }
        @lib.Instruction::if_(block_type, then_out, else_out)
      }
      @lib.Try(block_type, child, catches, delegate) => {
        let body_out = match
          rewrite_expr(
            child,
            state,
            temp_local,
            site_id,
            dynamic_locals,
            join_span_at,
            metered_functions,
            cache~,
            depth=depth + 1,
          ) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let catches_out : Array[@lib.LegacyCatch] = []
        for item in catches {
          match item {
            @lib.LegacyCatch(tag, catch_body) => {
              let value = match
                rewrite_expr(
                  catch_body,
                  state,
                  temp_local,
                  site_id,
                  dynamic_locals,
                  join_span_at,
                  metered_functions,
                  cache~,
                  depth=depth + 1,
                ) {
                Ok(value) => value
                Err(error) => return Err(error)
              }
              catches_out.push(@lib.LegacyCatch::tagged(tag, value))
            }
            @lib.LegacyCatchAll(catch_body) => {
              let value = match
                rewrite_expr(
                  catch_body,
                  state,
                  temp_local,
                  site_id,
                  dynamic_locals,
                  join_span_at,
                  metered_functions,
                  cache~,
                  depth=depth + 1,
                ) {
                Ok(value) => value
                Err(error) => return Err(error)
              }
              catches_out.push(@lib.LegacyCatch::all(value))
            }
          }
        }
        @lib.Instruction::try_(block_type, body_out, catches_out, delegate~)
      }
      @lib.TryTable(block_type, catches, child) =>
        @lib.Instruction::try_table(
          block_type,
          catches,
          match
            rewrite_expr(
              child,
              state,
              temp_local,
              site_id,
              dynamic_locals,
              join_span_at,
              metered_functions,
              cache~,
              depth=depth + 1,
            ) {
            Ok(value) => value
            Err(error) => return Err(error)
          },
        )
      _ => instruction
    }
    if instruction
      is (@lib.Block(_, _)
      | @lib.Loop(_, _)
      | @lib.If(_, _, _)
      | @lib.Try(_, _, _, _)
      | @lib.TryTable(_, _, _)) {
      balance_dirty = true
    }
    if rule.per_unit > 0L {
      guard dynamic_locals is Some(locals) && dynamic_key_is_supported(key) else {
        return Err(UnsupportedFeature("S07 dynamic locals unavailable"))
      }
      append_dynamic_operation(
        out,
        instruction,
        locals,
        state,
        temp_local,
        rule,
        site_id.val,
        cache~,
      )
      if cache is Some(balance_local) {
        publish_join_balance(out, state, balance_local)
        balance_dirty = false
      }
    } else {
      if cache is Some(balance_local) &&
        (!state.coalesce_join_publications || balance_dirty) &&
        join_cache_checkpoint(instruction, key, rule, depth) {
        publish_join_balance(out, state, balance_local)
        balance_dirty = false
      }
      out.push(rewritten)
      if cache is Some(balance_local) &&
        call_can_change_fuel(instruction, metered_functions) {
        reload_join_balance(out, state, balance_local)
        balance_dirty = false
      }
    }
  }
  if depth == 0 &&
    cache is Some(balance_local) &&
    (!state.coalesce_join_publications || balance_dirty) {
    publish_join_balance(out, state, balance_local)
  }
  Ok(@lib.Expr::new(out))
}

///|
priv struct FuelFunctionPlan {
  scratch_index : Int32
  appended_locals : Array[@lib.ValType]
  dynamic_locals : DynamicLocals?
  site_start : Int32
  site_end : Int32
  shared_charge : Bool
  join_spans : Array[JoinSpan?]
  cache : @lib.LocalIdx?
}

///|
// Frozen from the lower median of charged sites in loop-free tuning
// application functions. See docs/evidence/S20.md for provenance.
const HYBRID_MIN_SITES : Int32 = 21

///|
fn plan_fuel(
  semantic : SemanticPlan,
  stack_sites : StackSites?,
  source : @lib.Module,
  codegen~ : CodegenLayout = P0,
) -> Array[FuelFunctionPlan] {
  let mut next_site = 0
  let functions = []
  let bodies = match source.code_sec {
    Some(@lib.CodeSec(bodies)) => bodies
    None => []
  }
  let hot = if codegen.uses_compact_join() && stack_sites is Some(sites) {
    join_hot_functions(source, semantic, sites)
  } else {
    []
  }
  for i, facts in semantic.functions {
    let site_start = match stack_sites {
      Some(plan) => plan.starts[facts.function_index]
      None => next_site
    }
    let @lib.Func(_, body) = bodies[i]
    let site_count = Ref(0)
    let has_dynamic = Ref(false)
    let dynamic_operation_count = Ref(0)
    visit_instructions(body, fn(instruction) {
      let key = instruction_key(instruction)
      match fuel_v1_rule(key) {
        Some(rule) => if rule.base > 0L { site_count.val += 1 }
        None => ()
      }
      if dynamic_key_is_supported(key) {
        has_dynamic.val = true
      }
      if fuel_v1_rule(key) is Some(rule) && rule.per_unit > 0L {
        dynamic_operation_count.val += 1
      }
    })
    next_site = site_start + site_count.val
    let scratch_index = facts.parameter_count + facts.local_count
    let shared_charge = match codegen {
      P0 | P2Prefix | JoinSpan | JoinSpanCached | FuelV2 => false
      JoinSpanCompact | JoinSpanCompactV2 =>
        hot.get(facts.function_index) == Some(false) && next_site > site_start
      P1 => true
      P2 => facts.loop_count == 0 && next_site - site_start >= HYBRID_MIN_SITES
    }
    let dynamic = has_dynamic.val
    let needs_scratch = if codegen.uses_join_spans() {
      dynamic
    } else {
      !shared_charge
    }
    let appended_locals = if needs_scratch { [@lib.ValType::i64()] } else { [] }
    let dynamic_index = scratch_index + appended_locals.length()
    let dynamic_locals = if dynamic {
      appended_locals.push(@lib.ValType::i32())
      appended_locals.push(@lib.ValType::i64())
      Some({
        length: @lib.LocalIdx::new(dynamic_index.reinterpret_as_uint()),
        widened_length: @lib.LocalIdx::new(
          (dynamic_index + 1).reinterpret_as_uint(),
        ),
      })
    } else {
      None
    }
    let join_spans = if codegen.uses_join_spans() {
      let @lib.Func(_, body) = bodies[i]
      plan_join_spans(body, next_site - site_start, fuel_v2=codegen is FuelV2)
    } else {
      []
    }
    // Dynamic templates can observe the global even without an original call.
    let span_count = join_spans.fold(init=0, fn(n, span) {
      if span is Some(_) {
        n + 1
      } else {
        n
      }
    })
    let cache = if codegen.uses_fuel_cache() &&
      !shared_charge &&
      fuel_cache_profitable(
        span_count,
        dynamic_operation_count.val,
        codegen is FuelV2,
      ) {
      let index = scratch_index + appended_locals.length()
      appended_locals.push(@lib.ValType::i64())
      Some(@lib.LocalIdx::new(index.reinterpret_as_uint()))
    } else {
      None
    }
    functions.push({
      scratch_index,
      appended_locals,
      dynamic_locals,
      site_start,
      site_end: next_site,
      shared_charge,
      join_spans,
      cache,
    })
  }
  functions
}

///|
fn emit_fuel(
  config : FuelConfig,
  wasm_module : @lib.Module,
  plan : Array[FuelFunctionPlan],
  site_count : Int32,
  charge_helper~ : @lib.FuncIdx? = None,
  join_shared~ : @lib.FuncIdx? = None,
  codegen~ : CodegenLayout = P0,
  stage~ : (String) -> Unit = fn(_) { () },
) -> Result[(FuelState, String), InstrumentError] {
  let state = match add_fuel_state(wasm_module, config.budget(), stage~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let state = match codegen {
    JoinSpan | JoinSpanCached | JoinSpanCompact | JoinSpanCompactV2 | FuelV2 =>
      {
        ..state,
        join_failure: charge_helper,
        join_shared,
        compact_join: codegen.uses_compact_join(),
        fuel_v2: codegen is FuelV2,
        coalesce_join_publications: codegen is (JoinSpanCompactV2 | FuelV2),
      }
    P2Prefix => { ..state, prefix_failure: charge_helper, }
    _ => { ..state, charge_helper, }
  }
  stage("fuel_rewrite")
  let functions = match wasm_module.code_sec {
    Some(@lib.CodeSec(values)) => values
    None => []
  }
  let rewritten : Array[@lib.Func] = []
  let initially_changing = plan.map(fn(row) { row.site_end > row.site_start })
  let metered_functions = fuel_changing_functions(
    wasm_module, initially_changing,
  )
  for index, function in functions {
    let function_plan = plan[index]
    let function_state = if function_plan.shared_charge {
      state
    } else {
      { ..state, charge_helper: None, join_shared: None, }
    }
    let site_id = Ref(function_plan.site_start)
    let @lib.Func(locals, body) = function
    let new_locals = locals.copy()
    for ty in function_plan.appended_locals {
      new_locals.push(ty)
    }
    let new_body = match
      rewrite_expr(
        body,
        function_state,
        @lib.LocalIdx::new(function_plan.scratch_index.reinterpret_as_uint()),
        site_id,
        function_plan.dynamic_locals,
        fn(site) {
          function_plan.join_spans[site - function_plan.site_start - 1]
        },
        metered_functions,
        cache=function_plan.cache,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if site_id.val != function_plan.site_end {
      return Err(
        PipelineAuditFailed("FuelPass site count diverged from the source plan"),
      )
    }
    rewritten.push(@lib.Func::new(new_locals, new_body))
  }
  let output = if wasm_module.code_sec is Some(_) {
    state.wasm_module.with_code_sec(@lib.CodeSec::new(rewritten))
  } else {
    state.wasm_module
  }
  let output = if charge_helper is Some(_) {
    let types = match wasm_module.type_sec {
      Some(@lib.TypeSec(entries)) => entries.copy()
      None => []
    }
    let signatures = match wasm_module.func_sec {
      Some(@lib.FuncSec(entries)) => entries.copy()
      None => []
    }
    let (signature, definition) = charge_helper_definition(state)
    signatures.push(@lib.TypeIdx::new(types.length().reinterpret_as_uint()))
    types.push(signature)
    rewritten.push(definition)
    if join_shared is Some(_) {
      let (signature, definition) = join_shared_definition(state)
      signatures.push(@lib.TypeIdx::new(types.length().reinterpret_as_uint()))
      types.push(signature)
      rewritten.push(definition)
    }
    output
    .with_type_sec(@lib.TypeSec::new(types))
    .with_func_sec(@lib.FuncSec::new(signatures))
    .with_code_sec(@lib.CodeSec::new(rewritten))
  } else {
    output
  }
  stage("validate_fuel")
  match validate_wasm(output, "FuelPass") {
    Ok(_) => {
      let mode = if codegen is FuelV2 {
        FUEL_V2_CODEGEN_VERSION
      } else if codegen is JoinSpanCompactV2 {
        "join-span-compact-v2-i64"
      } else if codegen is JoinSpanCompact {
        "join-span-compact-i64"
      } else if codegen is JoinSpanCached {
        "join-span-cached-i64"
      } else if codegen is JoinSpan {
        "join-span-i64"
      } else if codegen is P2Prefix {
        "P2-prefix-i64"
      } else if codegen is P2 {
        "P2-i64"
      } else if charge_helper is Some(_) {
        "P1-i64"
      } else {
        "P0-i64"
      }
      let note = "fuel: version=\{codegen.fuel_model()} mode=\{mode} budget=\{config.budget()} functions=\{defined_function_count(wasm_module)} sites=\{site_count} loops=\{count_loops(wasm_module)}"
      Ok(({ ..state, wasm_module: output, }, note))
    }
    Err(error) => Err(error)
  }
}
