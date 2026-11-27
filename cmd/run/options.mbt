///|
priv struct CliOptions {
  file : String
  run : @runner.RunOptions
  args : Array[String]
  wasi : Bool
  wasi_stdout : Bool
  wasi_stderr : Bool
  wasi_stdin : Bool
  wasi_args : Array[String]
  allow : Array[String]
  timeout_ms : Int32?
}

///|
priv suberror RunError {
  RunError(@runner.RunFailure)
}

///|
fn input_error(reason : String) -> Unit raise RunError {
  raise RunError(@runner.RunFailure::input_error(reason))
}

///|
fn host_error(reason : String) -> Unit raise RunError {
  raise RunError(@runner.RunFailure::host_error(reason))
}

///|
fn parse_options(args : ArrayView[String]) -> CliOptions raise RunError {
  let file = args[0]
  if file.has_prefix("-") {
    input_error("expected a Wasm file path")
  }
  let mut invoke = None
  let mut timeout_ms = None
  let mut wasi = false
  let mut wasi_stdout = false
  let mut wasi_stderr = false
  let mut wasi_stdin = false
  let params = []
  let wasi_args = []
  let allow = []
  let mut i = 1
  while i < args.length() {
    let option = args[i]
    match option {
      "--wasi" => wasi = true
      "--wasi-stdout" => wasi_stdout = true
      "--wasi-stderr" => wasi_stderr = true
      "--wasi-stdin" => wasi_stdin = true
      "--invoke" | "--arg" | "--wasi-arg" | "--allow-import" | "--timeout-ms" => {
        guard i + 1 < args.length() else {
          raise RunError(
            @runner.RunFailure::input_error("missing value for " + option),
          )
        }
        i += 1
        let value = args[i]
        match option {
          "--invoke" => {
            if invoke is Some(_) || value.length() == 0 {
              input_error("--invoke takes one nonempty export name")
            }
            invoke = Some(value)
          }
          "--arg" => params.push(value)
          "--wasi-arg" => wasi_args.push(value)
          "--allow-import" => allow.push(value)
          _ => {
            let duration = @string.parse_int(value) catch {
              _ =>
                raise RunError(
                  @runner.RunFailure::input_error(
                    "--timeout-ms must be a positive 32-bit integer",
                  ),
                )
            }
            if timeout_ms is Some(_) || duration <= 0 {
              input_error("--timeout-ms takes one positive 32-bit integer")
            }
            timeout_ms = Some(duration)
          }
        }
      }
      _ => input_error("unknown option: " + option)
    }
    i += 1
  }
  if !wasi &&
    (wasi_stdout || wasi_stderr || wasi_stdin || wasi_args.length() > 0) {
    input_error("WASI stream or guest argument options require --wasi")
  }
  if @instrument.GuardConfig::new(allowed_imports=allow) is Err(error) {
    input_error(error.message())
  }
  {
    file,
    run: @runner.RunOptions::new(invoke~),
    args: params,
    wasi,
    wasi_stdout,
    wasi_stderr,
    wasi_stdin,
    wasi_args,
    allow,
    timeout_ms,
  }
}
