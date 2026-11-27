///|
const RECURSIVE_PROGRAM : String =
  #|(begin
  #|  (define fib
  #|    (lambda (n)
  #|      (if (< n 2)
  #|        n
  #|        (+ (fib (- n 1)) (fib (- n 2))))))
  #|  (fib 18))

///|
const LINEAR_PROGRAM : String =
  #|(begin
  #|  (define count
  #|    (lambda (n)
  #|      (if (= n 0)
  #|        0
  #|        (count (- n 1)))))
  #|  (count 400))

///|
priv struct EnvNode {
  name_start : Int
  name_len : Int
  mut value : LispValue
  parent : EnvNode?
}

///|
priv enum LispValue {
  Num(Int)
  Closure(Int, Int, Int, Int, EnvNode?)
}

///|
priv struct EvalResult {
  value : LispValue
  next : Int
}

///|
fn span_eq(
  s : String,
  a_start : Int,
  a_len : Int,
  b_start : Int,
  b_len : Int,
) -> Bool {
  if a_len != b_len {
    return false
  }
  for k in 0..<a_len {
    if s.code_unit_at(a_start + k) != s.code_unit_at(b_start + k) {
      return false
    }
  }
  true
}

///|
fn span_text_eq(s : String, start : Int, len : Int, expect : String) -> Bool {
  if len != expect.length() {
    return false
  }
  for k in 0..<len {
    if s.code_unit_at(start + k) != expect.code_unit_at(k) {
      return false
    }
  }
  true
}

///|
fn is_symbol_char(c : Int) -> Bool {
  let lower = c >= 97 && c <= 122
  let upper = c >= 65 && c <= 90
  let digit = c >= 48 && c <= 57
  let sign = c == 43 || c == 45 || c == 61 || c == 60 || c == 62
  lower || upper || digit || sign
}

///|
fn skip_ws(s : String, i : Int, end : Int) -> Int {
  let mut j = i
  while j < end {
    let c = s.code_unit_at(j).to_int()
    if c == 32 || c == 10 || c == 13 || c == 9 {
      j = j + 1
    } else {
      return j
    }
  }
  j
}

///|
fn env_lookup(
  env : EnvNode?,
  s : String,
  name_start : Int,
  name_len : Int,
) -> LispValue? {
  let mut node = env
  while node is Some(item) {
    if span_eq(s, item.name_start, item.name_len, name_start, name_len) {
      return Some(item.value)
    }
    node = item.parent
  }
  None
}

///|
fn matching_paren(s : String, open : Int, end : Int) -> Int {
  let mut depth = 0
  let mut j = open
  while j < end {
    let c = s.code_unit_at(j).to_int()
    if c == 40 {
      depth = depth + 1
    } else if c == 41 {
      depth = depth - 1
      if depth == 0 {
        return j
      }
    }
    j = j + 1
  }
  end
}

///|
fn expr_end(s : String, start : Int, end : Int) -> Int {
  let i = skip_ws(s, start, end)
  if i < end && s.code_unit_at(i).to_int() == 40 {
    matching_paren(s, i, end) + 1
  } else {
    let mut j = i
    while j < end && is_symbol_char(s.code_unit_at(j).to_int()) {
      j = j + 1
    }
    j
  }
}

///|
fn eval_expr(
  s : String,
  start : Int,
  end : Int,
  env : Ref[EnvNode?],
) -> EvalResult {
  let i = skip_ws(s, start, end)
  if i >= end {
    abort("lisp: unexpected end of program")
  }
  let c = s.code_unit_at(i).to_int()
  if c == 40 {
    let close = matching_paren(s, i, end)
    let inner_end = close
    let mut j = skip_ws(s, i + 1, inner_end)
    let op_start = j
    while j < inner_end && is_symbol_char(s.code_unit_at(j).to_int()) {
      j = j + 1
    }
    let op_len = j - op_start
    if op_len == 0 {
      abort("lisp: expected operator")
    }
    if span_text_eq(s, op_start, op_len, "define") {
      j = skip_ws(s, j, inner_end)
      let name_start = j
      while j < inner_end && is_symbol_char(s.code_unit_at(j).to_int()) {
        j = j + 1
      }
      let name_len = j - name_start
      let node = {
        name_start,
        name_len,
        value: LispValue::Num(0),
        parent: env.val,
      }
      env.val = Some(node)
      let value_r = eval_expr(s, j, inner_end, env)
      node.value = value_r.value
      let rest = skip_ws(s, value_r.next, inner_end)
      if rest < inner_end {
        let after = eval_expr(s, rest, inner_end, env)
        return { value: after.value, next: close + 1 }
      }
      return { value: LispValue::Num(0), next: close + 1 }
    }
    if span_text_eq(s, op_start, op_len, "lambda") {
      j = skip_ws(s, j, inner_end)
      guard s.code_unit_at(j).to_int() == 40 else {
        abort("lisp: lambda needs params")
      }
      let param_close = matching_paren(s, j, inner_end)
      let mut p = skip_ws(s, j + 1, param_close)
      let param_start = p
      while p < param_close && is_symbol_char(s.code_unit_at(p).to_int()) {
        p = p + 1
      }
      let param_len = p - param_start
      let body_start = skip_ws(s, param_close + 1, inner_end)
      let body_end = matching_paren(s, body_start, inner_end) + 1
      return {
        value: LispValue::Closure(param_start, param_len, body_start, body_end - body_start, env.val),
        next: close + 1,
      }
    }
    if span_text_eq(s, op_start, op_len, "if") {
      let cond = eval_expr(s, j, inner_end, env)
      let truth = match cond.value {
        LispValue::Num(n) => n
        _ => 1
      }
      let then_start = skip_ws(s, cond.next, inner_end)
      let then_end = expr_end(s, then_start, inner_end)
      if truth != 0 {
        let then_r = eval_expr(s, then_start, inner_end, env)
        return { value: then_r.value, next: close + 1 }
      }
      let else_start = skip_ws(s, then_end, inner_end)
      let else_r = eval_expr(s, else_start, inner_end, env)
      return { value: else_r.value, next: close + 1 }
    }
    if span_text_eq(s, op_start, op_len, "begin") {
      let mut last = LispValue::Num(0)
      while j < inner_end {
        let step = eval_expr(s, j, inner_end, env)
        last = step.value
        j = skip_ws(s, step.next, inner_end)
      }
      return { value: last, next: close + 1 }
    }
    let op_code = if span_text_eq(s, op_start, op_len, "+") {
      0
    } else if span_text_eq(s, op_start, op_len, "-") {
      1
    } else if span_text_eq(s, op_start, op_len, "<") {
      2
    } else if span_text_eq(s, op_start, op_len, "=") {
      3
    } else {
      -1
    }
    if op_code >= 0 {
      let mut acc = 0
      let mut count = 0
      let mut first = 0
      let mut second = 0
      while j < inner_end {
        let step = eval_expr(s, j, inner_end, env)
        let n = match step.value {
          LispValue::Num(n) => n
          _ => 0
        }
        if count == 0 {
          first = n
        } else if count == 1 {
          second = n
        }
        if op_code == 0 {
          acc = acc + n
        } else if op_code == 1 {
          acc = if count == 0 { n } else { acc - n }
        }
        count = count + 1
        j = skip_ws(s, step.next, inner_end)
      }
      let value = if op_code == 2 {
        LispValue::Num(if first < second { 1 } else { 0 })
      } else if op_code == 3 {
        LispValue::Num(if first == second { 1 } else { 0 })
      } else {
        LispValue::Num(acc)
      }
      return { value, next: close + 1 }
    }
    let callee = match env_lookup(env.val, s, op_start, op_len) {
      Some(value) => value
      None => abort("lisp: unbound function")
    }
    guard callee is LispValue::Closure(param_start, param_len, body_start, body_len, cenv) else {
      abort("lisp: not a function")
    }
    let arg = eval_expr(s, j, inner_end, env)
    let saved = env.val
    env.val = Some({
      name_start: param_start,
      name_len: param_len,
      value: arg.value,
      parent: cenv,
    })
    let body_r = eval_expr(s, body_start, body_start + body_len, env)
    env.val = saved
    return { value: body_r.value, next: close + 1 }
  }
  let token_start = i
  let mut j = i
  while j < end && is_symbol_char(s.code_unit_at(j).to_int()) {
    j = j + 1
  }
  let token_len = j - token_start
  let first = s.code_unit_at(token_start).to_int()
  if (first >= 48 && first <= 57) || (first == 45 && token_len > 1) {
    let mut n = 0
    let mut k = token_start
    let mut neg = false
    if s.code_unit_at(k).to_int() == 45 {
      neg = true
      k = k + 1
    }
    while k < j {
      n = n * 10 + (s.code_unit_at(k).to_int() - 48)
      k = k + 1
    }
    return { value: LispValue::Num(if neg { -n } else { n }), next: j }
  }
  match env_lookup(env.val, s, token_start, token_len) {
    Some(value) => { value, next: j }
    None => abort("lisp: unbound symbol")
  }
}

///|
fn run_program(program : String) -> Int {
  let env : Ref[EnvNode?] = Ref(None)
  let r = eval_expr(program, 0, program.length(), env)
  match r.value {
    LispValue::Num(n) => n
    _ => 0
  }
}

///|
fn run(program : String) -> Unit {
  let value = run_program(program)
  println("Number(" + value.to_string() + ")")
}

///|
fn main {
  run(RECURSIVE_PROGRAM)
  run(LINEAR_PROGRAM)
}
