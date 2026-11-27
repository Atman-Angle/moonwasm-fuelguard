///|
pub let stack_model_version : String = "stack-v2"

///|
fn check_shared_cost(
  index : Int32,
  cost : Int64,
) -> Int64 raise StackAuditError {
  if cost <= 0L || cost > MAX_PACKED_STACK_COUNTER {
    raise StackError(
      "function \{index}: shared C=\{cost} must fit in 1..=\{MAX_PACKED_STACK_COUNTER} (31 bits)",
    )
  }
  cost
}

///|
pub(all) struct StackLayout {
  function_index : Int32
  source_frame : StackFrameCost?
  final_frame : StackFrameCost
  auxiliary_peak : Int64
  shared_cost : Int64
  actual_cost : Int64
  within_shared_cost : Bool
  entry_wrapper : Bool
}

///|
const STACK_HELPER_FRAME_CAP : Int64 = 32L

///|
/// Preserve the shared Growth + charge allowance, including for Fuel v2
/// where the site-only failure frame and Growth are separate paths.
fn shared_auxiliary_caps(source : Array[ScannedFrame]) -> (Int64, Int64) {
  let mut signature = 0L
  for fact in source {
    let slots = fact.cost.parameters + fact.cost.results
    if slots > signature {
      signature = slots
    }
  }
  let helper_pair = 2L * STACK_HELPER_FRAME_CAP
  let wrapper = 32L + 2L * signature
  (helper_pair, helper_pair + wrapper)
}

///|
fn shared_source_cost(frame : StackFrameCost, entry_bound : Int64) -> Int64 {
  frame.total() + 8L + 16L + entry_bound
}

///|
fn source_stack_costs(
  source : @lib.Module,
) -> Array[Int64] raise StackAuditError {
  let frames = scan_module_frames(source)
  let (_, entry_bound) = shared_auxiliary_caps(frames)
  let costs = Array(capacity=frames.length())
  for index, frame in frames {
    costs.push(
      check_shared_cost(index, shared_source_cost(frame.cost, entry_bound)),
    )
  }
  costs
}

///|
fn generated_entries(
  wasm : @lib.Module,
  first : Int32,
) -> Array[Int32] raise StackAuditError {
  let entries = audit_table_targets(wasm)
  if wasm.start_sec is Some(@lib.StartSec(@lib.FuncIdx(start))) {
    entries.push(start.reinterpret_as_int())
  }
  if wasm.export_sec is Some(@lib.ExportSec(exports)) {
    for @lib.Export(_, target) in exports {
      if target is @lib.FuncExternIdx(@lib.FuncIdx(index)) {
        entries.push(index.reinterpret_as_int())
      }
    }
  }
  entries.filter(fn(index) { index >= first })
}

///|
/// Evaluate the generated-only graph bottom up. Original calls are budget
/// boundaries; traversing them here would count recursive source frames twice.
fn account_layout(
  source : Array[ScannedFrame],
  output : Array[ScannedFrame],
  entry_indices : Array[Int32],
) -> Array[StackLayout] raise StackAuditError {
  let first = source.length()
  let n = output.length()
  if n < first {
    raise StackError("output module removed original functions")
  }
  let auxiliary = Array::make(n, 0L)
  let remaining = Array::make(n, 0)
  let parents : Array[Array[Int32]] = Array::makei(n, fn(_) { [] })
  for owner in first..<n {
    for target in output[owner].calls {
      if target >= first {
        remaining[owner] += 1
        parents[target].push(owner)
      }
    }
  }
  let ready = []
  for index in first..<n {
    if remaining[index] == 0 {
      ready.push(index)
    }
  }
  let mut visited = 0
  while ready.pop() is Some(index) {
    visited += 1
    let active = output[index].cost.total() + auxiliary[index]
    for owner in parents[index] {
      if active > auxiliary[owner] {
        auxiliary[owner] = active
      }
      remaining[owner] -= 1
      if remaining[owner] == 0 {
        ready.push(owner)
      }
    }
  }
  if visited != n - first {
    raise StackError("recursive generated helper graph")
  }
  for owner in 0..<first {
    for target in output[owner].calls {
      if target >= first {
        let active = output[target].cost.total() + auxiliary[target]
        if active > auxiliary[owner] {
          auxiliary[owner] = active
        }
      }
    }
  }
  let (helper_bound, entry_bound) = shared_auxiliary_caps(source)
  let layouts = Array(capacity=n)
  for index in 0..<n {
    if index < first && source[index].signature != output[index].signature {
      raise StackError("instrumentation changed original function signature")
    }
    let final_frame = output[index].cost
    let actual = final_frame.total() + auxiliary[index]
    let source_frame = if index < first {
      Some(source[index].cost)
    } else {
      None
    }
    let entry_wrapper = entry_indices.contains(index)
    let shared = check_shared_cost(
      index,
      match source_frame {
        Some(frame) => shared_source_cost(frame, entry_bound)
        None => if entry_wrapper { entry_bound } else { helper_bound }
      },
    )
    if actual > shared {
      raise StackError(
        "function \{index}: A=\{actual} exceeds shared C=\{shared}",
      )
    }
    layouts.push({
      function_index: index,
      source_frame,
      final_frame,
      auxiliary_peak: auxiliary[index],
      shared_cost: shared,
      actual_cost: actual,
      within_shared_cost: true,
      entry_wrapper,
    })
  }
  layouts
}

///|
pub fn finalize_stack_layout(
  source : @lib.Module,
  output : @lib.Module,
  stage~ : (String) -> Unit = fn(_) { () },
) -> Result[Array[StackLayout], InstrumentError] {
  stage("audit_validate_source")
  if validate_wasm(source, "stack input") is Err(error) {
    return Err(error)
  }
  stage("audit_validate_output")
  if validate_wasm(output, "stack input") is Err(error) {
    return Err(error)
  }
  stage("audit_stack_layout")
  if source.import_sec != output.import_sec {
    return Err(StackAnalysisFailed("instrumentation changed imports"))
  }
  if source.func_sec is Some(@lib.FuncSec(before)) {
    guard output.func_sec is Some(@lib.FuncSec(after)) &&
      after.length() >= before.length() else {
      return Err(
        StackAnalysisFailed(
          "instrumentation removed original function signatures",
        ),
      )
    }
    for i, ty in before {
      if ty != after[i] {
        return Err(
          StackAnalysisFailed(
            "instrumentation changed original function type index",
          ),
        )
      }
    }
  }
  try {
    let before = scan_module_frames(source)
    let after = scan_module_frames(output)
    let entries = generated_entries(output, before.length())
    Ok(account_layout(before, after, entries))
  } catch {
    StackError(reason) => Err(StackAnalysisFailed(reason))
  }
}
