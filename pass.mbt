///|
pub struct PassResult {
  pass_name : String
  output : @lib.Module
  notes : Array[String]
  stack_layout : Array[StackLayout]
  stages : Array[String]
  manifest_details : Json?
}

///|
pub fn PassResult::new(
  pass_name : String,
  output : @lib.Module,
  notes~ : Array[String] = [],
  stack_layout~ : Array[StackLayout] = [],
  stages~ : Array[String] = [],
  manifest_details~ : Json? = None,
) -> Self {
  { pass_name, output, notes, stack_layout, stages, manifest_details, }
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

///|
pub fn PassResult::stack_layout(self : Self) -> Array[StackLayout] {
  self.stack_layout.copy()
}

///|
pub fn PassResult::stages(self : Self) -> Array[String] {
  self.stages.copy()
}

///|
pub fn PassResult::manifest_details(self : Self) -> Json? {
  self.manifest_details
}
