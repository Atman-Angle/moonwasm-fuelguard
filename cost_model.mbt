///|
pub enum FuelV1Boundary {
  Prefix
  Barrier
  Structure
  Marker
}

///|
pub(all) struct FuelV1Rule {
  base : Int64
  per_unit : Int64
  boundary : FuelV1Boundary
}

///|
pub let fuel_v1_version : String = "fuel-v1"

///|
pub const JOIN_FUEL_VERSION = "fuel-v1.2"

///|
pub const FUEL_V2_VERSION = "fuel-v2"

///|
priv enum JoinBoundary {
  Sequence
  Transfer
  Dynamic
}

///|
// Block exits, loop heads and if arms are resolved in the structured planner.
// A fuel-v1 Barrier alone no longer ends a span.
fn join_boundary(
  opcode : String,
  rule : FuelV1Rule,
  fuel_v2 : Bool,
) -> JoinBoundary {
  if !fuel_v2 && rule.per_unit > 0L {
    return Dynamic
  }
  match opcode {
    "br" | "br_if" | "br_table" | "return" | "unreachable" => Transfer
    _ => Sequence
  }
}

///|
/// Exact core-Wasm mnemonics. Feature and immediate validation remains separate.
pub fn fuel_v1_rule(opcode : String) -> FuelV1Rule? {
  match opcode {
    "nop"
    | "drop"
    | "select"
    | "local.get"
    | "local.set"
    | "local.tee"
    | "global.get"
    | "ref.null"
    | "ref.is_null"
    | "i32.const"
    | "i32.clz"
    | "i32.ctz"
    | "i32.popcnt"
    | "i32.add"
    | "i32.sub"
    | "i32.and"
    | "i32.or"
    | "i32.xor"
    | "i32.shl"
    | "i32.shr_s"
    | "i32.shr_u"
    | "i32.rotl"
    | "i32.rotr"
    | "i32.eqz"
    | "i32.eq"
    | "i32.ne"
    | "i32.lt_s"
    | "i32.lt_u"
    | "i32.gt_s"
    | "i32.gt_u"
    | "i32.le_s"
    | "i32.le_u"
    | "i32.ge_s"
    | "i32.ge_u"
    | "i32.extend8_s"
    | "i32.extend16_s"
    | "i64.const"
    | "i64.clz"
    | "i64.ctz"
    | "i64.popcnt"
    | "i64.add"
    | "i64.sub"
    | "i64.and"
    | "i64.or"
    | "i64.xor"
    | "i64.shl"
    | "i64.shr_s"
    | "i64.shr_u"
    | "i64.rotl"
    | "i64.rotr"
    | "i64.eqz"
    | "i64.eq"
    | "i64.ne"
    | "i64.lt_s"
    | "i64.lt_u"
    | "i64.gt_s"
    | "i64.gt_u"
    | "i64.le_s"
    | "i64.le_u"
    | "i64.ge_s"
    | "i64.ge_u"
    | "i64.extend8_s"
    | "i64.extend16_s"
    | "f32.const"
    | "f32.abs"
    | "f32.neg"
    | "f32.ceil"
    | "f32.floor"
    | "f32.trunc"
    | "f32.nearest"
    | "f32.eq"
    | "f32.ne"
    | "f32.lt"
    | "f32.gt"
    | "f32.le"
    | "f32.ge"
    | "f32.copysign"
    | "f64.const"
    | "f64.abs"
    | "f64.neg"
    | "f64.ceil"
    | "f64.floor"
    | "f64.trunc"
    | "f64.nearest"
    | "f64.eq"
    | "f64.ne"
    | "f64.lt"
    | "f64.gt"
    | "f64.le"
    | "f64.ge"
    | "f64.copysign"
    | "i32.wrap_i64"
    | "i64.extend_i32_s"
    | "i64.extend_i32_u"
    | "i64.extend32_s"
    | "i32.reinterpret_f32"
    | "i64.reinterpret_f64"
    | "f32.reinterpret_i32"
    | "f64.reinterpret_i64" =>
      Some({ base: 1L, per_unit: 0L, boundary: Prefix, })
    "i32.mul"
    | "i32.trunc_sat_f32_s"
    | "i32.trunc_sat_f32_u"
    | "i32.trunc_sat_f64_s"
    | "i32.trunc_sat_f64_u"
    | "i64.mul"
    | "i64.trunc_sat_f32_s"
    | "i64.trunc_sat_f32_u"
    | "i64.trunc_sat_f64_s"
    | "i64.trunc_sat_f64_u"
    | "f32.sqrt"
    | "f32.add"
    | "f32.sub"
    | "f32.mul"
    | "f32.div"
    | "f32.min"
    | "f32.max"
    | "f32.convert_i32_s"
    | "f32.convert_i32_u"
    | "f32.convert_i64_s"
    | "f32.convert_i64_u"
    | "f64.sqrt"
    | "f64.add"
    | "f64.sub"
    | "f64.mul"
    | "f64.div"
    | "f64.min"
    | "f64.max"
    | "f64.convert_i32_s"
    | "f64.convert_i32_u"
    | "f64.convert_i64_s"
    | "f64.convert_i64_u"
    | "f32.demote_f64"
    | "f64.promote_f32" => Some({ base: 2L, per_unit: 0L, boundary: Prefix, })
    "i32.div_s"
    | "i32.div_u"
    | "i32.rem_s"
    | "i32.rem_u"
    | "i32.trunc_f32_s"
    | "i32.trunc_f32_u"
    | "i32.trunc_f64_s"
    | "i32.trunc_f64_u"
    | "i64.div_s"
    | "i64.div_u"
    | "i64.rem_s"
    | "i64.rem_u"
    | "i64.trunc_f32_s"
    | "i64.trunc_f32_u"
    | "i64.trunc_f64_s"
    | "i64.trunc_f64_u" => Some({ base: 4L, per_unit: 0L, boundary: Barrier, })
    "i32.load"
    | "i64.load"
    | "f32.load"
    | "f64.load"
    | "i32.load8_s"
    | "i32.load8_u"
    | "i32.load16_s"
    | "i32.load16_u"
    | "i64.load8_s"
    | "i64.load8_u"
    | "i64.load16_s"
    | "i64.load16_u"
    | "i64.load32_s"
    | "i64.load32_u"
    | "i32.store"
    | "i64.store"
    | "f32.store"
    | "f64.store"
    | "i32.store8"
    | "i32.store16"
    | "i64.store8"
    | "i64.store16"
    | "i64.store32"
    | "table.get"
    | "table.set" => Some({ base: 3L, per_unit: 0L, boundary: Barrier, })
    "memory.size" | "table.size" =>
      Some({ base: 2L, per_unit: 0L, boundary: Prefix, })
    "global.set" | "data.drop" | "elem.drop" =>
      Some({ base: 2L, per_unit: 0L, boundary: Barrier, })
    "br" | "br_if" | "return" | "unreachable" =>
      Some({ base: 1L, per_unit: 0L, boundary: Barrier, })
    "br_table" => Some({ base: 2L, per_unit: 0L, boundary: Barrier, })
    "call" => Some({ base: 3L, per_unit: 0L, boundary: Barrier, })
    "call_indirect" => Some({ base: 5L, per_unit: 0L, boundary: Barrier, })
    "block" | "loop" | "if" =>
      Some({ base: 1L, per_unit: 0L, boundary: Structure, })
    "else" | "end" => Some({ base: 0L, per_unit: 0L, boundary: Marker, })
    "memory.copy" | "memory.fill" | "memory.init" =>
      Some({ base: 4L, per_unit: 1L, boundary: Barrier, })
    "table.copy" | "table.fill" | "table.init" =>
      Some({ base: 4L, per_unit: 2L, boundary: Barrier, })
    "memory.grow" => Some({ base: 8L, per_unit: 64L, boundary: Barrier, })
    "table.grow" => Some({ base: 8L, per_unit: 4L, boundary: Barrier, })
    _ => None
  }
}

///|
fn fuel_v1_checked_cost(
  base : Int64,
  per_unit : Int64,
  count : Int64,
) -> Int64? {
  let maximum = 9_223_372_036_854_775_807L
  if base < 0L || per_unit < 0L || count < 0L {
    None
  } else if per_unit == 0L {
    Some(base)
  } else if count > (maximum - base) / per_unit {
    None
  } else {
    Some(base + per_unit * count)
  }
}

///|
/// The static block has already paid the base. Reject overflow of the full
/// mathematical instruction cost before returning the additional debit.
pub fn FuelV1Rule::dynamic_surcharge(
  self : FuelV1Rule,
  count : UInt32,
) -> Int64? {
  match fuel_v1_checked_cost(self.base, self.per_unit, count.to_int64()) {
    Some(total) => Some(total - self.base)
    None => None
  }
}
