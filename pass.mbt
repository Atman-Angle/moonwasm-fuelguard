///|
pub struct PassResult {
  pass_name : String
  output : @lib.Module
  notes : Array[String]
}

///|
pub fn PassResult::new(
  pass_name : String,
  output : @lib.Module,
  notes~ : Array[String] = [],
) -> Self {
  { pass_name, output, notes, }
}

///|
pub fn PassResult::pass_name(self : Self) -> String {
  self.pass_name
}

///|
pub fn PassResult::output(self : Self) -> @lib.Module {
  self.output
}

///|
pub fn PassResult::notes(self : Self) -> Array[String] {
  self.notes
}

///|
pub(open) trait Pass {
  fn apply(Self, @lib.Module) -> Result[PassResult, InstrumentError]
}
