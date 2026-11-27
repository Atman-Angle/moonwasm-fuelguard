///|
test "production requires stack budgets on the AST entry point" {
  let config = InstrumentConfig::new(
    FuelConfig::new(10L).unwrap(),
    GuardConfig::new().unwrap(),
  )
  assert_true(
    Pipeline::builtin(config).run(@lib.Module::new())
    is Err(UnsupportedFeature(_)),
  )
}

///|
test "production rejects every retired library layout" {
  let source = @lib.Module::new()
  let fuel = FuelConfig::new(10L).unwrap()
  let guards = GuardConfig::new().unwrap()
  let stack = Some(StackConfig::new(1000L, 1L).unwrap())
  for
    codegen in [
      P0,
      P1,
      P2,
      P2Prefix,
      JoinSpan,
      JoinSpanCached,
      JoinSpanCompact,
      JoinSpanCompactV2,
    ] {
    let built = Pipeline::builtin(
      InstrumentConfig::new(fuel, guards, stack~, codegen~),
    )
    assert_true(
      built.run(source) is Err(UnsupportedFeature(message)) &&
      message.contains("retired production codegen"),
    )
  }
}

///|
test "legacy rejects a self tail call without a fuel price" {
  let source = function_module([], [], [
    @lib.Instruction::return_call(func_index(0)),
  ])
  assert_true(validate_wasm(source, "test") is Ok(_))
  let config = InstrumentConfig::new(
    FuelConfig::new(1L).unwrap(),
    GuardConfig::new().unwrap(),
    profile=Legacy,
  )
  let result = Pipeline::builtin(config).run(source)
  assert_true(
    result
    is Err(UnsupportedFeature("opcode outside fuel-v1 pricing allowlist")),
  )
}

///|
fn pipeline_audit_fixture() -> @lib.Module {
  function_module([], [], [@lib.Instruction::nop()]).with_export_sec(
    @lib.ExportSec::new([
      @lib.Export::new(
        @lib.Name::from_string("run"),
        @lib.ExternIdx::func(func_index(0)),
      ),
    ]),
  )
}

///|
test "builtin production stages are deterministic and preserve the source AST" {
  let source = pipeline_audit_fixture()
  let source_bytes = encode_wasm(source).unwrap()
  let config = InstrumentConfig::new(
    FuelConfig::new(10L).unwrap(),
    GuardConfig::new().unwrap(),
    stack=Some(StackConfig::new(1000L, 1L).unwrap()),
  )
  let built = Pipeline::builtin(config)
  let first = built.run(source).unwrap()
  let second = built.run(source).unwrap()
  assert_eq(first.stages(), ["FuelPass", "GrowthPass", "StackPass"])
  assert_eq(encode_wasm(source).unwrap(), source_bytes)
  assert_eq(
    encode_wasm(first.output()).unwrap(),
    encode_wasm(second.output()).unwrap(),
  )
  assert_true(built.run(first.output()) is Err(UnsupportedFeature(_)))
}

///|
test "production plan agrees with emitted append ranges and diagnostic sites" {
  let source = pipeline_audit_fixture()
  let config = InstrumentConfig::new(
    FuelConfig::new(10L).unwrap(),
    GuardConfig::new().unwrap(),
    stack=Some(StackConfig::new(1000L, 2L).unwrap()),
  )
  let built = Pipeline::builtin(config)
  let plan = built.plan(source).unwrap()
  let result = built.run(source).unwrap().output()
  assert_eq(plan.semantic.version, "fuel-v2")
  assert_eq(plan.functions[0].site_ids, [1, 2])
  assert_eq(plan.semantic.sites[0].first_ordinal, -1)
  assert_eq(plan.semantic.sites[1].first_ordinal, 0)
  let site = resolve_production_site(source, 2).unwrap().unwrap()
  assert_eq(site.function_index, plan.semantic.sites[1].function_index)
  assert_eq(
    site.instruction_ordinal,
    Some(plan.semantic.sites[1].first_ordinal),
  )
  let output = analyze_semantic(result).module_index
  assert_eq(
    output.function_count(),
    plan.first_added_function_index + plan.added_function_count,
  )
  assert_eq(
    output.defined_global_count,
    plan.first_added_global_index + plan.added_global_count,
  )
}

///|
test "production plan includes active expression-form element targets" {
  let target = func_index(0)
  let offset = @lib.Expr::new([@lib.Instruction::i32_const(@lib.I32::new(0))])
  let element = @lib.Elem::new(
    @lib.ElemMode::active(@lib.TableIdx::new(0U), offset),
    @lib.ElemKind::func_exprs([
      @lib.Expr::new([@lib.Instruction::ref_func(target)]),
    ]),
  )
  let table = @lib.TableType::new(
    @lib.RefType::abs(@lib.AbsHeapType::func()),
    @lib.Limits::i32(1U, Some(1U)),
  )
  let source = pipeline_audit_fixture()
    .with_table_sec(@lib.TableSec::new([@lib.Table::new(table, None)]))
    .with_elem_sec(@lib.ElemSec::new([element]))
  let pipeline = Pipeline::builtin(
    InstrumentConfig::new(
      FuelConfig::new(10L).unwrap(),
      GuardConfig::new(max_table_elements=Some(1)).unwrap(),
      stack=Some(StackConfig::new(1000L, 2L).unwrap()),
    ),
  )
  let plan = match pipeline.plan(source) {
    Ok(plan) => plan
    Err(error) => fail(error.message())
  }
  let output = pipeline.run(source).unwrap().output()
  assert_eq(plan.semantic.module_index.element_function_indices, [0])
  assert_eq(
    analyze_semantic(output).module_index.function_count(),
    plan.first_added_function_index + plan.added_function_count,
  )
}

///|
test "global initializer audit distinguishes floating-point bit patterns" {
  let expr = fn(bits : UInt64) {
    @lib.Expr::new([
      @lib.Instruction::f64_const(@lib.F64::new(bits.reinterpret_as_double())),
    ])
  }
  assert_true(
    same_global_initializer(
      expr(0xFFF8_0000_0000_0042UL),
      expr(0xFFF8_0000_0000_0042UL),
    ),
  )
  assert_false(
    same_global_initializer(
      expr(0xFFF8_0000_0000_0042UL),
      expr(0xFFF8_0000_0000_0043UL),
    ),
  )
  assert_false(
    same_global_initializer(expr(0UL), expr(0x8000_0000_0000_0000UL)),
  )
}

///|
test "reference audit rejects a valid export that bypasses its wrapper" {
  let source = pipeline_audit_fixture()
  let limits = StackConfig::new(1000L, 1L).unwrap()
  let sites = plan_stack_sites(source)
  let semantic = analyze_semantic(source)
  let fuel_plan = plan_fuel(semantic, Some(sites), source)
  let growth = plan_growth(source, semantic, None, fuel_plan).unwrap()
  let plan = plan_stack(source, sites, growth, fuel_plan, limits).unwrap()
  let (fuel, _) = emit_fuel(
    FuelConfig::new(10L).unwrap(),
    source,
    fuel_plan,
    sites.count,
  ).unwrap()
  let metered = emit_growth(fuel, growth, semantic.module_index.type_count).unwrap()
  let output = apply_stack(metered.output(), fuel, plan, limits)
    .unwrap()
    .output()
  assert_true(
    audit_pipeline(source, fuel, output, fuel_plan, growth, Some(plan)) is Ok(_),
  )
  guard output.export_sec is Some(@lib.ExportSec(entries)) else {
    abort("expected exports")
  }
  let redirected = entries.copy()
  redirected[0] = @lib.Export::new(
    @lib.Name::from_string("run"),
    @lib.ExternIdx::func(func_index(0)),
  )
  let changed = output.with_export_sec(@lib.ExportSec::new(redirected))
  assert_true(validate_wasm(changed, "test") is Ok(_))
  assert_true(
    audit_pipeline(source, fuel, changed, fuel_plan, growth, Some(plan))
    is Err(PipelineAuditFailed(_)),
  )
}

///|
test "Fuel v2 audits dominating stack reuse and rejects unchecked calls" {
  let source = stack_fixture(
    [
      audit_func([], []),
      audit_func(
        [
          @lib.ValType::i64(),
          @lib.ValType::i64(),
          @lib.ValType::i64(),
          @lib.ValType::i64(),
        ],
        [],
      ),
      audit_func([], [
        @lib.Instruction::call(@lib.FuncIdx::new(0U)),
        @lib.Instruction::i32_const(@lib.I32::new(1)),
        @lib.Instruction::if_(
          @lib.BlockType::void_(),
          [@lib.Instruction::call(@lib.FuncIdx::new(1U))],
          Some([@lib.Instruction::call(@lib.FuncIdx::new(1U))]),
        ),
        @lib.Instruction::call(@lib.FuncIdx::new(1U)),
        @lib.Instruction::call(@lib.FuncIdx::new(1U)),
      ]),
      audit_func([], [
        @lib.Instruction::i32_const(@lib.I32::new(1)),
        @lib.Instruction::if_(
          @lib.BlockType::void_(),
          [
            @lib.Instruction::br(@lib.LabelIdx::new(0U)),
            @lib.Instruction::call(@lib.FuncIdx::new(1U)),
          ],
          Some([
            @lib.Instruction::br(@lib.LabelIdx::new(0U)),
            @lib.Instruction::call(@lib.FuncIdx::new(1U)),
          ]),
        ),
        @lib.Instruction::call(@lib.FuncIdx::new(1U)),
      ]),
      audit_func([], [
        @lib.Instruction::i32_const(@lib.I32::new(1)),
        @lib.Instruction::if_(
          @lib.BlockType::void_(),
          [
            @lib.Instruction::br(@lib.LabelIdx::new(0U)),
            @lib.Instruction::call(@lib.FuncIdx::new(1U)),
          ],
          Some([@lib.Instruction::call(@lib.FuncIdx::new(1U))]),
        ),
        @lib.Instruction::call(@lib.FuncIdx::new(1U)),
      ]),
      audit_func([], [
        @lib.Instruction::i32_const(@lib.I32::new(1)),
        @lib.Instruction::if_(
          @lib.BlockType::void_(),
          [
            @lib.Instruction::i32_const(@lib.I32::new(1)),
            @lib.Instruction::br_if(@lib.LabelIdx::new(0U)),
            @lib.Instruction::call(@lib.FuncIdx::new(1U)),
          ],
          None,
        ),
        @lib.Instruction::call(@lib.FuncIdx::new(1U)),
      ]),
    ],
    [],
  )
  let sites = plan_stack_sites(source)
  let semantic = analyze_semantic(source)
  let fuel_plan = plan_fuel(semantic, Some(sites), source, codegen=FuelV2)
  let charge_helper = if fuel_plan.any(fn(plan) {
      plan.site_end > plan.site_start
    }) {
    Some(
      @lib.FuncIdx::new(
        semantic.module_index.function_count().reinterpret_as_uint(),
      ),
    )
  } else {
    None
  }
  let fuel_helpers = if charge_helper is Some(_) { 1 } else { 0 }
  let growth_plan = plan_growth(
    source,
    semantic,
    None,
    fuel_plan,
    fuel_helpers~,
  ).unwrap()
  let (fuel, _) = emit_fuel(
    FuelConfig::new(32L).unwrap(),
    source,
    fuel_plan,
    sites.count,
    charge_helper~,
    codegen=FuelV2,
  ).unwrap()
  let metered = emit_growth(
    fuel,
    growth_plan,
    semantic.module_index.type_count + fuel_helpers,
  ).unwrap()
  let limits = StackConfig::new(1000L, 2L).unwrap()
  let plan = plan_stack(
    source,
    sites,
    growth_plan,
    fuel_plan,
    limits,
    fuel_helpers~,
  ).unwrap()
  let output = apply_stack(
      metered.output(),
      fuel,
      plan,
      limits,
      reuse_checked_bound=true,
    )
    .unwrap()
    .output()
  let without_reuse = apply_stack(
      metered.output(),
      fuel,
      plan,
      limits,
      reuse_checked_bound=false,
    )
    .unwrap()
    .output()
  let proofs = audit_stack_checks(metered.output(), output, fuel, plan).unwrap()
  assert_eq(proofs.length(), 1)
  assert_true(proofs[0].contains("stack reuse function=2 calls=2"))
  assert_false(proofs.any(fn(proof) { proof.contains("function=3") }))
  assert_false(proofs.any(fn(proof) { proof.contains("function=4") }))
  assert_false(proofs.any(fn(proof) { proof.contains("function=5") }))
  assert_true(proofs[0].contains(" C="))
  assert_true(
    encode_wasm(output).unwrap().length() <
    encode_wasm(without_reuse).unwrap().length(),
  )
  assert_true(
    audit_stack_checks(metered.output(), metered.output(), fuel, plan)
    is Err(PipelineAuditFailed(_)),
  )
}

///|
test "Fuel v2 Growth and Stack helper frames satisfy the shared layout" {
  let source = function_module([], [], [
      @lib.Instruction::i32_const(@lib.I32::new(1)),
      @lib.Instruction::memory_grow(@lib.MemIdx::new(0U)),
      @lib.Instruction::drop(),
    ])
    .with_mem_sec(
      @lib.MemSec::new([@lib.MemType::new(@lib.Limits::i32(1U, Some(2U)))]),
    )
    .with_export_sec(
      @lib.ExportSec::new([
        @lib.Export::new(
          @lib.Name::from_string("grow"),
          @lib.ExternIdx::func(@lib.FuncIdx::new(0U)),
        ),
      ]),
    )
  let result = run_builtin(
    InstrumentConfig::new(
      FuelConfig::new(128L).unwrap(),
      GuardConfig::new(max_memory_pages=Some(2)).unwrap(),
      stack=Some(StackConfig::new(1000L, 2L).unwrap()),
    ),
    source,
    false,
    false,
    fn(_) { () },
  ).unwrap()
  assert_true(result.stack_layout().length() >= 3)
  for row in result.stack_layout() {
    assert_true(row.within_shared_cost)
    assert_true(row.actual_cost <= row.shared_cost)
  }
}

///|
priv struct MarkerPass {}

///|
impl Pass for MarkerPass with fn apply(_, input) {
  let forged = @lib.CustomSec::new(
    @lib.Name::from_string(instrument_marker),
    b"production-v1",
  )
  Ok(PassResult::new("forged", input.with_custom_secs([forged])))
}

///|
test "third-party pass combinations receive experimental results only" {
  let source = pipeline_audit_fixture()
  let fuel = FuelPass::new(FuelConfig::new(10L).unwrap())
  let experimental = Pipeline::new([fuel as &Pass]).run(source).unwrap()
  assert_eq(experimental.notes()[0], "profile: experimental custom passes")
  assert_eq(experimental.output().custom_secs, source.custom_secs)
  assert_eq(experimental.stack_layout().length(), 0)
  let production_claim = Pipeline::new([MarkerPass::{ } as &Pass]).run(source)
  assert_true(production_claim is Err(PipelineAuditFailed(_)))
}

///|
test "fuel-only ablation cannot claim the production marker or sidecar" {
  let source = pipeline_audit_fixture()
  let config = InstrumentConfig::new(
    FuelConfig::new(10L).unwrap(),
    GuardConfig::new().unwrap(),
    stack=Some(StackConfig::new(1000L, 1L).unwrap()),
  )
  let pipeline = Pipeline::builtin(config)
  assert_true(
    pipeline.run(source, manifest=true, fuel_only=true)
    is Err(UnsupportedFeature(_)),
  )
  let ablation = pipeline.run(source, fuel_only=true).unwrap()
  assert_eq(ablation.stages(), ["FuelPass", "GrowCharge"])
  assert_eq(ablation.stack_layout().length(), 0)
  assert_true(
    verify_production_artifact(encode_wasm(ablation.output()).unwrap())
    is Err(UnsupportedFeature(_)),
  )
}

///|
test "P1 growth helper and its charge share the original logical reservation" {
  let source = function_module([], [], [
    @lib.Instruction::i32_const(@lib.I32::new(0)),
    @lib.Instruction::memory_grow(@lib.MemIdx::new(0U)),
    @lib.Instruction::drop(),
  ]).with_mem_sec(
    @lib.MemSec::new([@lib.MemType::new(@lib.Limits::i32(1U, Some(2U)))]),
  )
  let build = fn(layout) {
    run_builtin(
      InstrumentConfig::new(
        FuelConfig::new(64L).unwrap(),
        GuardConfig::new(max_memory_pages=Some(2)).unwrap(),
        stack=Some(StackConfig::new(1000L, 1L).unwrap()),
        codegen=layout,
      ),
      source,
      false,
      false,
      fn(_) { () },
    )
  }
  let baseline = build(P0)
  let candidate = build(P1)
  guard baseline is Ok(p0) else {
    fail("P0: " + baseline.unwrap_err().message())
  }
  guard candidate is Ok(p1) else {
    fail("P1: " + candidate.unwrap_err().message())
  }
  guard p1.stack_layout()[:] is [owner, charge, grow] else {
    fail("expected original, charge and grow")
  }
  assert_eq(owner.shared_cost, p0.stack_layout()[0].shared_cost)
  assert_eq(charge.final_frame.parameters, 2L)
  assert_eq(charge.final_frame.operands, 2L)
  assert_eq(charge.auxiliary_peak, 0L)
  assert_eq(grow.auxiliary_peak, charge.actual_cost)
  assert_eq(owner.auxiliary_peak, grow.actual_cost)
  assert_true(
    owner.within_shared_cost &&
    charge.within_shared_cost &&
    grow.within_shared_cost,
  )
  let bytes = encode_wasm(p1.output()).unwrap()
  assert_true(verify_production_artifact(bytes) is Ok(_))
  assert_true(
    verify_builtin_artifact(bytes, ProductionV1, codegen=P0) is Err(_),
  )
}

///|
test "P1 with no charged instructions keeps the original code and adds no helper" {
  let source = function_module([], [], [])
  let config = InstrumentConfig::new(
    FuelConfig::new(1L).unwrap(),
    GuardConfig::new().unwrap(),
    stack=Some(StackConfig::new(1000L, 1L).unwrap()),
    codegen=P1,
  )
  let p1 = run_builtin(config, source, false, false, fn(_) { () }).unwrap()
  assert_eq(p1.output().func_sec, source.func_sec)
  assert_eq(p1.output().code_sec, source.code_sec)
  assert_eq(p1.stack_layout().length(), 1)
}
