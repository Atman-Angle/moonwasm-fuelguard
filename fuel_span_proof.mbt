///|
pub const FUEL_V2_SPAN_SECTION = "fuelguard.fuel-v2-spans-v1"

///|
fn fuel_span_proof_name() -> @lib.Name {
  @lib.Name::from_string(FUEL_V2_SPAN_SECTION)
}

///|
fn write_span(
  rows : Buffer,
  function_index : Int32,
  first : Int32,
  length : Int32,
  weight : Int64,
) -> Unit {
  rows.write_int_le(function_index)
  rows.write_int_le(first)
  rows.write_int_le(length)
  rows.write_int64_le(weight)
}

///|
fn fuel_span_proof(
  plan : Array[FuelFunctionPlan],
  imported : Int32,
) -> @lib.CustomSec {
  let rows = Buffer()
  let bounds = Buffer()
  for i, function in plan {
    bounds.write_int_le(
      if function.site_end > function.site_start {
        function.site_end
      } else {
        0
      },
    )
    for offset, span in function.join_spans {
      if span is Some(span) {
        write_span(
          rows,
          imported + i,
          function.site_start + offset + 1,
          span.count,
          span.total,
        )
      }
    }
  }
  let payload = Buffer()
  payload.write_bytesview(
    Bytes::from_iter(@crypto.sha256(rows.to_bytes()).iter())[:],
  )
  payload.write_bytesview(bounds.to_bytes()[:])
  @lib.CustomSec::new(fuel_span_proof_name(), payload.to_bytes())
}

///|
priv suberror FuelSpanGuardError {
  MalformedFuelSpanGuard
}

///|
fn scan_fuel_span_guards(
  body : Array[@lib.Instruction],
  helper : @lib.FuncIdx,
  fuel_global : @lib.GlobalIdx,
  cache : @lib.LocalIdx?,
  guards : Array[(Int32, Int64)],
) -> Unit raise FuelSpanGuardError {
  for i, instruction in body {
    match instruction {
      @lib.Block(_, @lib.Expr(child)) | @lib.Loop(_, @lib.Expr(child)) =>
        scan_fuel_span_guards(child, helper, fuel_global, cache, guards)
      @lib.If(ty, yes, None) if ty == @lib.BlockType::void_() &&
        yes[:] is [@lib.I32Const(@lib.I32(site)), @lib.Call(target)] &&
        target == helper => {
        let weight = if i >= 6 &&
          body[i - 6:i]
          is [
            @lib.LocalGet(read),
            @lib.I64Const(@lib.I64(cost)),
            @lib.I64Sub,
            @lib.LocalTee(write),
            @lib.I64Const(@lib.I64(0L)),
            @lib.I64LtS,
          ] &&
          read == write &&
          cache == Some(read) {
          cost
        } else if cache is None &&
          i >= 7 &&
          body[i - 7:i]
          is [
            @lib.GlobalGet(read),
            @lib.I64Const(@lib.I64(cost)),
            @lib.I64Sub,
            @lib.GlobalSet(write),
            @lib.GlobalGet(balance),
            @lib.I64Const(@lib.I64(0L)),
            @lib.I64LtS,
          ] &&
          read == fuel_global &&
          read == write &&
          read == balance {
          cost
        } else {
          raise MalformedFuelSpanGuard
        }
        if site <= 0 || weight <= 0L {
          raise MalformedFuelSpanGuard
        }
        guards.push((site, weight))
      }
      @lib.If(ty, yes, Some(failure)) if ty == @lib.BlockType::void_() &&
        yes.is_empty() &&
        failure[:] is [@lib.I32Const(@lib.I32(site)), @lib.Call(target)] &&
        target == helper => {
        let weight = if i >= 6 &&
          body[i - 6:i]
          is [
            @lib.LocalGet(read),
            @lib.I64Const(@lib.I64(cost)),
            @lib.I64Sub,
            @lib.LocalTee(write),
            @lib.I64Const(@lib.I64(0L)),
            @lib.I64GeS,
          ] &&
          read == write &&
          cache == Some(read) {
          cost
        } else if cache is None &&
          i >= 7 &&
          body[i - 7:i]
          is [
            @lib.GlobalGet(read),
            @lib.I64Const(@lib.I64(cost)),
            @lib.I64Sub,
            @lib.GlobalSet(write),
            @lib.GlobalGet(balance),
            @lib.I64Const(@lib.I64(0L)),
            @lib.I64GeS,
          ] &&
          read == fuel_global &&
          read == write &&
          read == balance {
          cost
        } else {
          raise MalformedFuelSpanGuard
        }
        if site <= 0 || weight <= 0L {
          raise MalformedFuelSpanGuard
        }
        guards.push((site, weight))
      }
      @lib.If(_, yes, no) => {
        scan_fuel_span_guards(yes, helper, fuel_global, cache, guards)
        if no is Some(other) {
          scan_fuel_span_guards(other, helper, fuel_global, cache, guards)
        }
      }
      @lib.Call(target) if target == helper => raise MalformedFuelSpanGuard
      _ => ()
    }
  }
}

///|
fn fuel_balance_cache(
  body : Array[@lib.Instruction],
  fuel_global : @lib.GlobalIdx,
) -> @lib.LocalIdx? {
  let end = if body.length() > 0 { body.length() - 1 } else { 0 }
  for i in 0..<end {
    if body[i:] is [@lib.GlobalGet(global), @lib.LocalSet(index), ..] &&
      global == fuel_global {
      return Some(index)
    }
  }
  None
}

///|
test "Fuel v2 proof finds cached balance after Stack v2 entry locals" {
  let fuel = @lib.GlobalIdx::new(3U)
  let body = [
    @lib.Instruction::global_get(@lib.GlobalIdx::new(8U)),
    @lib.Instruction::local_set(@lib.LocalIdx::new(2U)),
    @lib.Instruction::global_get(fuel),
    @lib.Instruction::local_set(@lib.LocalIdx::new(5U)),
  ]
  assert_eq(fuel_balance_cache(body, fuel), Some(@lib.LocalIdx::new(5U)))
}

///|
/// Reconstruct the static Fuel v2 spans from a validated delivery module.
pub fn verify_fuel_v2_spans(
  module_ : @lib.Module,
  budget : Int64,
) -> Result[Unit, String] {
  let proofs = module_.custom_secs.filter(fn(section) {
    let @lib.CustomSec(name, _) = section
    name == fuel_span_proof_name()
  })
  guard proofs[:] is [@lib.CustomSec(_, payload)] &&
    payload.length() >= 32 &&
    (payload.length() - 32) % 4 == 0 else {
    return Err("missing or malformed Fuel v2 span proof")
  }
  let original_count = (payload.length() - 32) / 4
  let @lib.CodeSec(functions) = module_.code_sec.unwrap_or(
    @lib.CodeSec::new([]),
  )
  guard original_count <= functions.length() else {
    return Err("invalid original function count in Fuel v2 span proof")
  }
  let @lib.ExportSec(exports) = module_.export_sec.unwrap_or(
    @lib.ExportSec::new([]),
  )
  let trap_name = @lib.Name::from_string(trap_export_name)
  let site_name = @lib.Name::from_string(trap_site_export_name)
  let mut trap = None
  let mut site = None
  for @lib.Export(name, target) in exports {
    if name == trap_name && target is @lib.GlobalExternIdx(index) {
      trap = Some(index)
    }
    if name == site_name && target is @lib.GlobalExternIdx(index) {
      site = Some(index)
    }
  }
  guard trap is Some(@lib.GlobalIdx(trap_index)) &&
    trap_index > 0U &&
    site == Some(@lib.GlobalIdx::new(trap_index + 1U)) else {
    return Err("invalid Fuel v2 diagnostic globals")
  }
  let fuel_global = @lib.GlobalIdx::new(trap_index - 1U)
  let @lib.GlobalSec(globals) = module_.global_sec.unwrap_or(
    @lib.GlobalSec::new([]),
  )
  let fuel_index = (trap_index - 1U).reinterpret_as_int() -
    imported_global_count(module_)
  guard globals.get(fuel_index) is Some(@lib.Global(_, @lib.Expr(init))) &&
    init[:] is [@lib.I64Const(@lib.I64(initial))] &&
    initial == budget else {
    return Err("manifest fuel budget does not match Wasm")
  }
  let imported = imported_function_count(module_)
  let helper = func_index(imported + original_count)
  let bounds = Array::make(original_count, 0)
  for i in 0..<original_count {
    let offset = 32 + i * 4
    bounds[i] = payload[offset].to_int() |
      (payload[offset + 1].to_int() << 8) |
      (payload[offset + 2].to_int() << 16) |
      (payload[offset + 3].to_int() << 24)
    if bounds[i] < 0 {
      return Err("invalid final fuel site in Fuel v2 span proof")
    }
  }
  let rows = Buffer()
  let failure_body = charge_trap(
    @lib.GlobalIdx::new(trap_index),
    @lib.GlobalIdx::new(trap_index + 1U),
    TrapCode::Fuel,
    @lib.Instruction::local_get(@lib.LocalIdx::new(0U)),
  )
  let metered = bounds.any(fn(last) { last > 0 })
  let functions = if metered {
    let restored = restore_fuel_v2_inline_leaves(
      module_, functions, original_count, fuel_global, helper,
    ) catch {
      StageRewriteError(reason) => return Err(reason)
    }
    if restored is Some(restored) {
      if validate_wasm(restored, "restored Fuel v2 leaf calls") is Err(error) {
        return Err(error.message())
      }
      let @lib.CodeSec(functions) = restored.code_sec.unwrap_or(
        @lib.CodeSec::new([]),
      )
      functions
    } else {
      functions
    }
  } else {
    functions
  }
  for i, @lib.Func(_, @lib.Expr(body)) in functions {
    if (body == failure_body) != (metered && i == original_count) {
      return Err("missing or misplaced Fuel v2 failure helper")
    }
    if bounds.get(i) == Some(0) && !body.is_empty() {
      return Err("nonempty function has no Fuel v2 span bound")
    }
  }
  if metered {
    guard original_count < functions.length() else {
      return Err("missing Fuel v2 failure helper")
    }
    let mut previous_end = 0
    for i, @lib.Func(_, @lib.Expr(body)) in functions {
      let cache = fuel_balance_cache(body, fuel_global)
      let guards = []
      scan_fuel_span_guards(body, helper, fuel_global, cache, guards) catch {
        MalformedFuelSpanGuard =>
          return Err("malformed Wasm Fuel v2 metering guard")
      }
      let last = bounds.get(i).unwrap_or(0)
      if (last == 0) != guards.is_empty() {
        return Err("Wasm metering guards disagree with Fuel v2 function bounds")
      }
      if cache is Some(_) && guards.length() < 2 {
        return Err(
          "Wasm metering guards disagree with the Fuel v2 balance cache",
        )
      }
      for j, (first, weight) in guards {
        let length = match guards.get(j + 1) {
          Some((next, _)) => next - first
          None => last - first + 1
        }
        if first <= previous_end ||
          first > last ||
          length <= 0 ||
          weight < length.to_int64() ||
          weight > 8L * length.to_int64() {
          return Err(
            "invalid span reconstructed from Wasm Fuel v2 metering guards",
          )
        }
        write_span(rows, imported + i, first, length, weight)
      }
      if last > 0 {
        previous_end = last
      }
    }
  }
  if payload[:32] != Bytes::from_iter(@crypto.sha256(rows.to_bytes()).iter())[:] {
    return Err("Wasm metering guards do not match the Fuel v2 span proof")
  }
  Ok(())
}
