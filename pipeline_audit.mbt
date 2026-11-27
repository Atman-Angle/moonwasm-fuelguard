///|
fn same_instruction(
  before : @lib.Instruction,
  after : @lib.Instruction,
) -> Bool {
  // Numeric equality collapses signed zeros and rejects identical NaNs.
  match (before, after) {
    (@lib.F32Const(@lib.F32(a)), @lib.F32Const(@lib.F32(b))) =>
      a.reinterpret_as_uint() == b.reinterpret_as_uint()
    (@lib.F64Const(@lib.F64(a)), @lib.F64Const(@lib.F64(b))) =>
      a.reinterpret_as_uint64() == b.reinterpret_as_uint64()
    (a, b) => a == b
  }
}

///|
fn same_global_initializer(before : @lib.Expr, after : @lib.Expr) -> Bool {
  let @lib.Expr(before) = before
  let @lib.Expr(after) = after
  if before.length() != after.length() {
    return false
  }
  for i, item in before {
    if !same_instruction(item, after[i]) {
      return false
    }
  }
  true
}

///|
fn same_expr(before : @lib.Expr, after : @lib.Expr) -> Bool {
  let @lib.Expr(before) = before
  let @lib.Expr(after) = after
  if before.length() != after.length() {
    return false
  }
  for i, instruction in before {
    match (instruction, after[i]) {
      (@lib.Block(a, @lib.Expr(left)), @lib.Block(b, @lib.Expr(right)))
      | (@lib.Loop(a, @lib.Expr(left)), @lib.Loop(b, @lib.Expr(right))) =>
        if a != b || !same_expr(@lib.Expr::new(left), @lib.Expr::new(right)) {
          return false
        }
      (@lib.If(a, left_yes, left_no), @lib.If(b, right_yes, right_no)) => {
        if a != b ||
          !same_expr(@lib.Expr::new(left_yes), @lib.Expr::new(right_yes)) {
          return false
        }
        match (left_no, right_no) {
          (Some(left), Some(right)) =>
            if !same_expr(@lib.Expr::new(left), @lib.Expr::new(right)) {
              return false
            }
          (None, None) => ()
          _ => return false
        }
      }
      _ => if !same_instruction(instruction, after[i]) { return false }
    }
  }
  true
}

///|
fn same_code_section(before : @lib.CodeSec?, after : @lib.CodeSec?) -> Bool {
  match (before, after) {
    (Some(@lib.CodeSec(left)), Some(@lib.CodeSec(right))) => {
      if left.length() != right.length() {
        return false
      }
      for i, function in left {
        let @lib.Func(left_locals, left_body) = function
        let @lib.Func(right_locals, right_body) = right[i]
        if left_locals.iter().collect() != right_locals.iter().collect() ||
          !same_expr(left_body, right_body) {
          return false
        }
      }
      true
    }
    (None, None) => true
    _ => false
  }
}

///|
fn audit_pipeline(
  source : @lib.Module,
  fuel : FuelState,
  output : @lib.Module,
  fuel_plan : Array[FuelFunctionPlan],
  growth : GrowthPlan,
  stack : StackPlan?,
) -> Result[Unit, InstrumentError] {
  if source.import_sec != output.import_sec {
    return Err(PipelineAuditFailed("import list changed"))
  }
  if source.mem_sec != output.mem_sec ||
    source.table_sec != output.table_sec ||
    source.data_sec != output.data_sec ||
    source.data_cnt_sec != output.data_cnt_sec ||
    source.tag_sec != output.tag_sec {
    return Err(
      PipelineAuditFailed("memory, table, data or tag declarations changed"),
    )
  }
  if source.custom_secs != output.custom_secs ||
    source.name_sec != output.name_sec ||
    source.raw_name_sec_payload != output.raw_name_sec_payload {
    return Err(PipelineAuditFailed("source custom sections changed"))
  }
  let before_globals = match source.global_sec {
    Some(@lib.GlobalSec(entries)) => entries
    None => []
  }
  guard output.global_sec is Some(@lib.GlobalSec(globals)) else {
    return Err(PipelineAuditFailed("diagnostic globals are missing"))
  }
  let generated_globals = if stack is Some(_) { 5 } else { 3 }
  if globals.length() != before_globals.length() + generated_globals {
    return Err(
      PipelineAuditFailed("original or generated global indexes changed"),
    )
  }
  for i, original in before_globals {
    let @lib.Global(original_type, original_init) = original
    let @lib.Global(actual_type, actual_init) = globals[i]
    if original_type != actual_type ||
      !same_global_initializer(original_init, actual_init) {
      return Err(PipelineAuditFailed("original global at index \{i} changed"))
    }
  }
  let base = imported_global_count(source) + before_globals.length()
  let entries = match source.export_sec {
    Some(@lib.ExportSec(exports)) => exports.copy()
    None => []
  }
  for i, name in [trap_export_name, trap_site_export_name] {
    entries.push(
      @lib.Export::new(
        @lib.Name::from_string(name),
        @lib.ExternIdx::global(stack_global(base + i + 1)),
      ),
    )
    let @lib.Global(ty, value) = globals[before_globals.length() + i + 1]
    if ty != @lib.GlobalType::new(@lib.ValType::i32(), true) ||
      value != @lib.Expr::new([stack_const(0)]) {
      return Err(
        PipelineAuditFailed("diagnostic global differs from the versioned ABI"),
      )
    }
  }
  let source_exports = source.with_export_sec(@lib.ExportSec::new(entries))
  let expected = match stack {
    Some(plan) =>
      rewrite_stack_references(source_exports, plan.external, plan.indirect) catch {
        StackError(reason) => return Err(PipelineAuditFailed(reason))
      }
    None => source_exports
  }
  if output.export_sec != expected.export_sec ||
    output.start_sec != expected.start_sec ||
    output.elem_sec != expected.elem_sec {
    return Err(
      PipelineAuditFailed(
        "export, start or element reference differs from the plan",
      ),
    )
  }
  audit_function_indexes(source, fuel, output, fuel_plan, growth, stack)
}

///|
fn audit_function_indexes(
  source : @lib.Module,
  fuel : FuelState,
  output : @lib.Module,
  fuel_plan : Array[FuelFunctionPlan],
  growth : GrowthPlan,
  stack : StackPlan?,
) -> Result[Unit, InstrumentError] {
  let expected_types = match source.type_sec {
    Some(@lib.TypeSec(entries)) => entries.copy()
    None => []
  }
  let expected_signatures = match source.func_sec {
    Some(@lib.FuncSec(entries)) => entries.copy()
    None => []
  }
  let original_defined = expected_signatures.length()
  let output_functions = match output.code_sec {
    Some(@lib.CodeSec(bodies)) => bodies
    None => []
  }
  let fuel_helper = match (fuel.join_failure, fuel.prefix_failure) {
    (Some(_) as failure, _) | (_, Some(_) as failure) => failure
    _ => fuel.charge_helper
  }
  if fuel_helper is Some(helper) {
    let expected = imported_functions(source) + original_defined
    if func_number(helper) != expected {
      return Err(PipelineAuditFailed("wrong charge helper index"))
    }
    let (signature, definition) = charge_helper_definition(fuel)
    let body = match output.code_sec {
      Some(@lib.CodeSec(bodies)) => bodies.get(original_defined)
      None => None
    }
    if body != Some(definition) {
      return Err(
        PipelineAuditFailed("charge helper body differs from the plan"),
      )
    }
    expected_signatures.push(
      @lib.TypeIdx::new(expected_types.length().reinterpret_as_uint()),
    )
    expected_types.push(signature)
  }
  if fuel.join_shared is Some(helper) {
    let expected = imported_functions(source) + original_defined + 1
    if func_number(helper) != expected || fuel.join_failure is None {
      return Err(PipelineAuditFailed("wrong shared span helper index"))
    }
    let (signature, definition) = join_shared_definition(fuel)
    let body = match output.code_sec {
      Some(@lib.CodeSec(bodies)) => bodies.get(original_defined + 1)
      None => None
    }
    if body != Some(definition) {
      return Err(
        PipelineAuditFailed("shared span helper body differs from the plan"),
      )
    }
    expected_signatures.push(
      @lib.TypeIdx::new(expected_types.length().reinterpret_as_uint()),
    )
    expected_types.push(signature)
  }
  for entry in [growth.memory, growth.table] {
    if entry is Some(helper) {
      let (signature, definition) = helper.generate(fuel)
      if output_functions.get(expected_signatures.length()) != Some(definition) {
        return Err(PipelineAuditFailed("Growth helper differs from the plan"))
      }
      expected_signatures.push(
        @lib.TypeIdx::new(expected_types.length().reinterpret_as_uint()),
      )
      expected_types.push(signature)
    }
  }
  let first_wrapper = expected_signatures.length()
  if stack is Some(plan) {
    let env = @validate.Env::new().with_module(source)
    for i, wrapper in plan.wrappers {
      guard env.get_functypeidx_by_funcidx(func_index(wrapper.target))
        is Some(ty) else {
        return Err(PipelineAuditFailed("wrapper source type index is missing"))
      }
      expected_signatures.push(ty)
      let index = first_wrapper + i
      guard index < output_functions.length() else {
        return Err(PipelineAuditFailed("missing planned wrapper"))
      }
      let @lib.Func(_, @lib.Expr(body)) = output_functions[index]
      let calls = body.filter(fn(instruction) { instruction is @lib.Call(_) })
      if calls != [@lib.Instruction::call(func_index(wrapper.target))] {
        return Err(
          PipelineAuditFailed(
            "wrapper does not call its planned original target",
          ),
        )
      }
    }
  }
  if stack is Some(plan) && fuel.fuel_v2 {
    let failure_index = plan.first_function + plan.wrappers.length()
    if failure_index !=
      imported_functions(source) + expected_signatures.length() {
      return Err(PipelineAuditFailed("wrong Stack v2 failure helper index"))
    }
    let (_, units_sign, _, _) = stack_v2_layout(plan) catch {
      StackError(reason) => return Err(PipelineAuditFailed(reason))
    }
    let (signature, definition) = stack_v2_failure_definition(fuel, units_sign)
    let failure_body = output_functions.get(
      failure_index - imported_functions(source),
    )
    if failure_body != Some(definition) {
      return Err(
        PipelineAuditFailed("Stack v2 failure helper differs from the plan"),
      )
    }
    expected_signatures.push(
      @lib.TypeIdx::new(expected_types.length().reinterpret_as_uint()),
    )
    expected_types.push(signature)
  }
  let actual_types = match output.type_sec {
    Some(@lib.TypeSec(entries)) => entries
    None => []
  }
  let actual_signatures = match output.func_sec {
    Some(@lib.FuncSec(entries)) => entries
    None => []
  }
  if expected_types != actual_types || expected_signatures != actual_signatures {
    return Err(
      PipelineAuditFailed("function or type indexes differ from the plan"),
    )
  }
  let source_functions = match source.code_sec {
    Some(@lib.CodeSec(bodies)) => bodies
    None => []
  }
  for i in 0..<original_defined {
    let @lib.Func(before, _) = source_functions[i]
    let @lib.Func(after, _) = output_functions[i]
    let expected = before.copy()
    for ty in fuel_plan[i].appended_locals {
      expected.push(ty)
    }
    if stack is Some(plan) && fuel.fuel_v2 {
      let calls = plan.sites.calls[imported_functions(source) + i]
      if !calls.is_empty() {
        expected.push(@lib.ValType::i64())
        let has_entry_balance = calls.any(fn(call) {
          match call.0 {
            @lib.Call(target) => {
              let target = func_number(target)
              target < imported_functions(source) ||
              !plan.sites.calls[target].is_empty()
            }
            @lib.CallIndirect(_, _) => true
            _ => false
          }
        })
        if has_entry_balance {
          expected.push(@lib.ValType::i64())
        }
      }
    } else if stack is Some(plan) && plan.indirect_locals[i] is Some(_) {
      expected.push(@lib.ValType::i32())
    }
    if expected != after {
      return Err(
        PipelineAuditFailed(
          "original or generated local indexes differ from the plan",
        ),
      )
    }
  }
  Ok(())
}

///|
priv struct StackCheckAudit {
  globals : StackGlobals
  plan : StackPlan
  imported : Int32
  owner : Int32
  cursor : Ref[Int32]
  mut reused : Int32
  mut witness : String?
}

///|
// Fuel/Growth supplies the original structured control flow. Consume the
// actual Stack output alongside it so an elided check cannot prove itself.
fn StackCheckAudit::body(
  self : Self,
  before : Array[@lib.Instruction],
  after : Array[@lib.Instruction],
  inherited : (Int64, Int32),
  reachable_at_entry : Bool,
) -> ((Int64, Int32), Bool) raise StackAuditError {
  let mut offset = 0
  let mut proof = inherited
  let mut reachable = reachable_at_entry
  let calls = self.plan.sites.calls[self.owner]
  let original_count = self.plan.costs.length()
  let template = []
  for instruction in before {
    match instruction {
      @lib.Call(target) if func_number(target) < original_count => {
        let site = verify_stack_call(instruction, calls, self.cursor)
        if !reachable {
          guard after.get(offset) is Some(actual) && actual == instruction else {
            raise StackError(
              "function \{self.owner} site \{site}: unreachable call was rewritten",
            )
          }
          offset += 1
          continue
        }
        let callee = func_number(target)
        let cost = self.plan.costs[callee]
        let leaf = callee >= self.imported &&
          self.plan.sites.calls[callee].is_empty()
        template.clear()
        self.globals.reserve(template, cost, stack_const(site), leaf~)
        template.push(instruction)
        self.globals.release(template, cost, leaf~)
        let full_end = offset + template.length()
        if full_end <= after.length() && after[offset:full_end] == template[:] {
          if reachable && cost > proof.0 {
            proof = (cost, site)
          }
          offset = full_end
          continue
        }
        if callee < self.imported || cost > proof.0 {
          raise StackError(
            "function \{self.owner} site \{site}: missing explicit stack check for C=\{cost}",
          )
        }
        template.clear()
        self.globals.reserve(
          template,
          cost,
          stack_const(site),
          leaf~,
          checked=true,
        )
        template.push(instruction)
        self.globals.release(template, cost, leaf~)
        let end = offset + template.length()
        if end > after.length() || after[offset:end] != template[:] {
          raise StackError(
            "function \{self.owner} site \{site}: invalid reused stack reservation",
          )
        }
        self.reused += 1
        if self.witness is None {
          self.witness = Some(
            "site=\{site} C=\{cost} checked_at=\{proof.1} bound=\{proof.0}",
          )
        }
        offset = end
        continue
      }
      @lib.CallIndirect(ty, table) => {
        let site = verify_stack_call(instruction, calls, self.cursor)
        if !reachable {
          guard after.get(offset) is Some(actual) && actual == instruction else {
            raise StackError(
              "site \{site}: unreachable indirect call was rewritten",
            )
          }
          offset += 1
          continue
        }
        guard self.plan.indirect_types.get(ty) is Some(wrapped) &&
          self.plan.indirect_locals[self.owner - self.imported] is Some(temp) else {
          raise StackError("missing planned indirect reservation")
        }
        let expected = stack_indirect_call(site, temp, wrapped, table)
        let end = offset + expected.length()
        if end > after.length() || after[offset:end] != expected[:] {
          raise StackError(
            "site \{site}: indirect wrapper arguments differ from the plan",
          )
        }
        offset = end
        continue
      }
      _ => ()
    }
    guard after.get(offset) is Some(actual) else {
      raise StackError("stack output truncated function \{self.owner}")
    }
    match (instruction, actual) {
      (@lib.Block(ty, @lib.Expr(a)), @lib.Block(other, @lib.Expr(b)))
      | (@lib.Loop(ty, @lib.Expr(a)), @lib.Loop(other, @lib.Expr(b))) if ty ==
        other => ignore(self.body(a, b, proof, reachable))
      (@lib.If(ty, yes, no), @lib.If(other, actual_yes, actual_no)) if ty ==
        other &&
        (no is None) == (actual_no is None) => {
        let (then_proof, then_falls) = self.body(
          yes, actual_yes, proof, reachable,
        )
        let (else_proof, else_falls) = match (no, actual_no) {
          (Some(a), Some(b)) => self.body(a, b, proof, reachable)
          _ => (proof, reachable)
        }
        let has_branch = contains_branch_instruction(yes) ||
          (match no {
            Some(body) => contains_branch_instruction(body)
            None => false
          })
        if reachable && !has_branch {
          match (then_falls, else_falls) {
            (true, true) =>
              proof = if then_proof.0 < else_proof.0 {
                then_proof
              } else {
                else_proof
              }
            (true, false) => proof = then_proof
            (false, true) => proof = else_proof
            (false, false) => reachable = false
          }
        } else if reachable {
          proof = inherited
        }
      }
      (@lib.Br(_) | @lib.BrTable(_, _) | @lib.Return | @lib.Unreachable, _) =>
        reachable = false
      (a, b) =>
        if !same_instruction(a, b) {
          raise StackError(
            "unexpected StackPass instruction in function \{self.owner}",
          )
        }
    }
    offset += 1
  }
  if after.length() != offset {
    raise StackError("unexpected StackPass suffix in function \{self.owner}")
  }
  (proof, reachable)
}

///|
fn audit_stack_checks(
  metered : @lib.Module,
  output : @lib.Module,
  fuel : FuelState,
  plan : StackPlan,
) -> Result[Array[String], InstrumentError] {
  try {
    let before = match metered.code_sec {
      Some(@lib.CodeSec(bodies)) => bodies
      None => []
    }
    guard output.code_sec is Some(@lib.CodeSec(after)) &&
      after.length() == before.length() + plan.wrappers.length() else {
      raise StackError("incorrect StackPass function count")
    }
    let imported = imported_functions(metered)
    let global_base = imported_global_count(metered) +
      defined_global_count(metered)
    let globals = StackGlobals::{
      units: stack_global(global_base),
      depth: stack_global(global_base + 1),
      code: fuel.trap_global,
      site: fuel.trap_site_global,
    }
    let reused = []
    for i, function in before {
      let owner = imported + i
      if owner >= plan.costs.length() {
        if function != after[i] {
          raise StackError("StackPass changed helper function \{owner}")
        }
        continue
      }
      let @lib.Func(_, @lib.Expr(code)) = function
      let @lib.Func(_, @lib.Expr(actual)) = after[i]
      let cursor = Ref(0)
      let audit = StackCheckAudit::{
        globals,
        plan,
        imported,
        owner,
        cursor,
        reused: 0,
        witness: None,
      }
      ignore(audit.body(code, actual, (0L, 0), true))
      if cursor.val != plan.sites.calls[owner].length() {
        raise StackError(
          "StackPass did not consume original calls in function \{owner}",
        )
      }
      if audit.witness is Some(witness) {
        reused.push(
          "stack reuse function=\{owner} calls=\{audit.reused} \{witness}",
        )
      }
    }
    let templates = StackRewrite::{
      original_count: plan.costs.length(),
      imported_count: imported,
      costs: plan.costs,
      leaves: [],
      globals,
      reuse_checked_bound: false,
      indirect_types: plan.indirect_types,
    }
    for i, wrapper in plan.wrappers {
      if after[before.length() + i] !=
        templates.wrapper(wrapper.target, wrapper.signature, wrapper.entry_site) {
        raise StackError(
          "planned stack wrapper differs at function \{plan.first_function + i}",
        )
      }
    }
    Ok(reused)
  } catch {
    StackError(reason) => Err(PipelineAuditFailed(reason))
  }
}

///|
fn audit_stack_v2(
  metered : @lib.Module,
  source : @lib.Module,
  output : @lib.Module,
  fuel : FuelState,
  sources : Array[FuelFunctionPlan],
  plan : StackPlan,
  config : StackConfig,
) -> Result[Array[String], InstrumentError] {
  try {
    guard config.max_units == plan.max_units &&
      config.max_depth == plan.max_depth else {
      raise StackError("Stack v2 limits differ from the planned layout")
    }
    let expected = emit_stack_v2(metered, source, fuel, sources, plan)
    if !same_code_section(expected.code_sec, output.code_sec) {
      raise StackError("Stack v2 code differs from its verified plan")
    }
    let expected_globals = match expected.global_sec {
      Some(@lib.GlobalSec(globals)) => globals
      None => []
    }
    let actual_globals = match output.global_sec {
      Some(@lib.GlobalSec(globals)) => globals
      None => []
    }
    if expected_globals.length() != actual_globals.length() {
      raise StackError(
        "Stack v2 global count differs from its plan: expected \{expected_globals.length()}, got \{actual_globals.length()}",
      )
    }
    for index, expected_global in expected_globals {
      let @lib.Global(expected_type, expected_init) = expected_global
      let @lib.Global(actual_type, actual_init) = actual_globals[index]
      if expected_type != actual_type ||
        !same_global_initializer(expected_init, actual_init) {
        raise StackError(
          "Stack v2 global at index \{index} differs from its plan",
        )
      }
    }
    if expected.type_sec != output.type_sec ||
      expected.func_sec != output.func_sec {
      raise StackError("Stack v2 indexes differ from its verified plan")
    }
    if expected.export_sec != output.export_sec ||
      expected.start_sec != output.start_sec ||
      expected.elem_sec != output.elem_sec {
      raise StackError("Stack v2 references differ from its verified plan")
    }
    Ok([])
  } catch {
    StackError(reason) => Err(PipelineAuditFailed(reason))
  }
}

///|
fn audit_fuel_v2_stack_layout(
  layout : Array[StackLayout],
  fuel : FuelState,
  growth : GrowthPlan,
  plan : StackPlan,
) -> Result[Unit, InstrumentError] {
  for
    helper in [
      fuel.join_failure,
      Some(func_index(plan.first_function + plan.wrappers.length())),
      growth.memory.map(fn(helper) { helper.function_index }),
      growth.table.map(fn(helper) { helper.function_index }),
    ] {
    if helper is Some(index) {
      let row = layout[func_number(index)]
      if row.actual_cost > STACK_HELPER_FRAME_CAP || row.auxiliary_peak != 0L {
        return Err(
          StackAnalysisFailed(
            "Fuel v2 helper \{row.function_index}: expected an independent frame within \{STACK_HELPER_FRAME_CAP} units",
          ),
        )
      }
    }
  }
  for i, wrapper in plan.wrappers {
    if wrapper.entry_site is Some(_) {
      let entry = layout[plan.first_function + i]
      let target = layout[wrapper.target]
      let active = entry.actual_cost + target.actual_cost
      if active > target.shared_cost {
        return Err(
          StackAnalysisFailed(
            "entry wrapper \{entry.function_index} with target \{wrapper.target}: A=\{active} exceeds C=\{target.shared_cost}",
          ),
        )
      }
    }
  }
  Ok(())
}
