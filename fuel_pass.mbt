///|
/// Inline charge sequence shared by every metering site. It reads the fuel
/// global once, writes it once, and only touches the trap code global on the
/// terminating path.
fn fuel_charge_instructions(
  fuel_global : @lib.GlobalIdx,
  temp_local : @lib.LocalIdx,
  trap_global : @lib.GlobalIdx,
) -> Array[@lib.Instruction] {
  [
    @lib.Instruction::global_get(fuel_global),
    @lib.Instruction::i32_const(@lib.I32::new(1)),
    @lib.Instruction::i32_sub(),
    @lib.Instruction::local_tee(temp_local),
    @lib.Instruction::global_set(fuel_global),
    @lib.Instruction::local_get(temp_local),
    @lib.Instruction::i32_const(@lib.I32::new(0)),
    @lib.Instruction::i32_lt_s(),
    @lib.Instruction::if_(
      @lib.BlockType::void_(),
      [
        @lib.Instruction::i32_const(@lib.I32::new(TrapCode::Fuel.to_code())),
        @lib.Instruction::global_set(trap_global),
        @lib.Instruction::unreachable_(),
      ],
      None,
    ),
  ]
}

///|
fn prepend_instructions(
  prefix : Array[@lib.Instruction],
  expr : @lib.Expr,
) -> @lib.Expr {
  let @lib.Expr(body) = expr
  let out : Array[@lib.Instruction] = Array(
    capacity=prefix.length() + body.length(),
  )
  for instruction in prefix {
    out.push(instruction)
  }
  for instruction in body {
    out.push(instruction)
  }
  @lib.Expr::new(out)
}

///|
fn charge_function_body(
  body : @lib.Expr,
  fuel_global : @lib.GlobalIdx,
  temp_local : @lib.LocalIdx,
  trap_global : @lib.GlobalIdx,
) -> @lib.Expr {
  let charged = map_expr(body, fn(instruction) {
    match instruction {
      @lib.Loop(block_type, loop_body) =>
        @lib.Instruction::loop_(
          block_type,
          prepend_instructions(
            fuel_charge_instructions(fuel_global, temp_local, trap_global),
            loop_body,
          ),
        )
      _ => instruction
    }
  })
  prepend_instructions(
    fuel_charge_instructions(fuel_global, temp_local, trap_global),
    charged,
  )
}

///|
fn apply_fuel(
  config : FuelConfig,
  wasm_module : @lib.Module,
) -> Result[PassResult, InstrumentError] {
  let state = match add_fuel_state(wasm_module, config.budget()) {
    Ok(state) => state
    Err(error) => return Err(error)
  }
  let functions = match wasm_module.code_sec {
    Some(@lib.CodeSec(functions)) => functions
    None => []
  }
  let loop_count = count_loops(wasm_module)
  let rewritten : Array[@lib.Func] = Array(capacity=functions.length())
  for index in 0..<functions.length() {
    let @lib.Func(locals, body) = functions[index]
    let temp_index = function_param_count(wasm_module, index) +
      function_body_local_count(wasm_module, index)
    let new_locals = locals.copy()
    new_locals.push(@lib.ValType::i32())
    let new_body = charge_function_body(
      body,
      state.fuel_global,
      @lib.LocalIdx::new(temp_index.reinterpret_as_uint()),
      state.trap_global,
    )
    rewritten.push(@lib.Func::new(new_locals, new_body))
  }
  let output = match wasm_module.code_sec {
    Some(_) => state.wasm_module.with_code_sec(@lib.CodeSec::new(rewritten))
    None => state.wasm_module
  }
  let function_count = defined_function_count(wasm_module)
  let notes = [
    "fuel: budget=\{config.budget()} functions=\{function_count} loops=\{loop_count}",
  ]
  Ok(PassResult::new("FuelPass", output, notes~))
}
