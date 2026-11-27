///|
priv struct LocalRange {
  first : Int32
  last : Int32
  first_scope : Int32
  initialized : Bool
  first_loop : Int32?
  last_loop : Int32?
}

///|
priv struct LocalScan {
  ranges : Array[LocalRange?]
  ends : Array[Int32]
  mut position : Int32
}

///|
fn LocalScan::body(
  self : Self,
  body : Array[@lib.Instruction],
  outer_loop : Int32?,
) -> Unit {
  let scope = self.ends.length()
  self.ends.push(0)
  for instruction in body {
    self.position += 1
    match instruction {
      @lib.LocalGet(@lib.LocalIdx(index))
      | @lib.LocalSet(@lib.LocalIdx(index))
      | @lib.LocalTee(@lib.LocalIdx(index)) => {
        let index = index.reinterpret_as_int()
        let row = match self.ranges[index] {
          Some(row) => { ..row, last: self.position, last_loop: outer_loop, }
          None =>
            {
              first: self.position,
              last: self.position,
              first_scope: scope,
              initialized: !(instruction is @lib.LocalGet(_)),
              first_loop: outer_loop,
              last_loop: outer_loop,
            }
        }
        self.ranges[index] = Some(row)
      }
      @lib.Block(_, @lib.Expr(child)) => self.body(child, outer_loop)
      @lib.Loop(_, @lib.Expr(child)) => {
        let marker = self.ends.length()
        self.ends.push(self.position)
        self.body(child, Some(outer_loop.unwrap_or(marker)))
      }
      @lib.If(_, yes, no) => {
        self.body(yes, outer_loop)
        if no is Some(other) {
          self.body(other, outer_loop)
        }
      }
      _ => ()
    }
  }
  self.ends[scope] = self.position
}

///|
fn LocalScan::interval(self : Self, index : Int32) -> (Int32, Int32)? {
  guard self.ranges[index] is Some(row) &&
    row.initialized &&
    row.last <= self.ends[row.first_scope] else {
    return None
  }
  Some(
    (
      row.first_loop
      .map(fn(loop_id) { self.ends[loop_id] })
      .unwrap_or(row.first),
      row.last_loop
      .map(fn(loop_id) { self.ends[loop_id + 1] })
      .unwrap_or(row.last),
    ),
  )
}

///|
fn local_index(index : Int32) -> @lib.LocalIdx {
  @lib.LocalIdx::new(index.reinterpret_as_uint())
}

///|
fn strip_raw_local_names(payload : Bytes) -> (Bytes, Bool) raise PreflightError {
  let reader = InputReader::{ bytes: payload, pos: 0, end: payload.length(), }
  let retained = []
  let mut removed = false
  while reader.pos < reader.end {
    let start = reader.pos
    let kind = reader.byte()
    let length = reader.uleb().reinterpret_as_int()
    ignore(reader.take(length))
    if kind == 2 {
      removed = true
    } else {
      for index in start..<reader.pos {
        retained.push(payload[index])
      }
    }
  }
  (Bytes::from_array(retained), removed)
}

///|
fn strip_local_names(wasm : @lib.Module) -> @lib.Module? {
  let name_section = @lib.Name::from_string("name")
  if wasm.custom_secs.any(fn(section) {
      match section {
        @lib.CustomSec(name, _) => name == name_section
      }
    }) {
    return None
  }
  let clean_name_sec = wasm.name_sec.map(fn(names) {
    @lib.NameSec::new(
      module_name=names.module_name,
      func_names=names.func_names,
      label_names=names.label_names,
      type_names=names.type_names,
      table_names=names.table_names,
      memory_names=names.memory_names,
      global_names=names.global_names,
      elem_names=names.elem_names,
      data_names=names.data_names,
      field_names=names.field_names,
      tag_names=names.tag_names,
    )
  })
  let output = match clean_name_sec {
    Some(names) => wasm.with_name_sec(names)
    None => wasm.without_name_sec()
  }
  match wasm.raw_name_sec_payload {
    Some(payload) => {
      let (retained, removed) = strip_raw_local_names(payload) catch {
        _ => return None
      }
      if removed {
        Some(output.with_raw_name_sec_payload(retained))
      } else if wasm.name_sec
        .map(fn(names) { names.local_names is Some(_) })
        .unwrap_or(false) {
        None
      } else {
        Some(wasm)
      }
    }
    None => Some(output)
  }
}

///|
test "local coalescing strips only local names and preserves other name subsections" {
  let payload = Bytes::from_array([0, 2, 1, 109, 2, 2, 0, 0])
  let input = @lib.Module::new()
    .with_name_sec(
      @lib.NameSec::new(
        module_name=Some(@lib.Name::from_string("m")),
        local_names=Some(@lib.IndirectNameMap::new([])),
      ),
    )
    .with_raw_name_sec_payload(payload)
  match strip_local_names(input) {
    Some(stripped) => {
      assert_eq(
        stripped.raw_name_sec_payload,
        Some(Bytes::from_array([0, 2, 1, 109])),
      )
      assert_true(stripped.name_sec is Some(names) && names.local_names is None)
      assert_true(
        stripped.name_sec is Some(names) && names.module_name is Some(_),
      )
    }
    None => assert_true(false)
  }
}

///|
test "local coalescing keeps raw module names when no local names exist" {
  let payload = Bytes::from_array([0, 2, 1, 109])
  let input = @lib.Module::new()
    .with_name_sec(
      @lib.NameSec::new(module_name=Some(@lib.Name::from_string("m"))),
    )
    .with_raw_name_sec_payload(payload)
  match strip_local_names(input) {
    Some(output) => {
      assert_eq(output.raw_name_sec_payload, Some(payload))
      assert_true(
        output.name_sec is Some(names) && names.module_name is Some(_),
      )
    }
    None => assert_true(false)
  }
}

///|
fn merge_function_locals(
  function : @lib.Func,
  parameters : Int32,
) -> @lib.Func raise StageRewriteError {
  let @lib.Func(locals, @lib.Expr(body)) = function
  let original = locals.iter().collect()
  if original.length() < 2 {
    return function
  }
  let scan : LocalScan = {
    ranges: Array::make(parameters + original.length(), None),
    ends: [],
    position: 0,
  }
  scan.body(body, None)
  let slots : Array[(@lib.ValType, Array[(Int32, Int32)]?)] = []
  let mapping = Array::makei(parameters, local_index)
  for index, ty in original {
    let interval = if ty is @lib.NumTypeValType(_) {
      scan.interval(parameters + index)
    } else {
      None
    }
    let mut slot = slots.length()
    if interval is Some((first, last)) {
      for candidate, (candidate_type, ranges) in slots {
        if ty == candidate_type &&
          ranges is Some(previous) &&
          previous.all(fn(range) { range.1 < first || last < range.0 }) {
          slot = candidate
          previous.push((first, last))
          break
        }
      }
    }
    if slot == slots.length() {
      slots.push((ty, interval.map(fn(range) { [range] })))
    }
    mapping.push(local_index(parameters + slot))
  }
  if slots.length() == original.length() {
    return function
  }
  let rewritten = rewrite_generated_stage(body, fn(instruction, out) {
    let new_instruction = match instruction {
      @lib.LocalGet(@lib.LocalIdx(index)) =>
        @lib.Instruction::local_get(mapping[index.reinterpret_as_int()])
      @lib.LocalSet(@lib.LocalIdx(index)) =>
        @lib.Instruction::local_set(mapping[index.reinterpret_as_int()])
      @lib.LocalTee(@lib.LocalIdx(index)) =>
        @lib.Instruction::local_tee(mapping[index.reinterpret_as_int()])
      _ => return false
    }
    out.push(new_instruction)
    true
  })
  @lib.Func::new(
    @lib.Locals::from_types(slots.map(fn(slot) { slot.0 })),
    @lib.Expr::new(rewritten),
  )
}

///|
fn merge_module_locals(
  wasm : @lib.Module,
) -> @lib.Module raise StageRewriteError {
  let wasm = match strip_local_names(wasm) {
    Some(output) => output
    None => return wasm
  }
  guard wasm.code_sec is Some(@lib.CodeSec(bodies)) else { return wasm }
  let env = @validate.Env::new().with_module(wasm)
  let imported = imported_functions(wasm)
  let rewritten = []
  for index, body in bodies {
    let @lib.FuncType(params, _) = env.funcs[imported + index]
    rewritten.push(merge_function_locals(body, params.length()))
  }
  wasm.with_code_sec(@lib.CodeSec::new(rewritten))
}

///|
test "local coalescing reuses dead same-typed locals" {
  let function = @lib.Func::new(
    @lib.Locals::from_types([@lib.ValType::i32(), @lib.ValType::i32()]),
    @lib.Expr::new([
      @lib.Instruction::i32_const(@lib.I32::new(1)),
      @lib.Instruction::local_set(local_index(0)),
      @lib.Instruction::local_get(local_index(0)),
      @lib.Instruction::drop(),
      @lib.Instruction::i32_const(@lib.I32::new(2)),
      @lib.Instruction::local_set(local_index(1)),
      @lib.Instruction::local_get(local_index(1)),
      @lib.Instruction::drop(),
    ]),
  )
  let @lib.Func(locals, @lib.Expr(body)) = merge_function_locals(function, 0)
  assert_eq(locals.iter().collect().length(), 1)
  assert_true(body[1] is @lib.LocalSet(@lib.LocalIdx(0U)))
  assert_true(body[5] is @lib.LocalSet(@lib.LocalIdx(0U)))
}

///|
test "local coalescing preserves overlapping live ranges" {
  let function = @lib.Func::new(
    @lib.Locals::from_types([@lib.ValType::i32(), @lib.ValType::i32()]),
    @lib.Expr::new([
      @lib.Instruction::i32_const(@lib.I32::new(1)),
      @lib.Instruction::local_set(local_index(0)),
      @lib.Instruction::i32_const(@lib.I32::new(2)),
      @lib.Instruction::local_set(local_index(1)),
      @lib.Instruction::local_get(local_index(0)),
      @lib.Instruction::local_get(local_index(1)),
      @lib.Instruction::i32_add(),
      @lib.Instruction::drop(),
    ]),
  )
  let @lib.Func(locals, _) = merge_function_locals(function, 0)
  assert_eq(locals.iter().collect().length(), 2)
}
