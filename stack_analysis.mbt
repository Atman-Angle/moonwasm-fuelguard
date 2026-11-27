///|
priv suberror StackAuditError {
  StackError(String)
}

///|
pub(all) struct StackFrameCost {
  parameters : Int64
  results : Int64
  locals : Int64
  operands : Int64
  fixed : Int64
}

///|
fn StackFrameCost::total(self : Self) -> Int64 {
  self.parameters + self.results + self.locals + self.operands + self.fixed
}

///|
fn stack_units(ty : @lib.ValType) -> Int64 {
  if ty is @lib.VecTypeValType {
    2L
  } else {
    1L
  }
}

///|
fn stack_vector_units(types : Array[@lib.ValType]) -> Int64 {
  let mut total = 0L
  for ty in types {
    total += stack_units(ty)
  }
  total
}

///|
priv struct OperandFrame {
  values : Array[@lib.ValType]
  mut units : Int64
}

///|
fn OperandFrame::pop(self : Self) -> @lib.ValType raise StackAuditError {
  match self.values.pop() {
    Some(item) => {
      self.units -= stack_units(item)
      item
    }
    None => raise StackError("operand stack underflow")
  }
}

///|
fn OperandFrame::push(self : Self, item : @lib.ValType) -> Unit {
  self.values.push(item)
  self.units += stack_units(item)
}

///|
priv struct StackLabel {
  backedge : Bool
  mut exit_reached : Bool
}

///|
priv struct FrameScan {
  env : @validate.Env
  leaf : @validate.TcState
  labels : Array[StackLabel]
  calls : Array[Int32]
  mut indirect : Bool
  mut peak : Int64
}

///|
fn[A] stack_result(result : Result[A, String]) -> A raise StackAuditError {
  match result {
    Ok(value) => value
    Err(reason) => raise StackError(reason)
  }
}

///|
fn FrameScan::branch(
  self : Self,
  label : @lib.LabelIdx,
) -> Unit raise StackAuditError {
  let @lib.LabelIdx(depth) = label
  if depth >= self.labels.length().reinterpret_as_uint() {
    raise StackError("branch label outside function")
  }
  let target = self.labels[self.labels.length() - 1 - depth.reinterpret_as_int()]
  if !target.backedge {
    target.exit_reached = true
  }
}

///|
fn FrameScan::observe(self : Self, units : Int64) -> Unit {
  if units > self.peak {
    self.peak = units
  }
}

///|
/// Probe only the operand suffix that a supported non-control instruction can
/// read. The validator supplies the typed result without rescanning the prefix.
fn FrameScan::leaf_step(
  self : Self,
  frame : OperandFrame,
  instruction : @lib.Instruction,
) -> Unit raise StackAuditError {
  let required = match instruction {
    @lib.Call(target) => {
      let @lib.FuncIdx(index) = target
      self.calls.push(index.reinterpret_as_int())
      match self.env.get_functype_by_funcidx(target) {
        Some(@lib.FuncType(params, _)) => params.length()
        None => raise StackError("unknown direct call target")
      }
    }
    @lib.CallIndirect(ty, _) => {
      self.indirect = true
      match self.env.resolve_functype(ty) {
        Some(@lib.FuncType(params, _)) => params.length() + 1
        None => raise StackError("unknown indirect call type")
      }
    }
    _ => 3
  }
  let available = if required < frame.values.length() {
    required
  } else {
    frame.values.length()
  }
  let suffix = Array::make(available, @lib.ValType::i32())
  for i in 0..<available {
    suffix[available - 1 - i] = frame.pop()
  }
  let state = @validate.tc_state_with_owned_stack(self.leaf, suffix)
  let result = stack_result(
    @validate.typecheck_expr_for_probe(@lib.Expr::new([instruction]), state),
  )
  for ty in result.stack {
    frame.push(ty)
  }
}

///|
fn FrameScan::body(
  self : Self,
  code : Array[@lib.Instruction],
  frame : OperandFrame,
  prefix : Int64,
) -> Bool raise StackAuditError {
  self.observe(prefix + frame.units)
  for instruction in code {
    let falls = match instruction {
      @lib.Block(ty, @lib.Expr(body)) =>
        self.control(ty, body, None, false, frame, prefix)
      @lib.Loop(ty, @lib.Expr(body)) =>
        self.control(ty, body, None, true, frame, prefix)
      @lib.If(ty, yes, no) => {
        ignore(frame.pop())
        self.control(ty, yes, Some(no.unwrap_or([])), false, frame, prefix)
      }
      @lib.Br(label) => {
        self.branch(label)
        false
      }
      @lib.BrIf(label) => {
        ignore(frame.pop())
        self.branch(label)
        true
      }
      @lib.BrTable(labels, fallback) => {
        for label in labels {
          self.branch(label)
        }
        self.branch(fallback)
        false
      }
      @lib.Unreachable | @lib.Return => false
      _ => {
        self.leaf_step(frame, instruction)
        true
      }
    }
    if !falls {
      return false
    }
    self.observe(prefix + frame.units)
  }
  true
}

///|
fn FrameScan::control(
  self : Self,
  ty : @lib.BlockType,
  body : Array[@lib.Instruction],
  otherwise : Array[@lib.Instruction]?,
  loop_body : Bool,
  parent : OperandFrame,
  prefix : Int64,
) -> Bool raise StackAuditError {
  if self.labels.length() > 512 {
    raise StackError("stack audit control depth exceeds 512")
  }
  let (params, results) = stack_result(self.env.expand_blocktype(ty))
  for _ in params {
    ignore(parent.pop())
  }
  let live_prefix = prefix + parent.units
  let param_units = stack_vector_units(params)
  let label = StackLabel::{ backedge: loop_body, exit_reached: false, }
  self.labels.push(label)
  let falls = self.body(
    body,
    { values: params.copy(), units: param_units, },
    live_prefix,
  )
  let else_falls = match otherwise {
    Some(other) =>
      self.body(
        other,
        { values: params.copy(), units: param_units, },
        live_prefix,
      )
    None => false
  }
  ignore(self.labels.pop())
  if falls || else_falls || label.exit_reached {
    for ty in results {
      parent.push(ty)
    }
    true
  } else {
    false
  }
}

///|
priv struct ScannedFrame {
  cost : StackFrameCost
  signature : @lib.FuncType
  calls : Array[Int32]
}

///|
fn audit_table_targets(
  wasm : @lib.Module,
) -> Array[Int32] raise StackAuditError {
  let targets = []
  if wasm.elem_sec is Some(@lib.ElemSec(segments)) {
    for @lib.Elem(mode, kind) in segments {
      if mode is @lib.Active(_, _) {
        match kind {
          @lib.FuncsElemKind(indices) =>
            for @lib.FuncIdx(index) in indices {
              targets.push(index.reinterpret_as_int())
            }
          @lib.FuncExprsElemKind(exprs) | @lib.TypedExprsElemKind(_, exprs) =>
            for @lib.Expr(values) in exprs {
              for value in values {
                match value {
                  @lib.RefFunc(@lib.FuncIdx(index)) =>
                    targets.push(index.reinterpret_as_int())
                  @lib.RefNull(_) => ()
                  _ => raise StackError("unresolved indirect target expression")
                }
              }
            }
        }
      }
    }
  }
  targets
}

///|
fn scan_module_frames(
  wasm : @lib.Module,
) -> Array[ScannedFrame] raise StackAuditError {
  let env = @validate.Env::new().with_module(wasm)
  let imported = imported_functions(wasm)
  let result = Array(capacity=env.funcs.length())
  // Imports have a logical boundary frame. Host implementation stack is external.
  for i in 0..<imported {
    let signature = env.funcs[i]
    let @lib.FuncType(params, results) = signature
    result.push({
      signature,
      cost: {
        parameters: stack_vector_units(params),
        results: stack_vector_units(results),
        locals: 0L,
        operands: 0L,
        fixed: 8L,
      },
      calls: [],
    })
  }
  let indirect_targets = audit_table_targets(wasm)
  let extern_table = wasm.table_sec is Some(@lib.TableSec(tables)) &&
    tables.length() == 1 &&
    tables[0] is @lib.Table(ty, _) &&
    is_extern_table(ty)
  if wasm.code_sec is Some(@lib.CodeSec(functions)) {
    for i, @lib.Func(locals, @lib.Expr(code)) in functions {
      let signature = env.funcs[imported + i]
      let @lib.FuncType(params, returns) = signature
      check_audit_body(code, extern_table)
      let local_types = @lib.Locals::from_types(params)
      local_types.append(locals)
      let function_env = env.with_locals(local_types)
      let scan = FrameScan::{
        env: function_env,
        leaf: @validate.make_state_owned(function_env, []),
        labels: [{ backedge: false, exit_reached: false, }],
        calls: [],
        indirect: false,
        peak: 0L,
      }
      ignore(scan.body(code, { values: [], units: 0L, }, 0L))
      let mut local_units = 0L
      for run in locals.runs() {
        local_units += run.count().to_int64() * stack_units(run.val_type())
      }
      if scan.indirect {
        check_audit_indirect_table(wasm)
        scan.calls.append(indirect_targets)
      }
      result.push({
        signature,
        cost: {
          parameters: stack_vector_units(params),
          results: stack_vector_units(returns),
          locals: local_units,
          operands: scan.peak,
          fixed: 8L,
        },
        calls: scan.calls,
      })
    }
  }
  result
}

///|
fn check_audit_indirect_table(wasm : @lib.Module) -> Unit raise StackAuditError {
  if imported_table_count(wasm) != 0 || defined_table_count(wasm) != 1 {
    raise StackError("indirect stack audit requires a fixed internal table")
  }
  let @lib.TableSec(tables) = wasm.table_sec.unwrap()
  let @lib.Table(@lib.TableType(ty, limits), _) = tables[0]
  if @lib.ValType::ref_type(ty) != @lib.ValType::funcref() ||
    !(limits is @lib.I32Limits(initial, Some(max)) && initial == max) {
    raise StackError("indirect stack audit requires a fixed funcref table")
  }
  if wasm.export_sec is Some(@lib.ExportSec(exports)) {
    for @lib.Export(_, target) in exports {
      if target is @lib.TableExternIdx(_) {
        raise StackError(
          "indirect stack audit cannot resolve an exported table",
        )
      }
    }
  }
}

///|
fn check_audit_body(
  code : Array[@lib.Instruction],
  extern_table : Bool,
) -> Unit raise StackAuditError {
  let pending = [(code, 0)]
  while pending.pop() is Some((body, depth)) {
    if depth > 512 {
      raise StackError("stack audit control depth exceeds 512")
    }
    for instruction in body {
      if fuel_v1_rule(instruction_key(instruction)) is None {
        raise StackError(
          "unsupported instruction in stack audit: " +
          Show::to_string(instruction),
        )
      }
      match instruction {
        @lib.If(_, yes, no) => {
          pending.push((yes, depth + 1))
          if no is Some(other) {
            pending.push((other, depth + 1))
          }
        }
        @lib.Block(_, @lib.Expr(child)) | @lib.Loop(_, @lib.Expr(child)) =>
          pending.push((child, depth + 1))
        @lib.TableSet(_)
        | @lib.TableGrow(_)
        | @lib.TableFill(_)
        | @lib.TableCopy(_, _)
        | @lib.TableInit(_, _) =>
          if !extern_table {
            raise StackError("stack audit requires a fixed funcref table")
          }
        _ => ()
      }
    }
  }
}
