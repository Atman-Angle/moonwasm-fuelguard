///|
/// Maps every instruction in an expression, rebuilding the arrays instead of
/// mutating the source expression.
fn map_expr(
  expr : @lib.Expr,
  f : (@lib.Instruction) -> @lib.Instruction,
) -> @lib.Expr {
  let @lib.Expr(instructions) = expr
  @lib.Expr::new(map_instructions(instructions, f))
}

///|
fn map_instructions(
  instructions : Array[@lib.Instruction],
  f : (@lib.Instruction) -> @lib.Instruction,
) -> Array[@lib.Instruction] {
  let out : Array[@lib.Instruction] = Array(capacity=instructions.length())
  for instruction in instructions {
    out.push(f(map_instruction_children(instruction, f)))
  }
  out
}

///|
/// Rebinds the nested expressions of structured instructions, then leaves the
/// instruction for the caller's mapper.
fn map_instruction_children(
  instruction : @lib.Instruction,
  f : (@lib.Instruction) -> @lib.Instruction,
) -> @lib.Instruction {
  match instruction {
    @lib.Block(block_type, body) =>
      @lib.Instruction::block(block_type, map_expr(body, f))
    @lib.Loop(block_type, body) =>
      @lib.Instruction::loop_(block_type, map_expr(body, f))
    @lib.If(block_type, then_body, else_body) =>
      @lib.Instruction::if_(
        block_type,
        map_instructions(then_body, f),
        match else_body {
          Some(body) => Some(map_instructions(body, f))
          None => None
        },
      )
    @lib.Try(block_type, body, catches, delegate) =>
      @lib.Instruction::try_(
        block_type,
        map_expr(body, f),
        map_legacy_catches(catches, f),
        delegate~,
      )
    @lib.TryTable(block_type, catches, body) =>
      @lib.Instruction::try_table(block_type, catches, map_expr(body, f))
    _ => instruction
  }
}

///|
fn map_legacy_catches(
  catches : Array[@lib.LegacyCatch],
  f : (@lib.Instruction) -> @lib.Instruction,
) -> Array[@lib.LegacyCatch] {
  let out : Array[@lib.LegacyCatch] = Array(capacity=catches.length())
  for item in catches {
    match item {
      @lib.LegacyCatch(tag, body) =>
        out.push(@lib.LegacyCatch::tagged(tag, map_expr(body, f)))
      @lib.LegacyCatchAll(body) =>
        out.push(@lib.LegacyCatch::all(map_expr(body, f)))
    }
  }
  out
}

///|
fn count_loops_in_expr(expr : @lib.Expr) -> Int32 {
  let @lib.Expr(instructions) = expr
  count_loops_in_instructions(instructions)
}

///|
fn count_loops_in_instructions(instructions : Array[@lib.Instruction]) -> Int32 {
  let mut count = 0
  for instruction in instructions {
    match instruction {
      @lib.Loop(_, body) => {
        count += 1
        count += count_loops_in_expr(body)
      }
      @lib.Block(_, body) => count += count_loops_in_expr(body)
      @lib.If(_, then_body, else_body) => {
        count += count_loops_in_instructions(then_body)
        match else_body {
          Some(body) => count += count_loops_in_instructions(body)
          None => ()
        }
      }
      @lib.Try(_, body, catches, _) => {
        count += count_loops_in_expr(body)
        for item in catches {
          match item {
            @lib.LegacyCatch(_, catch_body) =>
              count += count_loops_in_expr(catch_body)
            @lib.LegacyCatchAll(catch_body) =>
              count += count_loops_in_expr(catch_body)
          }
        }
      }
      @lib.TryTable(_, _, body) => count += count_loops_in_expr(body)
      _ => ()
    }
  }
  count
}

///|
fn defined_function_count(wasm_module : @lib.Module) -> Int32 {
  match wasm_module.func_sec {
    Some(@lib.FuncSec(types)) => types.length()
    None => 0
  }
}

///|
fn count_loops(wasm_module : @lib.Module) -> Int32 {
  match wasm_module.code_sec {
    Some(@lib.CodeSec(functions)) => {
      let mut count = 0
      for function in functions {
        let @lib.Func(_, body) = function
        count += count_loops_in_expr(body)
      }
      count
    }
    None => 0
  }
}

///|
#warnings("-unused_value")
fn imported_function_count(wasm_module : @lib.Module) -> Int32 {
  match wasm_module.import_sec {
    None => 0
    Some(@lib.ImportSec(imports)) => {
      let mut count = 0
      for entry in imports {
        if entry is @lib.Import(_, _, @lib.FuncExternType(_)) {
          count += 1
        }
      }
      count
    }
  }
}

///|
fn imported_global_count(wasm_module : @lib.Module) -> Int32 {
  match wasm_module.import_sec {
    None => 0
    Some(@lib.ImportSec(imports)) => {
      let mut count = 0
      for entry in imports {
        if entry is @lib.Import(_, _, @lib.GlobalExternType(_)) {
          count += 1
        }
      }
      count
    }
  }
}

///|
fn defined_global_count(wasm_module : @lib.Module) -> Int32 {
  match wasm_module.global_sec {
    Some(@lib.GlobalSec(globals)) => globals.length()
    None => 0
  }
}

///|
/// Resolves a global type index, flattening recursive type groups the same way
/// the binary format orders subtypes.
fn subtype_at(type_sec : @lib.TypeSec, index : Int32) -> @lib.SubType? {
  let @lib.TypeSec(rec_types) = type_sec
  let mut current = 0
  for rec_type in rec_types {
    let subtypes = match rec_type {
      @lib.SingleRecType(subtype) => [subtype]
      @lib.GroupRecType(group) => group
    }
    for subtype in subtypes {
      if current == index {
        return Some(subtype)
      }
      current += 1
    }
  }
  None
}

///|
fn function_type_index(
  wasm_module : @lib.Module,
  defined_index : Int32,
) -> @lib.TypeIdx? {
  match wasm_module.func_sec {
    Some(@lib.FuncSec(types)) =>
      if defined_index >= 0 && defined_index < types.length() {
        Some(types[defined_index])
      } else {
        None
      }
    None => None
  }
}

///|
fn function_comp_type(
  wasm_module : @lib.Module,
  defined_index : Int32,
) -> @lib.CompType? {
  let type_idx = match function_type_index(wasm_module, defined_index) {
    Some(type_idx) => type_idx
    None => return None
  }
  let index = match type_idx {
    @lib.TypeIdx(index) => index
    @lib.RecIdx(_) => return None
  }
  let type_sec = match wasm_module.type_sec {
    Some(type_sec) => type_sec
    None => return None
  }
  match subtype_at(type_sec, index.reinterpret_as_int()) {
    Some(subtype) => Some(subtype.get_comptype())
    None => None
  }
}

///|
fn function_param_count(
  wasm_module : @lib.Module,
  defined_index : Int32,
) -> Int32 {
  match function_comp_type(wasm_module, defined_index) {
    Some(@lib.FuncCompType(params, _)) => params.length()
    _ => 0
  }
}

///|
fn function_body_local_count(
  wasm_module : @lib.Module,
  defined_index : Int32,
) -> Int32 {
  match wasm_module.code_sec {
    Some(@lib.CodeSec(functions)) =>
      if defined_index >= 0 && defined_index < functions.length() {
        let @lib.Func(locals, _) = functions[defined_index]
        locals.length()
      } else {
        0
      }
    None => 0
  }
}
