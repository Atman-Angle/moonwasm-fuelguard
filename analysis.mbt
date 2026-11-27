/// Deterministic read-only facts and plans for FuelGuard.

///|
pub(all) struct ModuleIndex {
  type_count : Int32
  imported_function_count : Int32
  defined_function_count : Int32
  function_type_indices : Array[Int32]
  imported_global_count : Int32
  defined_global_count : Int32
  table_count : Int32
  memory_count : Int32
  export_function_indices : Array[Int32]
  start_function_index : Int32?
  element_function_indices : Array[Int32]
}

///|
pub fn ModuleIndex::function_count(self : Self) -> Int32 {
  self.imported_function_count + self.defined_function_count
}

///|
pub(all) struct InstructionFact {
  ordinal : Int32
  depth : Int32
  key : String
  static_cost : Int64
  dynamic : Bool
  boundary : String
}

///|
pub(all) struct FunctionFacts {
  function_index : Int32
  type_index : Int32
  parameter_count : Int32
  local_count : Int32
  instruction_count : Int32
  loop_count : Int32
  max_control_depth : Int32
  static_cost : Int64
  instructions : Array[InstructionFact]
}

///|
pub fn FunctionFacts::instructions(self : Self) -> Array[InstructionFact] {
  self.instructions.copy()
}

///|
pub(all) struct MeterSite {
  id : Int32
  function_index : Int32
  first_ordinal : Int32
  last_ordinal : Int32
  static_cost : Int64
  dynamic_rule : String?
}

///|
pub(all) struct FunctionPlan {
  function_index : Int32
  signature_type_index : Int32
  template_id : String
  appended_local_count : Int32
  output_capacity : Int32
  site_ids : Array[Int32]
}

///|
pub(all) struct SemanticPlan {
  version : String
  module_index : ModuleIndex
  functions : Array[FunctionFacts]
  sites : Array[MeterSite]
}

///|
pub fn SemanticPlan::sites(self : Self) -> Array[MeterSite] {
  self.sites.copy()
}

///|
pub(all) struct InstrumentPlan {
  semantic : SemanticPlan
  functions : Array[FunctionPlan]
  added_function_count : Int32
  added_global_count : Int32
  first_added_function_index : Int32
  first_added_global_index : Int32
}

///|
fn boundary_name(boundary : FuelV1Boundary) -> String {
  match boundary {
    FuelV1Boundary::Prefix => "Prefix"
    FuelV1Boundary::Barrier => "Barrier"
    FuelV1Boundary::Structure => "Structure"
    FuelV1Boundary::Marker => "Marker"
  }
}

///|
fn type_count(wasm : @lib.Module) -> Int32 {
  match wasm.type_sec {
    Some(@lib.TypeSec(groups)) => {
      let mut count = 0
      for group in groups {
        count += match group {
          @lib.SingleRecType(_) => 1
          @lib.GroupRecType(values) => values.length()
        }
      }
      count
    }
    None => 0
  }
}

///|
fn imported_functions(wasm : @lib.Module) -> Int32 {
  match wasm.import_sec {
    Some(@lib.ImportSec(values)) => {
      let mut count = 0
      for item in values {
        if item is @lib.Import(_, _, @lib.FuncExternType(_)) {
          count += 1
        }
      }
      count
    }
    None => 0
  }
}

///|
fn imported_tables(wasm : @lib.Module) -> Int32 {
  match wasm.import_sec {
    Some(@lib.ImportSec(values)) =>
      values
      .filter(fn(item) { item is @lib.Import(_, _, @lib.TableExternType(_)) })
      .length()
    None => 0
  }
}

///|
fn imported_memories(wasm : @lib.Module) -> Int32 {
  match wasm.import_sec {
    Some(@lib.ImportSec(values)) =>
      values
      .filter(fn(item) { item is @lib.Import(_, _, @lib.MemExternType(_)) })
      .length()
    None => 0
  }
}

///|
fn defined_function_type_index(wasm : @lib.Module, defined : Int32) -> Int32 {
  match wasm.func_sec {
    Some(@lib.FuncSec(values)) if defined >= 0 && defined < values.length() =>
      match values[defined] {
        @lib.TypeIdx(value) => value.reinterpret_as_int()
        @lib.RecIdx(value) => value.reinterpret_as_int()
      }
    _ => -1
  }
}

///|
fn type_parameter_counts(wasm : @lib.Module) -> Array[Int32] {
  let counts : Array[Int32] = []
  match wasm.type_sec {
    Some(@lib.TypeSec(groups)) =>
      for group in groups {
        let values = match group {
          @lib.SingleRecType(value) => [value]
          @lib.GroupRecType(values) => values
        }
        for value in values {
          counts.push(
            match value {
              @lib.SubType(_, _, _, @lib.FuncCompType(params, _)) =>
                params.length()
              @lib.CompTypeSubType(_, @lib.FuncCompType(params, _)) =>
                params.length()
              _ => 0
            },
          )
        }
      }
    None => ()
  }
  counts
}

///|
fn instruction_key(instruction : @lib.Instruction) -> String {
  match instruction {
    @lib.Nop => "nop"
    @lib.Drop => "drop"
    @lib.Select(_) => "select"
    @lib.LocalGet(_) => "local.get"
    @lib.LocalSet(_) => "local.set"
    @lib.LocalTee(_) => "local.tee"
    @lib.GlobalGet(_) => "global.get"
    @lib.GlobalSet(_) => "global.set"
    @lib.I32Const(_) => "i32.const"
    @lib.I64Const(_) => "i64.const"
    @lib.I32Add => "i32.add"
    @lib.I32Sub => "i32.sub"
    @lib.I64Add => "i64.add"
    @lib.I64Sub => "i64.sub"
    @lib.I32Load(_) => "i32.load"
    @lib.I64Load(_) => "i64.load"
    @lib.F32Load(_) => "f32.load"
    @lib.F64Load(_) => "f64.load"
    @lib.I32Store(_) => "i32.store"
    @lib.I64Store(_) => "i64.store"
    @lib.F32Store(_) => "f32.store"
    @lib.F64Store(_) => "f64.store"
    @lib.V128Load(_) => "v128.load"
    @lib.V128Store(_) => "v128.store"
    @lib.MemorySize(_) => "memory.size"
    @lib.MemoryGrow(_) => "memory.grow"
    @lib.MemoryInit(_, _) => "memory.init"
    @lib.MemoryCopy(_, _) => "memory.copy"
    @lib.MemoryFill(_) => "memory.fill"
    @lib.TableSize(_) => "table.size"
    @lib.TableGet(_) => "table.get"
    @lib.TableSet(_) => "table.set"
    @lib.TableGrow(_) => "table.grow"
    @lib.TableInit(_, _) => "table.init"
    @lib.TableCopy(_, _) => "table.copy"
    @lib.TableFill(_) => "table.fill"
    @lib.Br(_) => "br"
    @lib.BrIf(_) => "br_if"
    @lib.BrTable(_, _) => "br_table"
    @lib.Return => "return"
    @lib.Unreachable => "unreachable"
    @lib.Call(_) => "call"
    @lib.CallIndirect(_, _) => "call_indirect"
    @lib.Block(_, _) => "block"
    @lib.Loop(_, _) => "loop"
    @lib.If(_, _, _) => "if"
    @lib.RefNull(_) => "ref.null"
    @lib.RefIsNull => "ref.is_null"
    @lib.DataDrop(_) => "data.drop"
    @lib.ElemDrop(_) => "elem.drop"
    @lib.F32Abs => "f32.abs"
    @lib.F32Add => "f32.add"
    @lib.F32Ceil => "f32.ceil"
    @lib.F32Const(_) => "f32.const"
    @lib.F32ConvertI32S => "f32.convert_i32_s"
    @lib.F32ConvertI32U => "f32.convert_i32_u"
    @lib.F32ConvertI64S => "f32.convert_i64_s"
    @lib.F32ConvertI64U => "f32.convert_i64_u"
    @lib.F32Copysign => "f32.copysign"
    @lib.F32DemoteF64 => "f32.demote_f64"
    @lib.F32Div => "f32.div"
    @lib.F32Eq => "f32.eq"
    @lib.F32Floor => "f32.floor"
    @lib.F32Ge => "f32.ge"
    @lib.F32Gt => "f32.gt"
    @lib.F32Le => "f32.le"
    @lib.F32Lt => "f32.lt"
    @lib.F32Max => "f32.max"
    @lib.F32Min => "f32.min"
    @lib.F32Mul => "f32.mul"
    @lib.F32Ne => "f32.ne"
    @lib.F32Nearest => "f32.nearest"
    @lib.F32Neg => "f32.neg"
    @lib.F32ReinterpretI32 => "f32.reinterpret_i32"
    @lib.F32Sqrt => "f32.sqrt"
    @lib.F32Sub => "f32.sub"
    @lib.F32Trunc => "f32.trunc"
    @lib.F64Abs => "f64.abs"
    @lib.F64Add => "f64.add"
    @lib.F64Ceil => "f64.ceil"
    @lib.F64Const(_) => "f64.const"
    @lib.F64ConvertI32S => "f64.convert_i32_s"
    @lib.F64ConvertI32U => "f64.convert_i32_u"
    @lib.F64ConvertI64S => "f64.convert_i64_s"
    @lib.F64ConvertI64U => "f64.convert_i64_u"
    @lib.F64Copysign => "f64.copysign"
    @lib.F64Div => "f64.div"
    @lib.F64Eq => "f64.eq"
    @lib.F64Floor => "f64.floor"
    @lib.F64Ge => "f64.ge"
    @lib.F64Gt => "f64.gt"
    @lib.F64Le => "f64.le"
    @lib.F64Lt => "f64.lt"
    @lib.F64Max => "f64.max"
    @lib.F64Min => "f64.min"
    @lib.F64Mul => "f64.mul"
    @lib.F64Ne => "f64.ne"
    @lib.F64Nearest => "f64.nearest"
    @lib.F64Neg => "f64.neg"
    @lib.F64PromoteF32 => "f64.promote_f32"
    @lib.F64ReinterpretI64 => "f64.reinterpret_i64"
    @lib.F64Sqrt => "f64.sqrt"
    @lib.F64Sub => "f64.sub"
    @lib.F64Trunc => "f64.trunc"
    @lib.I16x8Bitmask => "i16x8.bitmask"
    @lib.I16x8Eq => "i16x8.eq"
    @lib.I16x8LeU => "i16x8.le_u"
    @lib.I16x8LtU => "i16x8.lt_u"
    @lib.I16x8Splat => "i16x8.splat"
    @lib.I16x8Sub => "i16x8.sub"
    @lib.I32And => "i32.and"
    @lib.I32Clz => "i32.clz"
    @lib.I32Ctz => "i32.ctz"
    @lib.I32DivS => "i32.div_s"
    @lib.I32DivU => "i32.div_u"
    @lib.I32Eq => "i32.eq"
    @lib.I32Eqz => "i32.eqz"
    @lib.I32Extend16S => "i32.extend16_s"
    @lib.I32Extend8S => "i32.extend8_s"
    @lib.I32GeS => "i32.ge_s"
    @lib.I32GeU => "i32.ge_u"
    @lib.I32GtS => "i32.gt_s"
    @lib.I32GtU => "i32.gt_u"
    @lib.I32LeS => "i32.le_s"
    @lib.I32LeU => "i32.le_u"
    @lib.I32Load16S(_) => "i32.load16_s"
    @lib.I32Load16U(_) => "i32.load16_u"
    @lib.I32Load8S(_) => "i32.load8_s"
    @lib.I32Load8U(_) => "i32.load8_u"
    @lib.I32LtS => "i32.lt_s"
    @lib.I32LtU => "i32.lt_u"
    @lib.I32Mul => "i32.mul"
    @lib.I32Ne => "i32.ne"
    @lib.I32Or => "i32.or"
    @lib.I32Popcnt => "i32.popcnt"
    @lib.I32ReinterpretF32 => "i32.reinterpret_f32"
    @lib.I32RemS => "i32.rem_s"
    @lib.I32RemU => "i32.rem_u"
    @lib.I32Rotl => "i32.rotl"
    @lib.I32Rotr => "i32.rotr"
    @lib.I32Shl => "i32.shl"
    @lib.I32ShrS => "i32.shr_s"
    @lib.I32ShrU => "i32.shr_u"
    @lib.I32Store16(_) => "i32.store16"
    @lib.I32Store8(_) => "i32.store8"
    @lib.I32TruncF32S => "i32.trunc_f32_s"
    @lib.I32TruncF32U => "i32.trunc_f32_u"
    @lib.I32TruncF64S => "i32.trunc_f64_s"
    @lib.I32TruncF64U => "i32.trunc_f64_u"
    @lib.I32TruncSatF32S => "i32.trunc_sat_f32_s"
    @lib.I32TruncSatF32U => "i32.trunc_sat_f32_u"
    @lib.I32TruncSatF64S => "i32.trunc_sat_f64_s"
    @lib.I32TruncSatF64U => "i32.trunc_sat_f64_u"
    @lib.I32WrapI64 => "i32.wrap_i64"
    @lib.I32Xor => "i32.xor"
    @lib.I32x4ExtractLane(_) => "i32x4.extract_lane"
    @lib.I64And => "i64.and"
    @lib.I64Clz => "i64.clz"
    @lib.I64Ctz => "i64.ctz"
    @lib.I64DivS => "i64.div_s"
    @lib.I64DivU => "i64.div_u"
    @lib.I64Eq => "i64.eq"
    @lib.I64Eqz => "i64.eqz"
    @lib.I64Extend16S => "i64.extend16_s"
    @lib.I64Extend32S => "i64.extend32_s"
    @lib.I64Extend8S => "i64.extend8_s"
    @lib.I64ExtendI32S => "i64.extend_i32_s"
    @lib.I64ExtendI32U => "i64.extend_i32_u"
    @lib.I64GeS => "i64.ge_s"
    @lib.I64GeU => "i64.ge_u"
    @lib.I64GtS => "i64.gt_s"
    @lib.I64GtU => "i64.gt_u"
    @lib.I64LeS => "i64.le_s"
    @lib.I64LeU => "i64.le_u"
    @lib.I64Load16S(_) => "i64.load16_s"
    @lib.I64Load16U(_) => "i64.load16_u"
    @lib.I64Load32S(_) => "i64.load32_s"
    @lib.I64Load32U(_) => "i64.load32_u"
    @lib.I64Load8S(_) => "i64.load8_s"
    @lib.I64Load8U(_) => "i64.load8_u"
    @lib.I64LtS => "i64.lt_s"
    @lib.I64LtU => "i64.lt_u"
    @lib.I64Mul => "i64.mul"
    @lib.I64Ne => "i64.ne"
    @lib.I64Or => "i64.or"
    @lib.I64Popcnt => "i64.popcnt"
    @lib.I64ReinterpretF64 => "i64.reinterpret_f64"
    @lib.I64RemS => "i64.rem_s"
    @lib.I64RemU => "i64.rem_u"
    @lib.I64Rotl => "i64.rotl"
    @lib.I64Rotr => "i64.rotr"
    @lib.I64Shl => "i64.shl"
    @lib.I64ShrS => "i64.shr_s"
    @lib.I64ShrU => "i64.shr_u"
    @lib.I64Store16(_) => "i64.store16"
    @lib.I64Store32(_) => "i64.store32"
    @lib.I64Store8(_) => "i64.store8"
    @lib.I64TruncF32S => "i64.trunc_f32_s"
    @lib.I64TruncF32U => "i64.trunc_f32_u"
    @lib.I64TruncF64S => "i64.trunc_f64_s"
    @lib.I64TruncF64U => "i64.trunc_f64_u"
    @lib.I64TruncSatF32S => "i64.trunc_sat_f32_s"
    @lib.I64TruncSatF32U => "i64.trunc_sat_f32_u"
    @lib.I64TruncSatF64S => "i64.trunc_sat_f64_s"
    @lib.I64TruncSatF64U => "i64.trunc_sat_f64_u"
    @lib.I64Xor => "i64.xor"
    @lib.I64x2ExtractLane(_) => "i64x2.extract_lane"
    @lib.I8x16AllTrue => "i8x16.all_true"
    @lib.I8x16Eq => "i8x16.eq"
    @lib.I8x16Shuffle(_, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _) =>
      "i8x16.shuffle"
    @lib.V128And => "v128.and"
    @lib.V128AnyTrue => "v128.any_true"
    @lib.V128Or => "v128.or"
    _ => "unknown"
  }
}

///|
/// Explicit work stack: host recursion is not used for arbitrary nesting.
priv enum Work {
  Expr(@lib.Expr, Int32)
  Instructions(Array[@lib.Instruction], Int32)
  Instruction(@lib.Instruction, Int32)
}

///|
fn visit_instructions(
  root : @lib.Expr,
  visit : (@lib.Instruction) -> Unit,
) -> Unit {
  let pending : Array[Work] = [Work::Expr(root, 0)]
  while pending.length() > 0 {
    match pending.pop().unwrap() {
      Work::Expr(expr, depth) => {
        let @lib.Expr(values) = expr
        pending.push(Work::Instructions(values, depth))
      }
      Work::Instructions(values, depth) => {
        let mut i = values.length() - 1
        while i >= 0 {
          pending.push(Work::Instruction(values[i], depth))
          i -= 1
        }
      }
      Work::Instruction(instruction, depth) => {
        visit(instruction)
        match instruction {
          @lib.Block(_, body) | @lib.Loop(_, body) =>
            pending.push(Work::Expr(body, depth + 1))
          @lib.If(_, then_body, else_body) => {
            match else_body {
              Some(body) => pending.push(Work::Instructions(body, depth + 1))
              None => ()
            }
            pending.push(Work::Instructions(then_body, depth + 1))
          }
          @lib.Try(_, body, catches, _) => {
            let mut i = catches.length() - 1
            while i >= 0 {
              match catches[i] {
                @lib.LegacyCatch(_, body) | @lib.LegacyCatchAll(body) =>
                  pending.push(Work::Expr(body, depth + 1))
              }
              i -= 1
            }
            pending.push(Work::Expr(body, depth + 1))
          }
          @lib.TryTable(_, _, body) => pending.push(Work::Expr(body, depth + 1))
          _ => ()
        }
      }
    }
  }
}

///|
fn collect(
  root : @lib.Expr,
  function_index : Int32,
  ordinal : Ref[Int32],
  facts : Array[InstructionFact],
  sites : Array[MeterSite]?,
  site_id : Ref[Int32],
  total : Ref[Int64],
  loops : Ref[Int32],
  max_depth : Ref[Int32],
  retain_facts : Bool,
) -> Unit {
  let pending : Array[Work] = [Work::Expr(root, 0)]
  while pending.length() > 0 {
    match pending.pop().unwrap() {
      Work::Expr(expr, depth) => {
        let @lib.Expr(values) = expr
        pending.push(Work::Instructions(values, depth))
      }
      Work::Instructions(values, depth) => {
        let mut i = values.length() - 1
        while i >= 0 {
          pending.push(Work::Instruction(values[i], depth))
          i -= 1
        }
      }
      Work::Instruction(instruction, depth) => {
        if depth > max_depth.val {
          max_depth.val = depth
        }
        let number = ordinal.val
        ordinal.val += 1
        let key = instruction_key(instruction)
        let rule = fuel_v1_rule(key)
        let cost = match rule {
          Some(value) => value.base
          None => 0L
        }
        let dynamic = match rule {
          Some(value) => value.per_unit > 0L
          None => false
        }
        let boundary = match rule {
          Some(value) => boundary_name(value.boundary)
          None => "Unknown"
        }
        if retain_facts {
          facts.push({
            ordinal: number,
            depth,
            key,
            static_cost: cost,
            dynamic,
            boundary,
          })
        }
        if cost > 0L {
          if sites is Some(output) {
            site_id.val += 1
            output.push({
              id: site_id.val,
              function_index,
              first_ordinal: number,
              last_ordinal: number,
              static_cost: cost,
              dynamic_rule: if dynamic {
                Some(key)
              } else {
                None
              },
            })
          }
          total.val += cost
        }
        match instruction {
          @lib.Block(_, body) => pending.push(Work::Expr(body, depth + 1))
          @lib.Loop(_, body) => {
            loops.val += 1
            pending.push(Work::Expr(body, depth + 1))
          }
          @lib.If(_, then_body, else_body) => {
            match else_body {
              Some(body) => pending.push(Work::Instructions(body, depth + 1))
              None => ()
            }
            pending.push(Work::Instructions(then_body, depth + 1))
          }
          @lib.Try(_, body, catches, _) => {
            let mut i = catches.length() - 1
            while i >= 0 {
              match catches[i] {
                @lib.LegacyCatch(_, body) | @lib.LegacyCatchAll(body) =>
                  pending.push(Work::Expr(body, depth + 1))
              }
              i -= 1
            }
            pending.push(Work::Expr(body, depth + 1))
          }
          @lib.TryTable(_, _, body) => pending.push(Work::Expr(body, depth + 1))
          _ => ()
        }
      }
    }
  }
}

///|
pub fn analyze_semantic(
  wasm : @lib.Module,
  stage~ : (String) -> Unit = fn(_) { () },
) -> SemanticPlan {
  analyze_semantic_impl(wasm, true, true, stage)
}

///|
fn analyze_semantic_impl(
  wasm : @lib.Module,
  materialize_sites : Bool,
  retain_facts : Bool,
  stage : (String) -> Unit,
  production_sites~ : StackSites? = None,
) -> SemanticPlan {
  stage("module_index")
  let imported = imported_functions(wasm)
  let defined = match wasm.func_sec {
    Some(@lib.FuncSec(values)) => values.length()
    None => 0
  }
  let function_types : Array[Int32] = []
  match wasm.import_sec {
    Some(@lib.ImportSec(values)) =>
      for item in values {
        let @lib.Import(_, _, kind) = item
        if kind is @lib.FuncExternType(index) {
          function_types.push(
            match index {
              @lib.TypeIdx(value) => value.reinterpret_as_int()
              @lib.RecIdx(value) => value.reinterpret_as_int()
            },
          )
        }
      }
    None => ()
  }
  for i in 0..<defined {
    function_types.push(defined_function_type_index(wasm, i))
  }
  let params = type_parameter_counts(wasm)
  let exports : Array[Int32] = []
  match wasm.export_sec {
    Some(@lib.ExportSec(values)) =>
      for @lib.Export(_, target) in values {
        if target is @lib.FuncExternIdx(@lib.FuncIdx(index)) {
          exports.push(index.reinterpret_as_int())
        }
      }
    None => ()
  }
  let start = match wasm.start_sec {
    Some(@lib.StartSec(@lib.FuncIdx(index))) => Some(index.reinterpret_as_int())
    None => None
  }
  let element_functions : Array[Int32] = []
  match wasm.elem_sec {
    Some(@lib.ElemSec(elements)) =>
      for element in elements {
        let @lib.Elem(_, kind) = element
        match kind {
          @lib.FuncsElemKind(values) =>
            for @lib.FuncIdx(index) in values {
              element_functions.push(index.reinterpret_as_int())
            }
          _ => ()
        }
      }
    None => ()
  }
  let index = {
    type_count: type_count(wasm),
    imported_function_count: imported,
    defined_function_count: defined,
    function_type_indices: function_types,
    imported_global_count: match wasm.import_sec {
      Some(@lib.ImportSec(values)) =>
        values
        .filter(fn(item) { item is @lib.Import(_, _, @lib.GlobalExternType(_)) })
        .length()
      None => 0
    },
    defined_global_count: match wasm.global_sec {
      Some(@lib.GlobalSec(values)) => values.length()
      None => 0
    },
    table_count: match wasm.table_sec {
      Some(@lib.TableSec(values)) => imported_tables(wasm) + values.length()
      None => imported_tables(wasm)
    },
    memory_count: match wasm.mem_sec {
      Some(@lib.MemSec(values)) => imported_memories(wasm) + values.length()
      None => imported_memories(wasm)
    },
    export_function_indices: exports,
    start_function_index: start,
    element_function_indices: element_functions,
  }
  stage("meter_site_analysis")
  let facts : Array[FunctionFacts] = []
  let sites : Array[MeterSite] = []
  let site_output = if materialize_sites { Some(sites) } else { None }
  let next_site = Ref(0)
  if production_sites is Some(plan) {
    for i in 0..<imported {
      append_entry_site(sites, i, plan.entries[i])
    }
  }
  match wasm.code_sec {
    Some(@lib.CodeSec(functions)) =>
      for i, function in functions {
        let @lib.Func(locals, body) = function
        let local_count = locals.length()
        let ordinal = Ref(0)
        let total = Ref(0L)
        let loops = Ref(0)
        let max_depth = Ref(0)
        let local_facts : Array[InstructionFact] = []
        let function_index = imported + i
        if production_sites is Some(plan) {
          append_entry_site(sites, function_index, plan.entries[function_index])
          next_site.val = plan.starts[function_index]
        }
        collect(
          body, function_index, ordinal, local_facts, site_output, next_site, total,
          loops, max_depth, retain_facts,
        )
        let type_index = function_types[function_index]
        let parameter_count = if type_index >= 0 && type_index < params.length() {
          params[type_index]
        } else {
          0
        }
        facts.push({
          function_index,
          type_index,
          parameter_count,
          local_count,
          instruction_count: ordinal.val,
          loop_count: loops.val,
          max_control_depth: max_depth.val,
          static_cost: total.val,
          instructions: local_facts,
        })
      }
    None => ()
  }
  let version = if production_sites is Some(_) {
    FuelV2.fuel_model()
  } else {
    fuel_v1_version
  }
  { version, module_index: index, functions: facts, sites, }
}

///|
fn append_entry_site(
  sites : Array[MeterSite],
  function_index : Int32,
  site : Int32,
) -> Unit {
  if site > 0 {
    sites.push({
      id: site,
      function_index,
      first_ordinal: -1,
      last_ordinal: -1,
      static_cost: 0L,
      dynamic_rule: None,
    })
  }
}

///|
fn production_semantic_plan(
  source : @lib.Module,
  sites : StackSites,
) -> Result[SemanticPlan, InstrumentError] {
  let semantic = analyze_semantic_impl(
    source,
    true,
    true,
    fn(_) { () },
    production_sites=Some(sites),
  )
  let targets = audit_table_targets(source) catch {
    StackError(reason) => return Err(StackAnalysisFailed(reason))
  }
  Ok({
    ..semantic,
    module_index: {
      ..semantic.module_index,
      element_function_indices: targets,
    },
  })
}

///|
pub fn plan_instrumentation(semantic : SemanticPlan) -> InstrumentPlan {
  let functions : Array[FunctionPlan] = []
  for facts in semantic.functions {
    functions.push({
      function_index: facts.function_index,
      signature_type_index: facts.type_index,
      template_id: "p0",
      appended_local_count: 1,
      output_capacity: facts.instruction_count + 8,
      site_ids: semantic.sites
      .filter(fn(site) { site.function_index == facts.function_index })
      .map(fn(site) { site.id }),
    })
  }
  {
    semantic,
    functions,
    added_function_count: 0,
    added_global_count: 0,
    first_added_function_index: semantic.module_index.function_count(),
    first_added_global_index: semantic.module_index.imported_global_count +
    semantic.module_index.defined_global_count,
  }
}
