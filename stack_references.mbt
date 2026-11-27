///|
fn stack_wrapper_index(
  mapping : Array[@lib.FuncIdx?],
  target : @lib.FuncIdx,
) -> @lib.FuncIdx raise StackAuditError {
  guard mapping[func_number(target)] is Some(wrapper) else {
    raise StackError("missing wrapper for original function reference")
  }
  wrapper
}

///|
fn stack_element_expr(
  expression : @lib.Expr,
  indirect : Array[@lib.FuncIdx?],
) -> @lib.Expr raise StackAuditError {
  let @lib.Expr(body) = expression
  if body is [@lib.RefFunc(target)] {
    @lib.Expr::new([
      @lib.Instruction::ref_func(stack_wrapper_index(indirect, target)),
    ])
  } else {
    expression // The production policy has checked that other expressions cannot contain ref.func.
  }
}

///|
fn rewrite_stack_references(
  wasm : @lib.Module,
  external : Array[@lib.FuncIdx?],
  indirect : Array[@lib.FuncIdx?],
) -> @lib.Module raise StackAuditError {
  let mut output = wasm
  if wasm.export_sec is Some(@lib.ExportSec(exports)) {
    let updated = Array(capacity=exports.length())
    for entry in exports {
      let @lib.Export(name, reference) = entry
      match reference {
        @lib.FuncExternIdx(target) =>
          updated.push(
            @lib.Export::new(
              name,
              @lib.ExternIdx::func(stack_wrapper_index(external, target)),
            ),
          )
        _ => updated.push(entry)
      }
    }
    output = output.with_export_sec(@lib.ExportSec::new(updated))
  }
  if wasm.start_sec is Some(@lib.StartSec(target)) {
    output = output.with_start_sec(
      @lib.StartSec::new(stack_wrapper_index(external, target)),
    )
  }
  if wasm.elem_sec is Some(@lib.ElemSec(segments)) {
    let updated = Array(capacity=segments.length())
    for entry in segments {
      let @lib.Elem(mode, kind) = entry
      if mode is @lib.Active(_, _) {
        let mapped = match kind {
          @lib.FuncsElemKind(targets) => {
            let wrapped = Array(capacity=targets.length())
            for target in targets {
              wrapped.push(stack_wrapper_index(indirect, target))
            }
            @lib.ElemKind::funcs(wrapped)
          }
          @lib.FuncExprsElemKind(exprs) => {
            let wrapped = Array(capacity=exprs.length())
            for expr in exprs {
              wrapped.push(stack_element_expr(expr, indirect))
            }
            @lib.ElemKind::func_exprs(wrapped)
          }
          @lib.TypedExprsElemKind(ty, exprs) => {
            let wrapped = Array(capacity=exprs.length())
            for expr in exprs {
              wrapped.push(stack_element_expr(expr, indirect))
            }
            @lib.ElemKind::typed_exprs(ty, wrapped)
          }
        }
        updated.push(@lib.Elem::new(mode, mapped))
      } else {
        updated.push(entry)
      }
    }
    output = output.with_elem_sec(@lib.ElemSec::new(updated))
  }
  output
}
