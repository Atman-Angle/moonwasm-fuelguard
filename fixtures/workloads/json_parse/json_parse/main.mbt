///|
const DOCUMENT : String =
  #|{
  #|  // JSON5 comment, trailing commas and single quotes are all legal here.
  #|  name: 'FuelGuard support matrix',
  #|  version: 3,
  #|  ratio: 0.125,
  #|  exponent: 1.5e3,
  #|  negative: -42,
  #|  flags: [true, false, null,],
  #|  nested: {
  #|    unicode: 'Huizhou \u0041 \u60e0',
  #|    escapes: 'line\nbreak\ttab',
  #|    matrix: [[1, 2, 3], [4, 5, 6], [7, 8, 9],],
  #|  },
  #|  items: [
  #|    { id: 1, label: 'alpha', weight: 1.25, },
  #|    { id: 2, label: 'beta', weight: -2.5, },
  #|    { id: 3, label: 'gamma', weight: 3.75, },
  #|  ],
  #|}

///|
priv struct ScanState {
  input : String
  mut offset : Int
  mut checksum : Int
  mut depth : Int
}

///|
fn peek_unit(st : ScanState) -> Int {
  if st.offset < st.input.length() {
    st.input.code_unit_at(st.offset).to_int()
  } else {
    -1
  }
}

///|
fn advance(st : ScanState) -> Unit {
  st.offset = st.offset + 1
}

///|
fn skip_trivia(st : ScanState) -> Unit {
  for ;; {
    let c = peek_unit(st)
    if c == 32 || c == 10 || c == 13 || c == 9 {
      advance(st)
    } else if c == 47 {
      advance(st)
      let c2 = peek_unit(st)
      if c2 == 47 {
        while peek_unit(st) != -1 && peek_unit(st) != 10 {
          advance(st)
        }
      } else if c2 == 42 {
        advance(st)
        let mut closed = false
        while !closed {
          if peek_unit(st) == -1 {
            abort("json5: unterminated block comment")
          }
          if peek_unit(st) == 42 {
            advance(st)
            if peek_unit(st) == 47 {
              advance(st)
              closed = true
            }
          } else {
            advance(st)
          }
        }
      } else {
        abort("json5: stray slash")
      }
    } else {
      return
    }
  }
}

///|
fn is_key_char(c : Int) -> Bool {
  let letter = (c >= 97 && c <= 122) || (c >= 65 && c <= 90)
  let digit = c >= 48 && c <= 57
  let extra = c == 95 || c == 36
  letter || digit || extra
}

///|
fn scan_key(st : ScanState) -> Unit {
  let c = peek_unit(st)
  if c == 39 || c == 34 {
    scan_string(st)
  } else {
    let mut units = 0
    let mut sum = 0
    while is_key_char(peek_unit(st)) {
      sum = sum + peek_unit(st)
      units = units + 1
      advance(st)
    }
    if units == 0 {
      println("ABORT: json5: expected key")
      abort("json5: expected key")
    }
    st.checksum = st.checksum + units * 3 + sum
  }
}

///|
fn scan_string(st : ScanState) -> Unit {
  let quote = peek_unit(st)
  if quote != 39 && quote != 34 {
    abort("json5: expected quote")
  }
  advance(st)
  let mut units = 0
  let mut sum = 0
  for ;; {
    let c = peek_unit(st)
    if c == -1 {
      abort("json5: unterminated string")
    }
    if c == quote {
      advance(st)
      break
    }
    if c == 10 || c == 13 {
      abort("json5: raw newline in string")
    }
    if c == 92 {
      advance(st)
      let e = peek_unit(st)
      let mut decoded = 0
      if e == 110 {
        decoded = 10
        advance(st)
      } else if e == 116 {
        decoded = 9
        advance(st)
      } else if e == 114 {
        decoded = 13
        advance(st)
      } else if e == 98 {
        decoded = 8
        advance(st)
      } else if e == 102 {
        decoded = 12
        advance(st)
      } else if e == 118 {
        decoded = 11
        advance(st)
      } else if e == 48 {
        decoded = 0
        advance(st)
      } else if e == 120 {
        advance(st)
        let mut v = 0
        for _ in 0..<2 {
          let h = peek_unit(st)
          let d = if h >= 48 && h <= 57 {
            h - 48
          } else if h >= 97 && h <= 102 {
            h - 87
          } else if h >= 65 && h <= 70 {
            h - 55
          } else {
            abort("json5: bad hex escape")
          }
          v = v * 16 + d
          advance(st)
        }
        decoded = v
      } else if e == 117 {
        advance(st)
        let mut v = 0
        for _ in 0..<4 {
          let h = peek_unit(st)
          let d = if h >= 48 && h <= 57 {
            h - 48
          } else if h >= 97 && h <= 102 {
            h - 87
          } else if h >= 65 && h <= 70 {
            h - 55
          } else {
            abort("json5: bad unicode escape")
          }
          v = v * 16 + d
          advance(st)
        }
        if v >= 0xD800 && v <= 0xDBFF {
          if peek_unit(st) == 92 {
            advance(st)
            if peek_unit(st) == 117 {
              advance(st)
              let mut lo = 0
              for _ in 0..<4 {
                let h = peek_unit(st)
                let d = if h >= 48 && h <= 57 {
                  h - 48
                } else if h >= 97 && h <= 102 {
                  h - 87
                } else if h >= 65 && h <= 70 {
                  h - 55
                } else {
                  abort("json5: bad unicode escape")
                }
                lo = lo * 16 + d
                advance(st)
              }
              if lo >= 0xDC00 && lo <= 0xDFFF {
                v = ((v - 0xD800) * 1024 + (lo - 0xDC00) + 0x10000) & 0xFFFF
              } else {
                abort("json5: bad surrogate pair")
              }
            }
          }
        }
        decoded = v
      } else if e == quote || e == 92 || e == 47 {
        decoded = e
        advance(st)
      } else {
        abort("json5: unknown escape")
      }
      units = units + 1
      sum = sum + decoded
    } else {
      advance(st)
      units = units + 1
      sum = sum + c
    }
  }
  st.checksum = st.checksum + units * 3 + sum
}

///|
fn scan_number(st : ScanState) -> Int {
  let mut neg = false
  if peek_unit(st) == 45 {
    neg = true
    advance(st)
  }
  let mut mantissa : Double = 0.0
  while peek_unit(st) >= 48 && peek_unit(st) <= 57 {
    mantissa = mantissa * 10.0 + (peek_unit(st) - 48).to_double()
    advance(st)
  }
  if peek_unit(st) == 46 {
    advance(st)
    let mut scale = 0.1
    while peek_unit(st) >= 48 && peek_unit(st) <= 57 {
      mantissa = mantissa + (peek_unit(st) - 48).to_double() * scale
      scale = scale / 10.0
      advance(st)
    }
  }
  let e = peek_unit(st)
  if e == 101 || e == 69 {
    advance(st)
    let mut expneg = false
    let sign = peek_unit(st)
    if sign == 43 {
      advance(st)
    } else if sign == 45 {
      expneg = true
      advance(st)
    }
    let mut exp = 0
    while peek_unit(st) >= 48 && peek_unit(st) <= 57 {
      exp = exp * 10 + (peek_unit(st) - 48)
      advance(st)
    }
    let mut k = 0
    while k < exp {
      if expneg {
        mantissa = mantissa / 10.0
      } else {
        mantissa = mantissa * 10.0
      }
      k = k + 1
    }
  }
  let v = mantissa.to_int()
  if neg {
    -v
  } else {
    v
  }
}

///|
fn scan_value(st : ScanState) -> Unit {
  st.depth = st.depth + 1
  if st.depth > 64 {
    abort("json5: depth limit")
  }
  skip_trivia(st)
  let c = peek_unit(st)
  if c == 123 {
    advance(st)
    let mut members = 0
    skip_trivia(st)
    if peek_unit(st) == 125 {
      advance(st)
    } else {
      for ;; {
        skip_trivia(st)
        scan_key(st)
        skip_trivia(st)
        if peek_unit(st) != 58 {
          abort("json5: expected colon")
        }
        advance(st)
        scan_value(st)
        members = members + 1
        skip_trivia(st)
        let sep = peek_unit(st)
        if sep == 44 {
          advance(st)
          skip_trivia(st)
          if peek_unit(st) == 125 {
            advance(st)
            break
          }
        } else if sep == 125 {
          advance(st)
          break
        } else {
          abort("json5: expected comma or brace")
        }
      }
    }
    st.checksum = st.checksum + members * 13
  } else if c == 91 {
    advance(st)
    let mut items = 0
    skip_trivia(st)
    if peek_unit(st) == 93 {
      advance(st)
    } else {
      for ;; {
        skip_trivia(st)
        scan_value(st)
        items = items + 1
        skip_trivia(st)
        let sep = peek_unit(st)
        if sep == 44 {
          advance(st)
          skip_trivia(st)
          if peek_unit(st) == 93 {
            advance(st)
            break
          }
        } else if sep == 93 {
          advance(st)
          break
        } else {
          abort("json5: expected comma or bracket")
        }
      }
    }
    st.checksum = st.checksum + items * 7
  } else if c == 39 || c == 34 {
    scan_string(st)
  } else if c == 116 {
    expect_word(st, "true")
    st.checksum = st.checksum + 1
  } else if c == 102 {
    expect_word(st, "false")
    st.checksum = st.checksum + 2
  } else if c == 110 {
    expect_word(st, "null")
  } else {
    let v = scan_number(st)
    st.checksum = st.checksum + v
  }
  st.depth = st.depth - 1
}

///|
fn expect_word(st : ScanState, word : String) -> Unit {
  for k in 0..<word.length() {
    if st.offset >= st.input.length() {
      abort("json5: truncated literal")
    }
    if st.input.code_unit_at(st.offset) != word.code_unit_at(k) {
      abort("json5: bad literal")
    }
    advance(st)
  }
}

///|
fn scan_document() -> Int {
  let st : ScanState = {
    input: DOCUMENT,
    offset: 0,
    checksum: 0,
    depth: 0,
  }
  scan_value(st)
  skip_trivia(st)
  if peek_unit(st) != -1 {
    abort("json5: trailing content")
  }
  st.checksum
}

///|
fn main {
  let mut round = 0
  let mut checksum = 0
  while round < 200 {
    checksum = checksum + scan_document()
    round = round + 1
  }
  println("json5 rounds=200 checksum=" + checksum.to_string())
}
