///|
const MAX_STACK_UNITS : Int64 = 100_000L

///|
const MAX_CALL_DEPTH : Int64 = 128L

///|
const FIBER_BYTES : Int64 = 16_777_216L

///|
const ARTIFACT_TRUST_REQUIREMENT : String = "Use only trusted artifacts from the built-in production-v1 pipeline."

///|
priv struct Diagnostics {
  code : Int32
  site : Int32
}

///|
fn wasmoon_module(bytes : Bytes) -> @types.Module raise RunError {
  if @instrument.verify_production_artifact(bytes) is Err(error) {
    input_error(error.message() + ". " + ARTIFACT_TRUST_REQUIREMENT)
  }
  @parser.parse_module(bytes) catch {
    error =>
      raise RunError(
        @runner.RunFailure::input_error("Wasm parse failed: \{error}"),
      )
  }
}

///|
fn budget_value(global : @types.Global) -> Int64? {
  if global.type_.value_type is I64 &&
    global.type_.mutable &&
    global.init[:] is [@types.I64Const(n)] {
    Some(n)
  } else {
    None
  }
}

///|
fn diagnostic_initializer(global : @types.Global) -> Bool {
  global.type_.value_type is I32 &&
  global.type_.mutable &&
  global.init[:] is [@types.I32Const(0)]
}

///|
fn valid_packed_stack_budget(value : Int64) -> Bool {
  let mut step = 4L
  while step <= 4_294_967_296L {
    let units = value % step
    let depth = value / step
    if units > 0L &&
      units <= MAX_STACK_UNITS &&
      units < step / 2L &&
      depth > 0L &&
      depth <= MAX_CALL_DEPTH {
      return true
    }
    step = step << 1
  }
  false
}

///|
fn artifact_diagnostics(module_ : @types.Module) -> Diagnostics raise RunError {
  let invalid = RunError(
    @runner.RunFailure::input_error(
      "invalid diagnostics-v1 or stack global layout",
    ),
  )
  let first = module_.globals.length() - 5
  guard first >= 0 &&
    budget_value(module_.globals[first]) is Some(fuel) &&
    diagnostic_initializer(module_.globals[first + 1]) &&
    diagnostic_initializer(module_.globals[first + 2]) else {
    raise invalid
  }
  if fuel <= 0L {
    input_error("Fuel budget must be positive")
  }
  match (budget_value(module_.globals[first + 3]), module_.globals[first + 4]) {
    (Some(units), stack_state) => {
      if stack_state.type_.value_type is I64 &&
        stack_state.type_.mutable &&
        stack_state.init[:] is [@types.I64Const(depth)] {
        if units <= 0L || depth <= 0L {
          input_error("Fuel, stack and depth budgets must be positive")
        }
        if units > MAX_STACK_UNITS || depth > MAX_CALL_DEPTH {
          input_error(
            "budget outside the Linux wasmoon profile: stack \{units}/\{MAX_STACK_UNITS}, depth \{depth}/\{MAX_CALL_DEPTH}",
          )
        }
      } else if stack_state.type_.value_type is I32 &&
        stack_state.type_.mutable &&
        stack_state.init[:] is [@types.I32Const(0)] {
        if !valid_packed_stack_budget(units) {
          input_error(
            "budget outside the Linux wasmoon profile: packed Stack v2 limits",
          )
        }
      } else {
        raise invalid
      }
    }
    _ => raise invalid
  }
  let imported = module_.imports
    .filter(fn(item) { item.desc is @types.ImportDesc::Global(_) })
    .length()
  let first = first + imported
  let mut code = false
  let mut site = false
  for item in module_.exports {
    match item.name {
      name if name == @instrument.trap_export_name =>
        if item.desc == @types.ExportDesc::Global(first + 1) {
          code = true
        } else {
          raise invalid
        }
      name if name == @instrument.trap_site_export_name =>
        if item.desc == @types.ExportDesc::Global(first + 2) {
          site = true
        } else {
          raise invalid
        }
      _ =>
        if item.desc is @types.ExportDesc::Global(index) && index >= first {
          raise invalid
        }
    }
  }
  if !code || !site {
    raise invalid
  }
  { code: first + 1, site: first + 2, }
}

///|
fn check_cli_imports(
  module_ : @types.Module,
  opts : CliOptions,
) -> Unit raise RunError {
  for item in module_.imports {
    let name = item.mod_name + "." + item.name
    if !opts.allow.contains(name) {
      input_error("import is not allowed: " + name)
    }
    if item.mod_name != "wasi_snapshot_preview1" ||
      !(item.desc is @types.ImportDesc::Func(_)) {
      input_error("unsupported runner import: " + name)
    }
    if !opts.wasi {
      input_error("WASI import requires --wasi: " + name)
    }
    match item.name {
      "fd_write"
      | "fd_read"
      | "fd_fdstat_get"
      | "proc_exit"
      | "args_get"
      | "args_sizes_get"
      | "environ_get"
      | "environ_sizes_get"
      | "clock_time_get"
      | "clock_res_get"
      | "random_get"
      | "sched_yield" => ()
      _ => input_error("unsupported WASI capability: " + name)
    }
  }
}

///|
priv struct Invocation {
  index : Int32
  args : Array[Int64]
  results : Array[@types.ValueType]
}

///|
fn scalar_argument(
  ty : @types.ValueType,
  text : String,
) -> Int64 raise RunError {
  let invalid = RunError(
    @runner.RunFailure::input_error("invalid \{ty} argument: \{text}"),
  )
  match ty {
    I32 => {
      let signed = @string.parse_int(text) catch {
        _ => {
          let unsigned = @string.parse_uint(text) catch { _ => raise invalid }
          unsigned.reinterpret_as_int()
        }
      }
      signed.to_int64()
    }
    I64 =>
      @string.parse_int64(text) catch {
        _ => {
          let unsigned = @string.parse_uint64(text) catch { _ => raise invalid }
          unsigned.reinterpret_as_int64()
        }
      }
    F32 | F64 => {
      let n = @string.parse_double(text) catch { _ => raise invalid }
      if ty is F32 {
        Float::from_double(n).reinterpret_as_int().to_int64()
      } else {
        n.reinterpret_as_int64()
      }
    }
    _ =>
      raise RunError(
        @runner.RunFailure::input_error(
          "unsupported export argument type: \{ty}",
        ),
      )
  }
}

///|
fn invocation(
  module_ : @types.Module,
  name : String,
  args : Array[String],
) -> Invocation raise RunError {
  for item in module_.exports {
    if item.name == name && item.desc is @types.ExportDesc::Func(index) {
      let (params, results) = @binding.build_func_signatures(module_)[index]
      if params.length() != args.length() {
        input_error(
          "export '\{name}' expects \{params.length()} arguments, got \{args.length()}",
        )
      }
      for ty in results {
        if !(ty is (I32 | I64 | F32 | F64)) {
          input_error("unsupported export result type: \{ty}")
        }
      }
      let values = []
      for i, ty in params {
        values.push(scalar_argument(ty, args[i]))
      }
      return { index, args: values, results, }
    }
  }
  raise RunError(
    @runner.RunFailure::input_error("function export not found: " + name),
  )
}

///|
fn render_values(
  values : Array[Int64],
  types : Array[@types.ValueType],
) -> String {
  types
  .mapi(fn(i, ty) {
    let value = values[i]
    match ty {
      I32 => value.to_int().to_string()
      I64 => value.to_string()
      F32 => Float::reinterpret_from_int(value.to_int()).to_string()
      F64 => value.reinterpret_as_double().to_string()
      _ => abort("export result types were validated")
    }
  })
  .join(" ")
}
