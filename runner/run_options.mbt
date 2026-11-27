///|
pub struct RunOptions {
  invoke : String?
}

///|
pub fn RunOptions::new(invoke~ : String? = None) -> Self {
  { invoke, }
}

///|
pub fn RunOptions::invoke(self : Self) -> String? {
  self.invoke
}

///|
pub(all) enum RunFailure {
  Trap(@instrument.TrapCode)
  ModuleTrap
  ResourceTrap(@instrument.TrapCode, Int32)
  NativeTrap(String)
  ExecutionError(String)
  DiagnosticError(String)
  InitializationFailure(String)
  TimedOut(String)
  Cancelled(String)
  WasiExit(Int32)
  HostError(String)
  InputError(String)
}

///|
pub fn RunFailure::host_error(reason : String) -> Self {
  HostError(reason)
}

///|
pub fn RunFailure::input_error(reason : String) -> Self {
  InputError(reason)
}

///|
pub fn RunFailure::exit_code(self : Self) -> Int32 {
  match self {
    HostError(_) | InputError(_) => 2
    _ => 1
  }
}

///|
pub fn RunFailure::describe(self : Self) -> String {
  match self {
    Trap(code) => code.message()
    ModuleTrap => "module trap"
    ResourceTrap(code, site) =>
      "resource-trap code=\{code.to_code()} site=\{site}: \{code.message()}"
    NativeTrap(reason) => "native-trap code=0: \{reason}"
    ExecutionError(reason) => "execution-error: \{reason}"
    DiagnosticError(reason) => "diagnostic-error: \{reason}"
    InitializationFailure(reason) =>
      "initialization-failure diagnostic-unavailable: \{reason}"
    TimedOut(phase) => "timeout phase=\{phase}"
    Cancelled(phase) => "cancelled phase=\{phase}"
    WasiExit(status) => "wasi-exit status=\{status}"
    HostError(reason) => "host error: \{reason}"
    InputError(reason) => "input error: \{reason}"
  }
}

///|
pub fn diagnose_trap_code(
  code : Int32,
) -> Result[RunFailure, @instrument.InstrumentError] {
  match @instrument.TrapCode::from_code(code) {
    Err(error) => Err(error)
    Ok(@instrument.TrapCode::NoTrap) => Ok(ModuleTrap)
    Ok(trap) => Ok(Trap(trap))
  }
}

///|
pub fn diagnose_instance_trap(
  code : Int32,
  site : Int32,
  reason : String,
) -> RunFailure {
  match @instrument.TrapCode::from_code(code) {
    Ok(@instrument.TrapCode::NoTrap) if site == 0 => NativeTrap(reason)
    Ok(trap) if code > 0 && site > 0 => ResourceTrap(trap, site)
    Ok(_) => DiagnosticError("inconsistent code=\{code} site=\{site}")
    Err(_) => DiagnosticError("unknown code=\{code} site=\{site}")
  }
}
