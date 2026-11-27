///|
priv suberror StageRewriteError {
  StageRewriteError(String)
}

///|
/// Traverse a validated function body in original instruction order.
fn rewrite_generated_stage(
  body : Array[@lib.Instruction],
  replace : (@lib.Instruction, Array[@lib.Instruction]) -> Bool raise StageRewriteError,
) -> Array[@lib.Instruction] raise StageRewriteError {
  let out = Array(capacity=body.length())
  for instruction in body {
    if replace(instruction, out) {
      continue
    }
    let rewritten = match instruction {
      @lib.Block(ty, @lib.Expr(child)) =>
        @lib.Instruction::block(
          ty,
          @lib.Expr::new(rewrite_generated_stage(child, replace)),
        )
      @lib.Loop(ty, @lib.Expr(child)) =>
        @lib.Instruction::loop_(
          ty,
          @lib.Expr::new(rewrite_generated_stage(child, replace)),
        )
      @lib.If(ty, yes, no) => {
        let new_yes = rewrite_generated_stage(yes, replace)
        let new_no = match no {
          Some(other) => Some(rewrite_generated_stage(other, replace))
          None => None
        }
        @lib.Instruction::if_(ty, new_yes, new_no)
      }
      @lib.Try(ty, @lib.Expr(child), catches, delegate) => {
        let inner = @lib.Expr::new(rewrite_generated_stage(child, replace))
        let new_catches = []
        for item in catches {
          new_catches.push(
            match item {
              @lib.LegacyCatch(tag, @lib.Expr(body)) =>
                @lib.LegacyCatch::tagged(
                  tag,
                  @lib.Expr::new(rewrite_generated_stage(body, replace)),
                )
              @lib.LegacyCatchAll(@lib.Expr(body)) =>
                @lib.LegacyCatch::all(
                  @lib.Expr::new(rewrite_generated_stage(body, replace)),
                )
            },
          )
        }
        @lib.Instruction::try_(ty, inner, new_catches, delegate~)
      }
      @lib.TryTable(ty, catches, @lib.Expr(child)) =>
        @lib.Instruction::try_table(
          ty,
          catches,
          @lib.Expr::new(rewrite_generated_stage(child, replace)),
        )
      _ => instruction
    }
    out.push(rewritten)
  }
  out
}
