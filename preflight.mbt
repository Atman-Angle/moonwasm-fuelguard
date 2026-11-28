///|
pub const PRODUCTION_MAX_INPUT_BYTES : Int64 = 4_194_304L

///|
priv suberror PreflightError {
  Refused(InstrumentError)
}

///|
priv struct InputReader {
  bytes : Bytes
  mut pos : Int32
  mut end : Int32
}

///|
fn InputReader::bad(self : Self, reason : String) -> Unit raise PreflightError {
  raise Refused(DecodeFailed("preflight at byte \{self.pos}: \{reason}"))
}

///|
fn InputReader::take(self : Self, n : Int32) -> Int32 raise PreflightError {
  if n < 0 || n > self.end - self.pos {
    self.bad("truncated field")
  }
  let first = self.pos
  self.pos += n
  first
}

///|
fn InputReader::byte(self : Self) -> Int32 raise PreflightError {
  self.bytes[self.take(1)].to_int()
}

///|
fn InputReader::uleb(self : Self) -> UInt32 raise PreflightError {
  let mut value = 0U
  for i in 0..<5 {
    let octet = self.byte()
    if i == 4 && octet > 15 {
      self.bad("u32 LEB overflow")
    }
    value = value | ((octet & 127).reinterpret_as_uint() << (i * 7))
    if octet < 128 {
      return value
    }
  }
  raise Refused(DecodeFailed("unterminated u32 LEB"))
}

///|
fn InputReader::signed_tail(
  self : Self,
  first : Int32,
  bytes : Int32,
) -> Unit raise PreflightError {
  let mut octet = first
  for _ in 1..<bytes {
    if octet < 128 {
      return
    }
    octet = self.byte()
  }
  if octet >= 128 {
    self.bad("unterminated signed LEB")
  }
}

///|
fn InputReader::count(
  self : Self,
  label : String,
  maximum : Int32,
) -> Int32 raise PreflightError {
  let count = self.uleb()
  check_input_limit(label, count.to_int64(), maximum)
  if count > (self.end - self.pos).reinterpret_as_uint() {
    self.bad("vector count exceeds remaining bytes")
  }
  count.reinterpret_as_int()
}

///|
fn check_input_limit(
  label : String,
  value : Int64,
  maximum : Int32,
) -> Unit raise PreflightError {
  if value > maximum.to_int64() {
    raise Refused(InputLimitExceeded(label, value, maximum))
  }
}

///|
fn InputReader::name(self : Self) -> String raise PreflightError {
  let n = self.count("name bytes", 1024)
  let first = self.take(n)
  @utf8.decode(self.bytes[first:first + n], ignore_bom=true) catch {
    _ => raise Refused(DecodeFailed("preflight: invalid UTF-8 name"))
  }
}

///|
fn InputReader::value_type(self : Self) -> Unit raise PreflightError {
  match self.byte() {
    0x7f | 0x7e | 0x7d | 0x7c | 0x7b | 0x6f => ()
    _ => raise Refused(UnsupportedFeature("production-v1 value type"))
  }
}

///|
fn InputReader::limits(
  self : Self,
  resource : String,
) -> Unit raise PreflightError {
  let flags = self.byte()
  if flags != 0 && flags != 1 {
    raise Refused(
      UnsupportedFeature("production-v1 \{resource} limits flags \{flags}"),
    )
  }
  let initial = self.uleb()
  check_input_limit(resource + " initial size", initial.to_int64(), 65536)
  if flags == 1 {
    let maximum = self.uleb()
    check_input_limit(resource + " declared maximum", maximum.to_int64(), 65536)
  }
}

///|
fn InputReader::memarg(self : Self) -> Unit raise PreflightError {
  if self.uleb() >= 64U {
    self.bad("explicit memory index in memarg")
  }
  ignore(self.uleb())
}

///|
fn InputReader::expr(
  self : Self,
  code : Bool,
  element : Bool,
) -> Int32 raise PreflightError {
  let mut depth = 0
  let mut count = 0
  while true {
    let op = self.byte()
    if op == 0x0b {
      if depth == 0 {
        return count
      }
      depth -= 1
      continue
    }
    if op == 0x05 {
      if depth == 0 {
        self.bad("else outside if")
      }
      continue
    }
    count += 1
    check_input_limit("function instructions", count.to_int64(), 65536)
    if !code && count > 1 {
      self.bad("extended constant expressions are outside production-v1")
    }
    if !code &&
      !(op == 0x23 ||
      (op >= 0x41 && op <= 0x44) ||
      op == 0xd0 ||
      (element && op == 0xd2)) {
      raise Refused(
        UnsupportedFeature("production-v1 constant expression opcode \{op}"),
      )
    }
    match op {
      0x02 | 0x03 | 0x04 => {
        depth += 1
        check_input_limit("structured nesting", depth.to_int64(), 256)
        let first = self.byte()
        if first >= 128 {
          self.signed_tail(first, 5)
        } else if first > 0x40 &&
          !(first == 0x7f ||
          first == 0x7e ||
          first == 0x7d ||
          first == 0x7c ||
          first == 0x7b ||
          first == 0x6f) {
          raise Refused(UnsupportedFeature("production-v1 block type"))
        }
      }
      0x0c
      | 0x0d
      | 0x10
      | 0x20
      | 0x21
      | 0x22
      | 0x23
      | 0x24
      | 0x25
      | 0x26
      | 0x3f
      | 0x40 => ignore(self.uleb())
      0xd2 if element => ignore(self.uleb())
      0x11 => {
        ignore(self.uleb())
        ignore(self.uleb())
      }
      0x0e => {
        let labels = self.count("branch table entries", 65536)
        for _ in 0..<=labels {
          ignore(self.uleb())
        }
      }
      0x1c => {
        let n = self.count("select types", 1)
        for _ in 0..<n {
          self.value_type()
        }
      }
      op if op >= 0x28 && op <= 0x3e => self.memarg()
      0x41 => self.signed_tail(self.byte(), 5)
      0x42 => self.signed_tail(self.byte(), 10)
      0x43 => ignore(self.take(4))
      0x44 => ignore(self.take(8))
      0xd0 => {
        let heap = self.byte()
        if heap != 0x6f && !(element && heap == 0x70) {
          raise Refused(UnsupportedFeature("production-v1 ref.null heap type"))
        }
      }
      0xfc =>
        match self.uleb() {
          0U | 1U | 2U | 3U | 4U | 5U | 6U | 7U => ()
          8U | 10U | 12U | 14U => {
            ignore(self.uleb())
            ignore(self.uleb())
          }
          9U | 11U | 13U | 15U | 16U | 17U => ignore(self.uleb())
          sub =>
            raise Refused(
              UnsupportedFeature("production-v1 misc opcode \{sub}"),
            )
        }
      0xfd =>
        // S25: production-v1 refuses every SIMD opcode (docs/04 scope).
        match self.uleb() {
          sub if sub >= 256U =>
            raise Refused(UnsupportedFeature("relaxed SIMD opcode \{sub}"))
          sub =>
            raise Refused(
              UnsupportedFeature(
                "SIMD opcode \{sub} outside production-v1 allowlist",
              ),
            )
        }
      0x00 | 0x01 | 0x0f | 0x1a | 0x1b | 0xd1 => ()
      op if op >= 0x45 && op <= 0xc4 => () // Exact pricing is checked on the decoded AST.
      _ => raise Refused(UnsupportedFeature("production-v1 opcode \{op}"))
    }
  }
  count
}

///|
fn InputReader::element(self : Self) -> Unit raise PreflightError {
  let mode = self.uleb()
  if mode > 7U {
    self.bad("invalid element segment flags")
  }
  if mode == 0U || mode == 2U || mode == 4U || mode == 6U {
    if mode == 2U || mode == 6U {
      ignore(self.uleb())
    }
    ignore(self.expr(false, false))
  }
  if mode != 0U && mode != 4U {
    let kind = self.byte()
    if (mode < 4U && kind != 0) || (mode >= 4U && kind != 0x6f && kind != 0x70) {
      self.bad("unsupported element type")
    }
  }
  let n = self.count("element entries", 4096)
  for _ in 0..<n {
    if mode < 4U {
      ignore(self.uleb())
    } else {
      ignore(self.expr(false, true))
    }
  }
}

///|
fn InputReader::name_map(self : Self) -> Unit raise PreflightError {
  let n = self.count("name map entries", 1048576)
  for _ in 0..<n {
    ignore(self.uleb())
    ignore(self.name())
  }
}

///|
fn InputReader::custom(self : Self) -> Unit raise PreflightError {
  let name = self.name()
  if name == instrument_marker {
    raise Refused(
      UnsupportedFeature("already instrumented or unknown FuelGuard marker"),
    )
  }
  if name == "compiler.facts" {
    raise Refused(
      UnsupportedFeature("structured compiler.facts custom section"),
    )
  }
  if name == "name" {
    let section_end = self.end
    while self.pos < section_end {
      let id = self.byte()
      let length = self.uleb().reinterpret_as_int()
      let start = self.take(length)
      self.end = self.pos
      self.pos = start
      match id {
        0 => ignore(self.name())
        2 | 3 | 10 => {
          let n = self.count("indirect name map entries", 1048576)
          for _ in 0..<n {
            ignore(self.uleb())
            self.name_map()
          }
        }
        1 | 4 | 5 | 6 | 7 | 8 | 9 | 11 => self.name_map()
        _ => self.pos = self.end
      }
      if self.pos != self.end {
        self.bad("name subsection trailing bytes")
      }
      self.end = section_end
    }
  } else {
    self.pos = self.end
  }
}

///|
fn scan_production_input(bytes : Bytes) -> Unit raise PreflightError {
  check_input_limit(
    "module bytes",
    bytes.length().to_int64(),
    PRODUCTION_MAX_INPUT_BYTES.to_int(),
  )
  let r = InputReader::{ bytes, pos: 0, end: bytes.length(), }
  for byte in [0, 97, 115, 109] {
    if r.byte() != byte {
      r.bad("invalid Wasm magic")
    }
  }
  for byte in [1, 0, 0, 0] {
    if r.byte() != byte {
      raise Refused(UnsupportedFeature("expected core Wasm version 1"))
    }
  }
  let mut funcs = 0
  let mut globals = 0
  let mut instructions = 0
  while r.pos < bytes.length() {
    let section = r.byte()
    let length = r.uleb().reinterpret_as_int()
    let start = r.take(length)
    r.end = r.pos
    r.pos = start
    match section {
      0 => r.custom()
      1 => {
        let types = r.count("types", 1024)
        for _ in 0..<types {
          if r.byte() != 0x60 {
            raise Refused(
              UnsupportedFeature("production-v1 function types only"),
            )
          }
          let params = r.count("parameters", 64)
          for _ in 0..<params {
            r.value_type()
          }
          let results = r.count("results", 16)
          for _ in 0..<results {
            r.value_type()
          }
        }
      }
      2 => {
        let imports = r.count("imports", 256)
        for _ in 0..<imports {
          ignore(r.name())
          ignore(r.name())
          match r.byte() {
            0 => {
              funcs += 1
              ignore(r.uleb())
            }
            1 => raise Refused(UnsupportedFeature("imported table"))
            2 => raise Refused(UnsupportedFeature("imported memory"))
            3 => {
              globals += 1
              r.value_type()
              ignore(r.byte())
            }
            _ => raise Refused(UnsupportedFeature("production-v1 import kind"))
          }
        }
      }
      3 => {
        let n = r.count("defined functions", 4096)
        funcs += n
        check_input_limit("total functions", funcs.to_int64(), 4096)
        for _ in 0..<n {
          ignore(r.uleb())
        }
      }
      4 => {
        let n = r.count("tables", 1)
        for _ in 0..<n {
          let ty = r.byte()
          if ty != 0x70 && ty != 0x6f {
            raise Refused(UnsupportedFeature("production-v1 table type"))
          }
          r.limits("table")
        }
      }
      5 => {
        let n = r.count("memories", 1)
        for _ in 0..<n {
          r.limits("memory")
        }
      }
      6 => {
        let n = r.count("defined globals", 16384)
        globals += n
        check_input_limit("total globals", globals.to_int64(), 16384)
        for _ in 0..<n {
          r.value_type()
          ignore(r.byte())
          ignore(r.expr(false, false))
        }
      }
      7 => {
        let n = r.count("source exports", 1022)
        for _ in 0..<n {
          ignore(r.name())
          ignore(r.byte())
          ignore(r.uleb())
        }
      }
      8 => ignore(r.uleb())
      9 => {
        let n = r.count("element segments", 256)
        for _ in 0..<n {
          r.element()
        }
      }
      10 => {
        let n = r.count("code bodies", 4096)
        let section_end = r.end
        for _ in 0..<n {
          let size = r.uleb().reinterpret_as_int()
          let body = r.take(size)
          r.end = r.pos
          r.pos = body
          let groups = r.count("local declaration groups", 4096)
          let mut locals = 0L
          for _ in 0..<groups {
            locals += r.uleb().to_int64()
            check_input_limit("locals", locals, 4096)
            r.value_type()
          }
          instructions += r.expr(true, false)
          check_input_limit(
            "module instructions",
            instructions.to_int64(),
            1048576,
          )
          if r.pos != r.end {
            r.bad("code body trailing bytes")
          }
          r.end = section_end
        }
      }
      11 => {
        let n = r.count("data segments", 256)
        for _ in 0..<n {
          match r.uleb() {
            0U => ignore(r.expr(false, false))
            1U => ()
            2U => {
              ignore(r.uleb())
              ignore(r.expr(false, false))
            }
            _ => r.bad("invalid data segment flags")
          }
          ignore(r.take(r.uleb().reinterpret_as_int()))
        }
      }
      12 => check_input_limit("data count", r.uleb().to_int64(), 256)
      _ => raise Refused(UnsupportedFeature("production-v1 section \{section}"))
    }
    if r.pos != r.end {
      r.bad("section trailing bytes")
    }
    r.end = bytes.length()
  }
}

///|
pub fn preflight_production_wasm(
  bytes : Bytes,
) -> Result[Unit, InstrumentError] {
  try {
    scan_production_input(bytes)
    Ok(())
  } catch {
    Refused(error) => Err(error)
  }
}
