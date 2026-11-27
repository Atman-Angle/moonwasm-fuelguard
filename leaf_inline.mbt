///|
fn fuel_v2_leaf_body(
  function : @lib.Func,
  ty : @lib.FuncType,
  fuel : @lib.GlobalIdx,
  failure : @lib.FuncIdx,
) -> (Int32, Array[@lib.Instruction])? {
  let @lib.FuncType(params, results) = ty
  guard params.length() == 1 &&
    params[0] == @lib.ValType::i32() &&
    results.length() == 1 &&
    results[0] == @lib.ValType::i32() else {
    return None
  }
  let @lib.Func(locals, @lib.Expr(body)) = function
  guard locals.iter().next() is None &&
    body.length() >= 9 &&
    body.length() <= 18 else {
    return None
  }
  guard body[:8]
    is [
      @lib.GlobalGet(read),
      @lib.I64Const(@lib.I64(cost)),
      @lib.I64Sub,
      @lib.GlobalSet(write),
      @lib.GlobalGet(check),
      @lib.I64Const(@lib.I64(0L)),
      @lib.I64GeS,
      @lib.If(
        block_type,
        [],
        Some([@lib.I32Const(@lib.I32(site)), @lib.Call(helper)]),
      ),
    ] &&
    read == fuel &&
    write == fuel &&
    check == fuel &&
    cost > 0L &&
    site > 0 &&
    helper == failure &&
    block_type == @lib.BlockType::void_() else {
    return None
  }
  for instruction in body[8:] {
    match instruction {
      @lib.LocalGet(@lib.LocalIdx(0U))
      | @lib.I32Const(_)
      | @lib.I32Load(_)
      | @lib.I32Load8S(_)
      | @lib.I32Load8U(_)
      | @lib.I32Load16S(_)
      | @lib.I32Load16U(_)
      | @lib.I32Add
      | @lib.I32Sub
      | @lib.I32And
      | @lib.I32Or
      | @lib.I32Xor
      | @lib.I32Shl
      | @lib.I32ShrU
      | @lib.I32Eqz
      | @lib.I32Eq
      | @lib.I32Ne
      | @lib.I32LtU
      | @lib.I32LtS
      | @lib.I32GeU
      | @lib.I32GeS => ()
      _ => return None
    }
  }
  Some((site, body))
}

///|
priv struct MeteredLeaf {
  target : @lib.FuncIdx
  signature : @lib.TypeIdx
  body : Array[@lib.Instruction]
}

///|
fn MeteredLeaf::inline_block(
  self : Self,
  scratch : @lib.LocalIdx,
) -> @lib.Instruction {
  let code = [@lib.Instruction::local_set(scratch)]
  for instruction in self.body {
    code.push(
      match instruction {
        @lib.LocalGet(@lib.LocalIdx(0U)) => @lib.Instruction::local_get(scratch)
        _ => instruction
      },
    )
  }
  @lib.Instruction::block(
    @lib.BlockType::type_idx(self.signature),
    @lib.Expr::new(code),
  )
}

///|
fn metered_leaves(
  module_ : @lib.Module,
  functions : Array[@lib.Func],
  original_count : Int32,
  fuel : @lib.GlobalIdx,
  failure : @lib.FuncIdx,
) -> Array[(Int32, MeteredLeaf)] {
  guard module_.func_sec is Some(@lib.FuncSec(signatures)) else { return [] }
  let env = @validate.Env::new().with_module(module_)
  let imported = imported_functions(module_)
  let leaves = []
  for index in 0..<original_count {
    let target = imported + index
    if fuel_v2_leaf_body(functions[index], env.funcs[target], fuel, failure)
      is Some((site, body)) {
      leaves.push(
        (
          site,
          { target: func_index(target), signature: signatures[index], body, },
        ),
      )
    }
  }
  leaves
}

///|
fn inline_fuel_v2_leaves(
  module_ : @lib.Module,
  fuel : FuelState,
  original_count : Int32,
) -> @lib.Module? raise StageRewriteError {
  guard fuel.join_failure is Some(failure) &&
    module_.code_sec is Some(@lib.CodeSec(bodies)) else {
    return None
  }
  let leaves = metered_leaves(
    module_,
    bodies,
    original_count,
    fuel.fuel_global,
    failure,
  )
  if leaves.is_empty() {
    return None
  }
  let targets = Map([], capacity=leaves.length())
  for (_, leaf) in leaves {
    targets.set(leaf.target, leaf)
  }
  let env = @validate.Env::new().with_module(module_)
  let imported = imported_functions(module_)
  let rewritten = bodies.copy()
  let mut any_changed = false
  for owner in 0..<original_count {
    let @lib.Func(locals, @lib.Expr(body)) = bodies[owner]
    let @lib.FuncType(params, _) = env.funcs[imported + owner]
    let scratch = local_index(params.length() + locals.length())
    let mut changed = false
    let code = rewrite_generated_stage(body, fn(instruction, out) {
      if instruction is @lib.Call(target) && targets.get(target) is Some(leaf) {
        out.push(leaf.inline_block(scratch))
        changed = true
        true
      } else {
        false
      }
    })
    if changed {
      let new_locals = locals.copy()
      new_locals.push(@lib.ValType::i32())
      rewritten[owner] = @lib.Func::new(new_locals, @lib.Expr::new(code))
      any_changed = true
    }
  }
  if any_changed {
    Some(module_.with_code_sec(@lib.CodeSec::new(rewritten)))
  } else {
    None
  }
}

///|
fn restore_fuel_v2_inline_leaves(
  module_ : @lib.Module,
  functions : Array[@lib.Func],
  original_count : Int32,
  fuel : @lib.GlobalIdx,
  failure : @lib.FuncIdx,
) -> @lib.Module? raise StageRewriteError {
  let leaves = metered_leaves(module_, functions, original_count, fuel, failure)
  if leaves.is_empty() {
    return None
  }
  let sites = Map(leaves)
  let env = @validate.Env::new().with_module(module_)
  let imported = imported_functions(module_)
  let rewritten = functions.copy()
  let mut any_changed = false
  for owner in 0..<original_count {
    let @lib.Func(locals, @lib.Expr(body)) = functions[owner]
    let @lib.FuncType(params, _) = env.funcs[imported + owner]
    let last = locals.length() - 1
    guard last >= 0 && locals[last] == @lib.ValType::i32() else { continue }
    let scratch = local_index(params.length() + last)
    let mut changed = false
    let code = rewrite_generated_stage(body, fn(instruction, out) {
      if instruction is @lib.Block(_, @lib.Expr(child)) &&
        child.get(8)
        is Some(
          @lib.If(_, [], Some([@lib.I32Const(@lib.I32(site)), @lib.Call(_)])),
        ) &&
        sites.get(site) is Some(leaf) &&
        instruction == leaf.inline_block(scratch) {
        changed = true
        out.push(@lib.Instruction::call(leaf.target))
        true
      } else {
        false
      }
    })
    if changed {
      let runs = locals.runs()
      if runs.pop() is Some(last_run) && last_run.count > 1U {
        runs.push(@lib.LocalRun::new(last_run.count - 1U, last_run.vt))
      }
      rewritten[owner] = @lib.Func::new(
        @lib.Locals::from_decl_runs_preserving_groups(runs),
        @lib.Expr::new(code),
      )
      any_changed = true
    }
  }
  if any_changed {
    Some(module_.with_code_sec(@lib.CodeSec::new(rewritten)))
  } else {
    None
  }
}
