///|
pub let diagnostics_abi_version : String = "diagnostics-v1"

///|
pub let trap_export_name : String = "__moonwasm_trap_code"

///|
pub let trap_site_export_name : String = "__moonwasm_trap_site"

///|
pub enum TrapCode {
  NoTrap
  Fuel
  Memory
  Table
  Stack
  Depth
}

///|
pub fn TrapCode::from_code(code : Int32) -> Result[Self, InstrumentError] {
  match code {
    0 => Ok(NoTrap)
    1 => Ok(Fuel)
    2 => Ok(Memory)
    3 => Ok(Table)
    4 => Ok(Stack)
    5 => Ok(Depth)
    _ => Err(InvalidTrapCode(code))
  }
}

///|
pub fn TrapCode::to_code(self : Self) -> Int32 {
  match self {
    NoTrap => 0
    Fuel => 1
    Memory => 2
    Table => 3
    Stack => 4
    Depth => 5
  }
}

///|
pub fn TrapCode::message(self : Self) -> String {
  match self {
    NoTrap => "module trap"
    Fuel => "fuel exhausted"
    Memory => "memory growth limit exceeded"
    Table => "table growth limit exceeded"
    Stack => "stack unit budget exhausted"
    Depth => "logical call depth exceeded"
  }
}
