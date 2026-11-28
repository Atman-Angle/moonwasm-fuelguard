///|
extern "c" fn host_environment() -> Int32 = "fuelguard_run_environment"

///|
extern "c" fn install_cancel() -> Int32 = "fuelguard_run_install_cancel"

///|
extern "c" fn host_cancelled() -> Int32 = "fuelguard_run_cancelled"

///|
#borrow(bytes)
extern "c" fn report(bytes : Bytes) -> Unit = "fuelguard_run_report"

///|
extern "c" fn native_exit(status : Int32) -> Unit = "fuelguard_run_exit"

///|
fn print_usage() -> Unit {
  println("FuelGuard Linux wasmoon runner")
  println("  run <production-v1.wasm> [--invoke <export>] [--arg <scalar>]...")
  println("      [--timeout-ms <N>] [--wasi] [--allow-import <module.name>]...")
  println(
    "      [--wasi-stdin] [--wasi-stdout] [--wasi-stderr] [--wasi-arg <value>]...",
  )
  println("Default export: _start. Supported scalar types: i32, i64, f32, f64.")
  println(ARTIFACT_TRUST_REQUIREMENT)
  println(
    "The marker identifies the artifact format. The caller verifies provenance.",
  )
}

///|
fn check_environment() -> Unit raise RunError {
  match host_environment() {
    0 => ()
    1 => host_error("runner requires Linux x86_64")
    2 => host_error("unable to read RLIMIT_STACK")
    _ => host_error("Linux process stack soft limit must be at least 8192 KiB")
  }
}

///|
fn cli_linker(opts : CliOptions) -> @runtime.Linker raise RunError {
  let linker = @runtime.Linker::Linker() catch {
    error => raise RunError(@runner.HostError("initializing wasmoon: \{error}"))
  }
  if opts.wasi {
    let builder = @wasi.WasiContextBuilder::WasiContextBuilder()
      .args([opts.file] + opts.wasi_args)
      .stdout(fn(_) { () })
      .stderr(fn(_) { () })
    if opts.wasi_stdout {
      ignore(builder.inherit_stdout())
    }
    if opts.wasi_stderr {
      ignore(builder.inherit_stderr())
    }
    if opts.wasi_stdin {
      ignore(builder.inherit_stdin())
    }
    @wasi.register_wasi(linker, builder.build()) catch {
      error => {
        linker.close()
        raise RunError(@runner.HostError("registering WASI: \{error}"))
      }
    }
  }
  linker
}

///|
fn run_file(opts : CliOptions) -> Unit raise RunError {
  check_environment()
  if install_cancel() == 0 {
    host_error("failed to install cancellation handlers")
  }
  let bytes = @fs.read_file_to_bytes(opts.file) catch {
    _ => raise RunError(@runner.InputError("unable to read file: " + opts.file))
  }
  let module_ = wasmoon_module(bytes)
  @validator.validate_module(module_) catch {
    error =>
      raise RunError(@runner.InputError("Wasm validation failed: \{error}"))
  }
  let diagnostics = artifact_diagnostics(module_)
  check_cli_imports(module_, opts)
  let entry = invocation(
    module_,
    opts.run.invoke().unwrap_or("_start"),
    opts.args,
  )
  let session = open_session(module_, cli_linker(opts), diagnostics)
  defer session.close()
  let cancel = Some(fn() { host_cancelled() != 0 })
  if session.initialize(module_.start, opts.timeout_ms, cancel) is Exited {
    return
  }
  if session.invoke(entry, opts.timeout_ms, cancel) is Returned(values) {
    if values.length() != entry.results.length() {
      host_error("wasmoon returned an unexpected number of scalar results")
    }
    if values.length() > 0 {
      println(render_values(values, entry.results))
    }
  }
}

///|
fn main_impl(args : ArrayView[String]) -> Int32 {
  if args.length() == 0 {
    print_usage()
    return 2
  }
  match args[0] {
    "help" | "--help" | "-h" => {
      print_usage()
      0
    }
    "--version" => {
      println("FuelGuard run 0.2.2 (wasmoon 0.18.0)")
      0
    }
    _ =>
      try {
        run_file(parse_options(args))
        0
      } catch {
        RunError(error) => {
          report(@utf8.encode("run: " + error.describe()))
          error.exit_code()
        }
      }
  }
}

///|
fn main {
  let status = main_impl(@env.args()[1:])
  if status != 0 {
    native_exit(status)
  }
}
