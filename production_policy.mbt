///|
fn refuse(reason : String) -> Unit raise PreflightError {
  raise Refused(UnsupportedFeature(reason))
}

///|
fn source_name(name : @lib.Name) -> String raise PreflightError {
  let @lib.Name(view) = name
  let text = view.to_owned()
  check_input_limit("name bytes", @utf8.encode(text).length().to_int64(), 1024)
  text
}

///|
fn check_value_type(ty : @lib.ValType) -> Unit raise PreflightError {
  match ty {
    @lib.NumTypeValType(_) => ()
    _ =>
      if ty != @lib.ValType::externref() {
        refuse("production-v1 value type")
      }
  }
}

///|
fn check_global_type(ty : @lib.GlobalType) -> Unit raise PreflightError {
  let @lib.GlobalType(value, _) = ty
  if value != @lib.ValType::i32() && value != @lib.ValType::i64() {
    refuse("production-v1 globals require i32 or i64")
  }
}

///|
fn check_production_limits(
  limits : @lib.Limits,
  label : String,
) -> Unit raise PreflightError {
  match limits {
    @lib.I32Limits(initial, max) => {
      check_input_limit(label + " initial size", initial.to_int64(), 65536)
      if max is Some(n) {
        check_input_limit(label + " declared maximum", n.to_int64(), 65536)
      }
    }
    _ => refuse("production-v1 requires 32-bit " + label)
  }
}

///|
fn check_const_expr(
  expr : @lib.Expr,
  reference : Bool,
  function_reference : Bool,
) -> Unit raise PreflightError {
  let @lib.Expr(code) = expr
  for instruction in code {
    match instruction {
      @lib.I32Const(_)
      | @lib.I64Const(_)
      | @lib.F32Const(_)
      | @lib.F64Const(_)
      | @lib.GlobalGet(_) if !reference => ()
      @lib.RefNull(ty) if reference &&
        !function_reference &&
        @lib.ValType::ref_type(ty) == @lib.ValType::externref() => ()
      @lib.RefNull(ty) if function_reference &&
        @lib.ValType::ref_type(ty) == @lib.ValType::funcref() => ()
      @lib.RefFunc(_) if function_reference => ()
      _ => refuse("production-v1 constant expression")
    }
  }
}

///|
fn check_production_body(
  root : @lib.Expr,
  fixed_table : Bool,
  extern_table : Bool,
) -> Int32 raise PreflightError {
  let @lib.Expr(instructions) = root
  let pending = [(instructions, 0)]
  let mut count = 0
  while pending.pop() is Some((body, depth)) {
    check_input_limit("structured nesting", depth.to_int64(), 256)
    for instruction in body {
      count += 1
      check_input_limit("function instructions", count.to_int64(), 65536)
      let key = instruction_key(instruction)
      if fuel_v1_rule(key) is None {
        refuse("opcode outside production-v1 pricing allowlist")
      }
      match instruction {
        @lib.Block(ty, @lib.Expr(child)) | @lib.Loop(ty, @lib.Expr(child)) => {
          if ty is @lib.ValTypeBlockType(value) {
            check_value_type(value)
          }
          pending.push((child, depth + 1))
        }
        @lib.If(ty, yes, no) => {
          if ty is @lib.ValTypeBlockType(value) {
            check_value_type(value)
          }
          if no is Some(other) {
            pending.push((other, depth + 1))
          }
          pending.push((yes, depth + 1))
        }
        @lib.CallIndirect(_, _) =>
          if !fixed_table {
            refuse("call_indirect requires an internal fixed funcref table")
          }
        @lib.TableGet(_)
        | @lib.TableSet(_)
        | @lib.TableGrow(_)
        | @lib.TableFill(_)
        | @lib.TableCopy(_, _)
        | @lib.TableInit(_, _)
        | @lib.ElemDrop(_) =>
          if !extern_table {
            refuse("table operation requires an internal externref table")
          }
        @lib.RefNull(heap) =>
          if @lib.ValType::ref_type(heap) != @lib.ValType::externref() {
            refuse("production-v1 ref.null supports externref only")
          }
        @lib.Select(Some(types)) =>
          for ty in types {
            if !(ty is @lib.NumTypeValType(_)) {
              refuse("production-v1 typed select requires a numeric type")
            }
          }
        _ => ()
      }
    }
  }
  count
}

///|
fn check_production_module(
  wasm : @lib.Module,
  guards : GuardConfig,
) -> Unit raise PreflightError {
  if wasm.tag_sec is Some(_) ||
    wasm.stringrefs_sec is Some(_) ||
    wasm.func_annotation_sec is Some(_) ||
    wasm.compiler_fact_custom_section is Some(_) {
    refuse("unsupported production-v1 module section")
  }
  for @lib.CustomSec(name, bytes) in wasm.custom_secs {
    let text = source_name(name)
    if text == instrument_marker {
      refuse("already instrumented or unknown FuelGuard marker")
    }
    if text == "compiler.facts" {
      refuse("structured compiler.facts custom section")
    }
    check_input_limit(
      "custom payload bytes",
      bytes.length().to_int64(),
      4194304,
    )
  }

  if wasm.type_sec is Some(@lib.TypeSec(types)) {
    check_input_limit("types", types.length().to_int64(), 1024)
    for item in types {
      match item {
        @lib.SingleRecType(
          @lib.CompTypeSubType(meta, @lib.FuncCompType(params, results)),
        ) => {
          if meta.shared ||
            meta.describes is Some(_) ||
            meta.descriptor is Some(_) {
            refuse("production-v1 function type metadata")
          }
          check_input_limit("parameters", params.length().to_int64(), 64)
          check_input_limit("results", results.length().to_int64(), 16)
          for value in params {
            check_value_type(value)
          }
          for value in results {
            check_value_type(value)
          }
        }
        _ => refuse("production-v1 requires plain function types")
      }
    }
  }
  if wasm.import_sec is Some(@lib.ImportSec(imports)) {
    check_input_limit("imports", imports.length().to_int64(), 256)
    for @lib.Import(module_name, field, ty) in imports {
      match ty {
        @lib.FuncExternType(_) => ()
        @lib.GlobalExternType(global) => check_global_type(global)
        @lib.TableExternType(_) =>
          refuse("imported table forbidden by production-v1")
        @lib.MemExternType(_) =>
          refuse("imported memory forbidden by production-v1")
        _ => refuse("production-v1 import kind")
      }
      let pair = (source_name(module_name), source_name(field))
      if !guards.imports.contains(pair) {
        raise Refused(ImportNotAllowed(pair.0, pair.1))
      }
    }
  }
  if wasm.func_sec is Some(@lib.FuncSec(functions)) {
    check_input_limit(
      "total functions",
      (functions.length() + imported_functions(wasm)).to_int64(),
      4096,
    )
  }
  if wasm.global_sec is Some(@lib.GlobalSec(globals)) {
    check_input_limit(
      "total globals",
      (globals.length() + imported_global_count(wasm)).to_int64(),
      16384,
    )
    for @lib.Global(ty, init) in globals {
      let @lib.GlobalType(value, _) = ty
      // The frozen MoonBit JSON5 workload uses defined f64 state.
      if value != @lib.ValType::f64() {
        check_global_type(ty)
      }
      check_const_expr(init, false, false)
    }
  }
  if wasm.export_sec is Some(@lib.ExportSec(exports)) {
    check_input_limit("source exports", exports.length().to_int64(), 1022)
    for @lib.Export(name, target) in exports {
      let name = source_name(name)
      if name.has_prefix("__moonwasm_") {
        raise Refused(ExportNameConflict(name))
      }
      if target is @lib.TableExternIdx(_) {
        refuse("exported table forbidden by production-v1")
      }
    }
  }
  if wasm.mem_sec is Some(@lib.MemSec(memories)) {
    check_input_limit("memories", memories.length().to_int64(), 1)
    for @lib.MemType(limits, shared) in memories {
      if shared {
        refuse("shared memory")
      }
      check_production_limits(limits, "memory")
    }
    if memories.length() > 0 && guards.max_memory_pages() is None {
      refuse("production-v1 requires --max-memory-pages for memory")
    }
  }
  let mut fixed_table = false
  let mut extern_table = false
  if wasm.table_sec is Some(@lib.TableSec(tables)) {
    check_input_limit("tables", tables.length().to_int64(), 1)
    for @lib.Table(ty, init) in tables {
      if init is Some(_) {
        refuse("production-v1 table initializer")
      }
      let @lib.TableType(ref_type, limits) = ty
      check_production_limits(limits, "table")
      if is_extern_table(ty) {
        extern_table = true
      } else if @lib.ValType::ref_type(ref_type) == @lib.ValType::funcref() {
        if limits is @lib.I32Limits(initial, Some(maximum)) &&
          initial == maximum {
          fixed_table = true
        } else {
          refuse("funcref table must have equal minimum and maximum")
        }
      } else {
        refuse("production-v1 table type")
      }
    }
    if tables.length() > 0 && guards.max_table_elements() is None {
      refuse("production-v1 requires --max-table-elements for table")
    }
  }
  if wasm.elem_sec is Some(@lib.ElemSec(elements)) {
    check_input_limit("element segments", elements.length().to_int64(), 256)
    for @lib.Elem(mode, kind) in elements {
      if mode is @lib.Active(_, offset) {
        check_const_expr(offset, false, false)
      }
      match kind {
        @lib.FuncsElemKind(entries) if fixed_table && mode is @lib.Active(_, _) =>
          check_input_limit(
            "element entries",
            entries.length().to_int64(),
            4096,
          )
        @lib.FuncExprsElemKind(entries) if fixed_table &&
          mode is @lib.Active(_, _) => {
          check_input_limit(
            "element entries",
            entries.length().to_int64(),
            4096,
          )
          for expr in entries {
            check_const_expr(expr, true, true)
          }
        }
        @lib.TypedExprsElemKind(ty, entries) => {
          let value = @lib.ValType::ref_type(ty)
          let refs = fixed_table &&
            mode is @lib.Active(_, _) &&
            value == @lib.ValType::funcref()
          if !refs && !(extern_table && value == @lib.ValType::externref()) {
            refuse("production-v1 element segment reference type or mode")
          }
          check_input_limit(
            "element entries",
            entries.length().to_int64(),
            4096,
          )
          for expr in entries {
            check_const_expr(expr, true, refs)
          }
        }
        _ =>
          refuse(
            "funcref element must be active and target a fixed internal table",
          )
      }
    }
  }
  if wasm.data_sec is Some(@lib.DataSec(segments)) {
    check_input_limit("data segments", segments.length().to_int64(), 256)
    for @lib.Data(mode, _) in segments {
      if mode is @lib.Active(_, offset) {
        check_const_expr(offset, false, false)
      }
    }
  }
  if wasm.code_sec is Some(@lib.CodeSec(functions)) {
    check_input_limit("code bodies", functions.length().to_int64(), 4096)
    let mut total = 0
    for @lib.Func(locals, body) in functions {
      let mut count = 0L
      for run in locals.runs() {
        count += run.count().to_int64()
        check_input_limit("locals", count, 4096)
        check_value_type(run.val_type())
      }
      total += check_production_body(body, fixed_table, extern_table)
      check_input_limit("module instructions", total.to_int64(), 1048576)
    }
  }
}

///|
pub fn check_production_input(
  wasm : @lib.Module,
  guards : GuardConfig,
) -> Result[Unit, InstrumentError] {
  try {
    check_production_module(wasm, guards)
    Ok(())
  } catch {
    Refused(error) => Err(error)
  }
}
