///|
test "instrument cli parses required options" {
  let options = parse_args(["in.wasm", "-o", "out.wasm", "--fuel", "100000"]).unwrap()
  assert_eq(options.input_path, "in.wasm")
  assert_eq(options.output_path, "out.wasm")
  assert_eq(options.config.fuel().budget(), 100000)
  assert_true(options.config.guard_config().max_memory_pages() is None)
  assert_true(options.config.guard_config().max_table_elements() is None)
  assert_eq(options.config.guard_config().allowed_imports().length(), 0)
}

///|
test "instrument cli parses guard options and repeated allow-import" {
  let options = parse_args([
    "in.wasm", "-o", "out.wasm", "--fuel", "500", "--max-memory-pages", "64", "--max-table-elements",
    "1024", "--allow-import", "env.memory", "--allow-import", "wasi.stdout",
  ]).unwrap()
  assert_eq(options.config.guard_config().max_memory_pages(), Some(64))
  assert_eq(options.config.guard_config().max_table_elements(), Some(1024))
  let allowed = options.config.guard_config().allowed_imports()
  assert_eq(allowed.length(), 2)
  assert_eq(allowed[0], "env.memory")
  assert_eq(allowed[1], "wasi.stdout")
}

///|
test "instrument cli rejects a missing fuel budget" {
  match parse_args(["in.wasm", "-o", "out.wasm"]) {
    Ok(_) => abort("expected a missing fuel error")
    Err(message) => assert_true(message.contains("--fuel"))
  }
}

///|
test "instrument cli rejects a missing output path" {
  match parse_args(["in.wasm", "--fuel", "10"]) {
    Ok(_) => abort("expected a missing output error")
    Err(message) => assert_true(message.contains("-o"))
  }
}

///|
test "instrument cli rejects a missing input path" {
  match parse_args(["-o", "out.wasm", "--fuel", "10"]) {
    Ok(_) => abort("expected a missing input error")
    Err(message) => assert_true(message.contains("input"))
  }
}

///|
test "instrument cli rejects unknown options" {
  match parse_args(["in.wasm", "-o", "out.wasm", "--fuel", "10", "--unknown"]) {
    Ok(_) => abort("expected an unknown option error")
    Err(message) => assert_true(message.contains("--unknown"))
  }
}

///|
test "instrument cli rejects missing option values" {
  let cases : Array[Array[String]] = [
    ["in.wasm", "-o"],
    ["in.wasm", "-o", "out.wasm", "--fuel"],
    ["in.wasm", "-o", "out.wasm", "--fuel", "10", "--max-memory-pages"],
    ["in.wasm", "-o", "out.wasm", "--fuel", "10", "--allow-import"],
  ]
  for case in cases {
    assert_true(parse_args(case) is Err(_))
  }
}

///|
test "instrument cli rejects invalid numbers" {
  let cases : Array[String] = ["abc", "1.5", "10x", "  "]
  for raw in cases {
    assert_true(
      parse_args(["in.wasm", "-o", "out.wasm", "--fuel", raw]) is Err(_),
    )
  }
  assert_true(
    parse_args([
      "in.wasm", "-o", "out.wasm", "--fuel", "10", "--max-memory-pages", "99999999999999999999",
    ])
    is Err(_),
  )
}

///|
test "instrument cli rejects zero and negative fuel" {
  let zero = parse_args(["in.wasm", "-o", "out.wasm", "--fuel", "0"])
  match zero {
    Ok(_) => abort("expected zero fuel to be rejected")
    Err(message) => assert_true(message.contains("--fuel"))
  }
  assert_true(
    parse_args(["in.wasm", "-o", "out.wasm", "--fuel", "-1"]) is Err(_),
  )
}

///|
test "instrument cli rejects invalid guard limits" {
  assert_true(
    parse_args([
      "in.wasm", "-o", "out.wasm", "--fuel", "10", "--max-memory-pages", "65537",
    ])
    is Err(_),
  )
  assert_true(
    parse_args([
      "in.wasm", "-o", "out.wasm", "--fuel", "10", "--max-table-elements", "-1",
    ])
    is Err(_),
  )
}

///|
test "instrument cli rejects duplicate conflicting options" {
  assert_true(
    parse_args(["in.wasm", "-o", "out.wasm", "-o", "other.wasm", "--fuel", "10"])
    is Err(_),
  )
  assert_true(
    parse_args(["in.wasm", "-o", "out.wasm", "--fuel", "10", "--fuel", "20"])
    is Err(_),
  )
  assert_true(
    parse_args([
      "in.wasm", "-o", "out.wasm", "--fuel", "10", "--max-memory-pages", "1", "--max-memory-pages",
      "2",
    ])
    is Err(_),
  )
}

///|
test "instrument cli rejects extra positional arguments" {
  assert_true(
    parse_args(["in.wasm", "extra.wasm", "-o", "out.wasm", "--fuel", "10"])
    is Err(_),
  )
}

///|
test "instrument cli description includes parsed values" {
  let options = parse_args([
    "in.wasm", "-o", "out.wasm", "--fuel", "42", "--max-memory-pages", "8", "--allow-import",
    "env.f", "--allow-import", "env.g",
  ]).unwrap()
  let text = options.describe()
  assert_true(text.contains("fuel=42"))
  assert_true(text.contains("max-memory-pages=8"))
  assert_true(text.contains("max-table-elements=none"))
  assert_true(text.contains("allow-import=[env.f,env.g]"))
}
