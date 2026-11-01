///|
pub let trap_export_name : String = "__moonwasm_trap_code"

///|
pub enum TrapCode {
  NoTrap
  Fuel
  Memory
  Table
}

///|
pub fn TrapCode::from_code(code : Int32) -> Result[Self, InstrumentError] {
  match code {
    0 => Ok(NoTrap)
    1 => Ok(Fuel)
    2 => Ok(Memory)
    3 => Ok(Table)
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
  }
}

///|
pub fn TrapCode::message(self : Self) -> String {
  match self {
    NoTrap => "module trap"
    Fuel => "fuel exhausted"
    Memory => "memory growth limit exceeded"
    Table => "table growth limit exceeded"
  }
}
