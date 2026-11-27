///|
/// Coordinates refer to the original module. An absent ordinal denotes
/// the export or core-start entry of the original function.
pub(all) struct DiagnosticSite {
  function_index : Int32
  instruction_ordinal : Int32?
  opcode : String?
}

///|
/// Resolve a diagnostics-v1 site for the Fuel v2 production layout.
pub fn resolve_production_site(
  source : @lib.Module,
  site : Int32,
) -> Result[DiagnosticSite?, InstrumentError] {
  if validate_wasm(source, "diagnostic source") is Err(error) {
    return Err(error)
  }
  if check_input(source) is Err(error) {
    return Err(error)
  }
  let plan = plan_stack_sites(source)
  if site <= 0 || site > plan.count {
    return Ok(None)
  }
  let imported = imported_functions(source)
  for i, end in plan.ends {
    if plan.entries[i] == site {
      return Ok(
        Some({ function_index: i, instruction_ordinal: None, opcode: None, }),
      )
    }
    if plan.starts[i] < site &&
      site <= end &&
      source.code_sec is Some(@lib.CodeSec(functions)) {
      let @lib.Func(_, body) = functions[i - imported]
      let mut ordinal = 0
      let mut current_site = plan.starts[i]
      let mut location = None
      visit_instructions(body, fn(instruction) {
        let key = instruction_key(instruction)
        if fuel_v1_rule(key) is Some(rule) && rule.base > 0L {
          current_site += 1
          if current_site == site {
            location = Some({
              function_index: i,
              instruction_ordinal: Some(ordinal),
              opcode: Some(key),
            })
          }
        }
        ordinal += 1
      })
      return Ok(location)
    }
  }
  Ok(None)
}
