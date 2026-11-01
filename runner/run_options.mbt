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
pub enum RunFailure {
  Trap(@instrument.TrapCode)
  ModuleTrap
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
    Trap(_) | ModuleTrap => 1
    HostError(_) | InputError(_) => 2
  }
}

///|
pub fn RunFailure::describe(self : Self) -> String {
  match self {
    Trap(code) => code.message()
    ModuleTrap => "module trap"
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
