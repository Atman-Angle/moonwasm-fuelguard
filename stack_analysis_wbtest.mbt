///|
fn stack_fixture(
  bodies : Array[@lib.Func],
  result_types : Array[@lib.ValType],
) -> @lib.Module {
  @lib.Module::new(
    type_sec=Some(
      @lib.TypeSec::new([
        @lib.RecType::new(
          @lib.SubType::comp_type(@lib.CompType::func([], result_types)),
        ),
      ]),
    ),
    func_sec=Some(
      @lib.FuncSec::new(bodies.map(fn(_) { @lib.TypeIdx::new(0U) })),
    ),
    code_sec=Some(@lib.CodeSec::new(bodies)),
  )
}

///|
fn audit_func(
  locals : Array[@lib.ValType],
  body : Array[@lib.Instruction],
) -> @lib.Func {
  @lib.Func::new(@lib.Locals::from_types(locals), @lib.Expr::new(body))
}

///|
test "stack audit rejects unpriced vector instructions and refuses SIMD valtypes" {
  let v128 = @lib.ValType::v128()
  let simd_body = [
    @lib.Instruction::block(
      @lib.BlockType::void_(),
      @lib.Expr::new([
        @lib.Instruction::local_get(@lib.LocalIdx::new(0U)),
        @lib.Instruction::local_get(@lib.LocalIdx::new(1U)),
        @lib.Instruction::v128_and(),
        @lib.Instruction::drop(),
      ]),
    ),
  ]
  let simd_source = stack_fixture([audit_func([v128, v128], simd_body)], [])
  assert_true(
    finalize_stack_layout(simd_source, simd_source)
    is Err(StackAnalysisFailed(_)),
  )
}

///|
test "stack audit measures typed i64 values and ignores polymorphic dead code" {
  let i64 = @lib.ValType::i64()
  let body = [
    @lib.Instruction::block(
      @lib.BlockType::void_(),
      @lib.Expr::new([
        @lib.Instruction::local_get(@lib.LocalIdx::new(0U)),
        @lib.Instruction::local_get(@lib.LocalIdx::new(1U)),
        @lib.Instruction::i64_and(),
        @lib.Instruction::drop(),
        @lib.Instruction::br(@lib.LabelIdx::new(0U)),
        @lib.Instruction::drop(), // stack-polymorphic
        @lib.Instruction::local_get(@lib.LocalIdx::new(0U)),
        @lib.Instruction::local_get(@lib.LocalIdx::new(0U)),
        @lib.Instruction::local_get(@lib.LocalIdx::new(0U)),
      ]),
    ),
  ]
  // Drop three concrete values at the end of the unreachable block.
  guard body[0] is @lib.Block(_, @lib.Expr(inner)) else {
    fail("fixture block")
  }
  for _ in 0..<3 {
    inner.push(@lib.Instruction::drop())
  }
  let source = stack_fixture([audit_func([i64, i64], body)], [])
  let audit = finalize_stack_layout(source, source).unwrap()
  assert_eq(audit[0].final_frame.locals, 2L)
  assert_eq(audit[0].final_frame.operands, 2L)
  assert_eq(audit[0].actual_cost, 12L)
}

///|
test "stack units keep the vector conservatism clause for the model" {
  assert_eq(stack_units(@lib.ValType::v128()), 2L)
  assert_eq(stack_units(@lib.ValType::i64()), 1L)
}

///|
test "packed stack limits and reservation costs reject values beyond 31 bits" {
  let maximum = 2_147_483_647L
  assert_true(StackConfig::new(maximum, maximum) is Ok(_))
  assert_true(
    StackConfig::new(maximum + 1L, maximum) is Err(InvalidStackLimits(_, _)),
  )
  assert_true(
    StackConfig::new(maximum, maximum + 1L) is Err(InvalidStackLimits(_, _)),
  )
  assert_eq(check_shared_cost(0, maximum), maximum)
  for cost in [0L, maximum + 1L] {
    try check_shared_cost(3, cost) catch {
      StackError(message) => {
        assert_true(message.contains("function 3"))
        assert_true(message.contains("31 bits"))
      }
    } noraise {
      _ => fail("accepted a shared cost outside the packed stack domain")
    }
  }
}

///|
test "generated sequential edges take max and nested live frames add" {
  let call = fn(index : UInt32) {
    @lib.Instruction::call(@lib.FuncIdx::new(index))
  }
  let source = stack_fixture([audit_func([], [])], [])
  let output = stack_fixture(
    [
      audit_func([], [call(1U), call(3U)]),
      audit_func([], [call(2U)]),
      audit_func([@lib.ValType::i64()], []),
      audit_func([@lib.ValType::i64(), @lib.ValType::i64()], []),
    ],
    [],
  )
  let audit = finalize_stack_layout(source, output).unwrap()
  // A(2)=9, A(1)=8+9, A(3)=10, A(0)=8+max(17,10).
  assert_eq(audit[0].auxiliary_peak, 17L)
  assert_eq(audit[0].actual_cost, 25L)
  assert_eq(audit[1].actual_cost, 17L)
  assert_eq(audit[2].actual_cost, 9L)
  assert_eq(audit[3].actual_cost, 10L)
}

///|
test "generated entry keeps its descendants but does not charge the source callee twice" {
  let source = stack_fixture([audit_func([], [])], [])
  let output = stack_fixture(
    [
      audit_func([], []),
      audit_func([], [
        @lib.Instruction::call(@lib.FuncIdx::new(2U)),
        @lib.Instruction::call(@lib.FuncIdx::new(0U)),
      ]),
      audit_func([], []),
    ],
    [],
  ).with_export_sec(
    @lib.ExportSec::new([
      @lib.Export::new(
        @lib.Name::from_string("entry"),
        @lib.ExternIdx::func(@lib.FuncIdx::new(1U)),
      ),
    ]),
  )
  let audit = finalize_stack_layout(source, output).unwrap()
  assert_true(audit[1].entry_wrapper)
  assert_eq(audit[1].actual_cost, 16L)
  assert_eq(audit[0].actual_cost, 8L)
}

///|
test "stack audit rejects excess actual frames and recursive generated graphs" {
  let source = stack_fixture([audit_func([], [])], [])
  let exact = stack_fixture(
    [audit_func(Array::make(120, @lib.ValType::i64()), [])],
    [],
  )
  let row = finalize_stack_layout(source, exact).unwrap()[0]
  assert_eq(row.actual_cost, 128L)
  assert_eq(row.actual_cost, row.shared_cost)
  let inflated = stack_fixture(
    [audit_func(Array::make(121, @lib.ValType::i64()), [])],
    [],
  )
  assert_true(
    finalize_stack_layout(source, inflated) is Err(StackAnalysisFailed(_)),
  )
  let recursive = stack_fixture(
    [
      audit_func([], []),
      audit_func([], [@lib.Instruction::call(@lib.FuncIdx::new(1U))]),
    ],
    [],
  )
  assert_true(
    finalize_stack_layout(source, recursive) is Err(StackAnalysisFailed(_)),
  )
}
