///|
pub struct Pipeline {
  passes : Array[&Pass]
  config : InstrumentConfig?
}

///|
pub fn Pipeline::new(passes : Array[&Pass]) -> Self {
  { passes: passes.copy(), config: None, }
}

///|
pub fn Pipeline::builtin(config : InstrumentConfig) -> Self {
  { passes: [], config: Some(config), }
}

///|
fn check_pipeline_config(
  config : InstrumentConfig,
) -> Result[Unit, InstrumentError] {
  if config.profile() is ProductionV1 {
    if !(config.codegen() is FuelV2) {
      return Err(
        UnsupportedFeature(
          "retired production codegen; use fuel-v2 with the original uninstrumented Wasm",
        ),
      )
    }
    if config.stack_config() is None {
      return Err(
        UnsupportedFeature(
          "production-v1 requires --max-stack-units and --max-call-depth",
        ),
      )
    }
  } else if !(config.codegen() is P0) {
    return Err(UnsupportedFeature("fuel-v2 requires production-v1"))
  } else if config.stack_config() is Some(_) {
    return Err(UnsupportedFeature("stack limits require production-v1"))
  }
  if config.profile() is Legacy &&
    config.guard_config().allowed_imports().length() > 0 {
    return Err(
      UnsupportedFeature(
        "allow-import requires production-v1 or fuel-growth-v1",
      ),
    )
  }
  Ok(())
}

///|
/// The fuel-only benchmark mode keeps the production meter and emits no production marker.
/// Stage callbacks observe the start of each named phase.
pub fn Pipeline::run(
  self : Self,
  wasm_module : @lib.Module,
  manifest~ : Bool = false,
  fuel_only~ : Bool = false,
  stage~ : (String) -> Unit = fn(_) { () },
) -> Result[PassResult, InstrumentError] {
  stage("input_policy")
  if fuel_only {
    guard self.config is Some(config) &&
      config.profile() is ProductionV1 &&
      config.codegen() is FuelV2 &&
      !manifest else {
      return Err(
        UnsupportedFeature(
          "fuel-only benchmark requires production-v1 fuel-v2 settings without manifest",
        ),
      )
    }
  }
  if check_pipeline_input(self.config, wasm_module, stage) is Err(error) {
    return Err(error)
  }
  match self.config {
    Some(config) => run_builtin(config, wasm_module, manifest, fuel_only, stage)
    None => run_experimental(self.passes, wasm_module, stage)
  }
}

///|
fn check_pipeline_input(
  config_opt : InstrumentConfig?,
  wasm_module : @lib.Module,
  stage : (String) -> Unit,
) -> Result[Unit, InstrumentError] {
  if config_opt is Some(config) {
    if config.codegen() is FuelV2 &&
      wasm_module.custom_secs.any(fn(section) {
        let @lib.CustomSec(name, _) = section
        name == fuel_span_proof_name()
      }) {
      return Err(UnsupportedFeature("reserved FuelGuard span proof section"))
    }
    if check_pipeline_config(config) is Err(error) {
      return Err(error)
    }
    if !(config.profile() is Legacy) {
      if check_production_input(wasm_module, config.guard_config())
        is Err(error) {
        return Err(error)
      }
    }
  }
  stage("validate_input")
  if validate_wasm(wasm_module, "input") is Err(error) {
    return Err(error)
  }
  stage("input_limits")
  if check_input(wasm_module) is Err(error) {
    return Err(error)
  }
  Ok(())
}

///|
fn run_experimental(
  passes : Array[&Pass],
  input : @lib.Module,
  stage : (String) -> Unit,
) -> Result[PassResult, InstrumentError] {
  let mut current = input
  let stages = []
  let notes = ["profile: experimental custom passes"]
  for pass in passes {
    stage("experimental_rewrite")
    let result = match pass.apply(current) {
      Ok(result) => result
      Err(error) => return Err(error)
    }
    let name = result.pass_name()
    stage("validate_experimental")
    if validate_wasm(result.output(), name) is Err(error) {
      return Err(error)
    }
    stages.push(name)
    notes.append(result.notes())
    current = result.output()
  }
  for @lib.CustomSec(@lib.Name(name), _) in current.custom_secs {
    if name.to_owned() == instrument_marker {
      return Err(
        PipelineAuditFailed(
          "custom pass output cannot claim the built-in pipeline marker",
        ),
      )
    }
  }
  stage("validate_pipeline_output")
  match validate_wasm(current, "before encode") {
    Ok(_) => Ok(PassResult::new("pipeline", current, notes~, stages~))
    Err(error) => Err(error)
  }
}

///|
priv struct BuiltinPlan {
  semantic : SemanticPlan
  fuel : Array[FuelFunctionPlan]
  growth : GrowthPlan
  stack : StackPlan?
  charge_helper : @lib.FuncIdx?
  join_shared : @lib.FuncIdx?
  fuel_helpers : Int32
  site_count : Int32
}

///|
fn plan_builtin(
  config : InstrumentConfig,
  source : @lib.Module,
  fuel_only : Bool,
  stage : (String) -> Unit,
) -> Result[BuiltinPlan, InstrumentError] {
  // The built-in plans derive production site IDs from the function facts.
  let semantic = analyze_semantic_impl(source, false, false, stage)
  stage("rewrite_plan")
  let sites = config.stack_config().map(fn(_) { plan_stack_sites(source) })
  let codegen = config.codegen()
  let fuel_plan = plan_fuel(semantic, sites, source, codegen~)
  let charge_helper = if fuel_plan.any(fn(plan) {
      (plan.shared_charge || codegen is P2Prefix || codegen.uses_join_spans()) &&
      plan.site_end > plan.site_start
    }) {
    Some(func_index(semantic.module_index.function_count()))
  } else {
    None
  }
  let join_shared = if codegen.uses_compact_join() &&
    fuel_plan.any(fn(plan) { plan.shared_charge }) {
    Some(func_index(semantic.module_index.function_count() + 1))
  } else {
    None
  }
  let fuel_helpers = (if charge_helper is Some(_) { 1 } else { 0 }) +
    (if join_shared is Some(_) { 1 } else { 0 })
  let site_count = match sites {
    Some(sites) => sites.count
    None => fuel_plan.last().map(fn(plan) { plan.site_end }).unwrap_or(0)
  }
  let growth_plan = match
    plan_growth(
      source,
      semantic,
      Some(config.guard_config()),
      fuel_plan,
      metering_only=fuel_only,
      fuel_helpers~,
    ) {
    Ok(plan) => plan
    Err(error) => return Err(error)
  }
  let stack_plan = match sites {
    Some(_) if fuel_only => None
    Some(sites) if config.stack_config() is Some(limits) =>
      match
        plan_stack(source, sites, growth_plan, fuel_plan, limits, fuel_helpers~) {
        Ok(plan) => Some(plan)
        Err(error) => return Err(error)
      }
    Some(_) =>
      return Err(PipelineAuditFailed("Stack limits disappeared after planning"))
    None => None
  }
  Ok({
    semantic,
    fuel: fuel_plan,
    growth: growth_plan,
    stack: stack_plan,
    charge_helper,
    join_shared,
    fuel_helpers,
    site_count,
  })
}

///|
/// Inspect the built-in production plan before applying a pass. Local counts
/// describe Fuel staging before subsequent local coalescing.
pub fn Pipeline::plan(
  self : Self,
  source : @lib.Module,
) -> Result[InstrumentPlan, InstrumentError] {
  guard self.config is Some(config) && config.profile() is ProductionV1 else {
    return Err(
      UnsupportedFeature("planning requires a built-in production-v1 pipeline"),
    )
  }
  let stage = fn(_) { () }
  if check_pipeline_input(self.config, source, stage) is Err(error) {
    return Err(error)
  }
  let plan = match plan_builtin(config, source, false, stage) {
    Ok(plan) => plan
    Err(error) => return Err(error)
  }
  guard plan.stack is Some(stack) else {
    return Err(PipelineAuditFailed("production stack plan is missing"))
  }
  let semantic = match production_semantic_plan(source, stack.sites) {
    Ok(semantic) => semantic
    Err(error) => return Err(error)
  }
  let functions = semantic.functions.mapi(fn(index, facts) {
    let row = plan.fuel[index]
    let entry = stack.sites.entries[facts.function_index]
    let site_ids = if entry == 0 { [] } else { [entry] }
    for site in (row.site_start + 1)..<(row.site_end + 1) {
      site_ids.push(site)
    }
    {
      function_index: facts.function_index,
      signature_type_index: facts.type_index,
      template_id: config.codegen().version(),
      appended_local_count: row.appended_locals.length(),
      output_capacity: facts.instruction_count + 8,
      site_ids,
    }
  })
  let index = semantic.module_index
  Ok({
    semantic,
    functions,
    added_function_count: plan.fuel_helpers +
    plan.growth.helper_count() +
    stack.wrappers.length() +
    1,
    added_global_count: 5,
    first_added_function_index: index.function_count(),
    first_added_global_index: index.imported_global_count +
    index.defined_global_count,
  })
}

///|
fn run_builtin(
  config : InstrumentConfig,
  source : @lib.Module,
  manifest : Bool,
  fuel_only : Bool,
  stage : (String) -> Unit,
) -> Result[PassResult, InstrumentError] {
  let plan = match plan_builtin(config, source, fuel_only, stage) {
    Ok(plan) => plan
    Err(error) => return Err(error)
  }
  let {
    semantic,
    fuel: fuel_plan,
    growth: growth_plan,
    stack: stack_plan,
    charge_helper,
    join_shared,
    fuel_helpers,
    site_count,
  } = plan
  let codegen = config.codegen()
  stage("fuel_state")
  let (fuel, fuel_note) = match
    emit_fuel(
      config.fuel(),
      source,
      fuel_plan,
      site_count,
      charge_helper~,
      join_shared~,
      codegen~,
      stage~,
    ) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  stage("growth_rewrite")
  let growth = match
    emit_growth(
      fuel,
      growth_plan,
      semantic.module_index.type_count + fuel_helpers,
      stage~,
    ) {
    Ok(result) => result
    Err(error) => return Err(error)
  }
  // Later passes and audits use FuelState metadata, not its Fuel output module.
  let fuel = { ..fuel, wasm_module: source, }
  if fuel_only {
    stage("validate_pipeline_output")
    if validate_wasm(growth.output(), "fuel-only output") is Err(error) {
      return Err(error)
    }
    stage("result")
    return Ok(
      PassResult::new(
        "pipeline",
        growth.output(),
        notes=["experimental fuel-only benchmark", fuel_note],
        stages=["FuelPass", "GrowCharge"],
      ),
    )
  }
  let stages = ["FuelPass", growth.pass_name()]
  let notes = [fuel_note]
  notes.append(growth.notes())
  let output = if (stack_plan, config.stack_config())
    is (Some(plan), Some(limits)) {
    stage("stack_rewrite")
    let rewritten = if codegen is FuelV2 {
      apply_stack_v2(
        growth.output(),
        source,
        fuel,
        fuel_plan,
        plan,
        limits,
        stage,
      )
    } else {
      apply_stack(
        growth.output(),
        fuel,
        plan,
        limits,
        reuse_checked_bound=codegen is JoinSpanCompactV2,
        stage~,
      )
    }
    match rewritten {
      Ok(result) => {
        stages.push(result.pass_name())
        notes.append(result.notes())
        result.output()
      }
      Err(error) => return Err(error)
    }
  } else {
    growth.output()
  }
  stage("audit_references")
  let stack_layout = if config.profile() is Legacy {
    []
  } else {
    if stack_plan is Some(plan) {
      stage("audit_stack_checks")
      let audit = if codegen is FuelV2 {
        match config.stack_config() {
          Some(limits) =>
            audit_stack_v2(
              growth.output(),
              source,
              output,
              fuel,
              fuel_plan,
              plan,
              limits,
            )
          None => Err(PipelineAuditFailed("Stack v2 limits are missing"))
        }
      } else {
        audit_stack_checks(growth.output(), output, fuel, plan)
      }
      match audit {
        Ok(proofs) => notes.append(proofs)
        Err(error) => return Err(error)
      }
    }
    if audit_pipeline(source, fuel, output, fuel_plan, growth_plan, stack_plan)
      is Err(error) {
      return Err(error)
    }
    match finalize_stack_layout(source, output, stage~) {
      Ok(layout) => {
        if codegen is FuelV2 && stack_plan is Some(plan) {
          if audit_fuel_v2_stack_layout(layout, fuel, growth_plan, plan)
            is Err(error) {
            return Err(error)
          }
        }
        notes.push(
          "stack audit: \{stack_model_version}, functions=\{layout.length()}",
        )
        layout
      }
      Err(error) => return Err(error)
    }
  }
  let (output, stack_layout) = if config.profile() is ProductionV1 &&
    codegen is FuelV2 {
    stage("local_coalescing")
    let optimized = merge_module_locals(output) catch {
      StageRewriteError(reason) => return Err(PipelineAuditFailed(reason))
    }
    stage("validate_local_coalescing")
    if validate_wasm(optimized, "local coalescing") is Err(error) {
      return Err(error)
    }
    let inlined = if fuel.join_failure is Some(failure) {
      let inlined = inline_fuel_v2_leaves(optimized, fuel, fuel_plan.length()) catch {
        StageRewriteError(reason) => return Err(PipelineAuditFailed(reason))
      }
      if inlined is Some(product) &&
        product.code_sec is Some(@lib.CodeSec(functions)) {
        let restored = restore_fuel_v2_inline_leaves(
          product,
          functions,
          fuel_plan.length(),
          fuel.fuel_global,
          failure,
        ) catch {
          StageRewriteError(reason) => return Err(PipelineAuditFailed(reason))
        }
        guard restored is Some(restored) &&
          @binary.encode_module(restored) is Ok(restored_bytes) &&
          @binary.encode_module(optimized) is Ok(audited_bytes) &&
          restored_bytes == audited_bytes else {
          return Err(
            PipelineAuditFailed(
              "Fuel v2 inline leaf reconstruction differs from audited code",
            ),
          )
        }
      }
      inlined
    } else {
      None
    }
    let audit_layout = fn(candidate, record_stage) {
      let layout = match
        finalize_stack_layout(source, candidate, stage=fn(name) {
          if record_stage {
            stage("post_local_coalescing_" + name)
          }
        }) {
        Ok(layout) => layout
        Err(error) => return Err(error)
      }
      if stack_plan is Some(plan) &&
        audit_fuel_v2_stack_layout(layout, fuel, growth_plan, plan)
        is Err(error) {
        return Err(error)
      }
      Ok(layout)
    }
    let candidate = inlined.unwrap_or(optimized)
    match audit_layout(candidate, true) {
      Ok(layout) => (candidate, layout)
      Err(_) if inlined is Some(_) =>
        match audit_layout(optimized, false) {
          Ok(layout) => (optimized, layout)
          Err(error) => return Err(error)
        }
      Err(error) => return Err(error)
    }
  } else {
    (output, stack_layout)
  }
  stage("artifact_marker")
  let profile = match config.profile() {
    ProductionV1 => "production-v1"
    FuelGrowthV1 => "fuel-growth-v1"
    Legacy => "legacy"
  }
  let payload = builtin_artifact_marker(config.profile(), codegen)
  let sections = output.custom_secs.copy()
  if codegen is FuelV2 {
    sections.push(
      fuel_span_proof(fuel_plan, semantic.module_index.imported_function_count),
    )
  }
  sections.push(
    @lib.CustomSec::new(@lib.Name::from_string(instrument_marker), payload),
  )
  let output = output.with_custom_secs(sections)
  stage("validate_pipeline_output")
  if validate_wasm(output, "before encode") is Err(error) {
    return Err(error)
  }
  stage("result")
  notes.push(
    if config.profile() is Legacy {
      "profile: legacy compatibility"
    } else {
      "profile: " + profile
    },
  )
  let manifest_details = if manifest {
    Some(builtin_manifest_details(config, profile))
  } else {
    None
  }
  Ok(
    PassResult::new(
      "pipeline",
      output,
      notes~,
      stack_layout~,
      stages~,
      manifest_details~,
    ),
  )
}
