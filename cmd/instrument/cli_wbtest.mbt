///|
test "instrument cli parses required options" {
  let options = parse_args([
    "in.wasm", "-o", "out.wasm", "--fuel", "100000", "--max-stack-units", "5000",
    "--max-call-depth", "32",
  ]).unwrap()
  assert_eq(options.input_path, "in.wasm")
  assert_eq(options.output_path, "out.wasm")
  assert_eq(options.config.fuel().budget(), 100000)
  assert_true(options.config.guard_config().max_memory_pages() is None)
  assert_true(options.config.guard_config().max_table_elements() is None)
  assert_eq(options.config.guard_config().allowed_imports().length(), 0)
}

///|
test "delivery span scanner rejects a shared charge with nonconstant arguments" {
  let replay = @lib.FuncIdx::new(4U)
  let shared = @lib.FuncIdx::new(5U)
  let call = @lib.Instruction::call(shared)
  let site = @lib.Instruction::i32_const(@lib.I32::new(2))
  let profile = @lib.Instruction::i64_const(@lib.I64::new(129L))
  let rows : Array[ArtifactJoinSpan] = []
  artifact_join_spans(
    [site, profile, call],
    replay,
    0,
    rows,
    true,
    Some(shared),
  )
  assert_eq(rows[0].first, 2)
  assert_eq(rows[0].length, 1)
  let get_arg = @lib.Instruction::local_get(@lib.LocalIdx::new(0U))
  let invalid = @lib.Instruction::i64_const(@lib.I64::new(130L))
  for body in [[call], [site, get_arg, call], [site, invalid, call]] {
    let rejected = try {
      artifact_join_spans(body, replay, 0, [], true, Some(shared))
      false
    } catch {
      MalformedJoinGuard => true
    }
    assert_true(rejected)
  }
}

///|
test "instrument cli binds fuel-v2 to the site-only layout" {
  let common = [
    "in.wasm", "-o", "out.wasm", "--fuel", "10", "--max-stack-units", "5000", "--max-call-depth",
    "32",
  ]
  assert_true(
    parse_args([..common, "--cost-model", "fuel-v2"]).unwrap().config.codegen()
    is @core.FuelV2,
  )
  assert_true(
    parse_args([..common, "--codegen", "fuel-v2"]).unwrap().config.codegen()
    is @core.FuelV2,
  )
  assert_true(
    parse_args(
      [..common, "--codegen", "join-span-compact-v2", "--cost-model", "fuel-v2"],
    )
    is Err(_),
  )
}

///|
test "instrument cli accepts the i64 fuel maximum" {
  let options = parse_args([
    "in.wasm", "-o", "out.wasm", "--fuel", "9223372036854775807", "--max-stack-units",
    "5000", "--max-call-depth", "32",
  ]).unwrap()
  assert_eq(options.config.fuel().budget(), 9_223_372_036_854_775_807L)
}

///|
test "instrument cli rejects stack budgets outside the packed 31-bit domain" {
  let common = ["in.wasm", "-o", "out.wasm", "--fuel", "10"]
  for
    (units, depth) in [
      ("2147483648", "1"),
      ("1", "2147483648"),
      ("9223372036854775807", "1"),
      ("1", "9223372036854775807"),
    ] {
    match
      parse_args(
        [..common, "--max-stack-units", units, "--max-call-depth", depth],
      ) {
      Err(message) => assert_true(message.contains("1..=2147483647"))
      Ok(_) => fail("accepted an out-of-range stack budget")
    }
  }
  assert_true(
    parse_args(
      [
        ..common, "--max-stack-units", "2147483647", "--max-call-depth", "2147483647",
      ],
    )
    is Ok(_),
  )
}

///|
test "instrument cli parses guard options and repeated allow-import" {
  let options = parse_args([
    "in.wasm", "-o", "out.wasm", "--fuel", "500", "--max-stack-units", "5000", "--max-call-depth",
    "32", "--max-memory-pages", "64", "--max-table-elements", "1024", "--allow-import",
    "env.memory", "--allow-import", "wasi.stdout",
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
    "in.wasm", "-o", "out.wasm", "--fuel", "42", "--max-stack-units", "5000", "--max-call-depth",
    "32", "--max-memory-pages", "8", "--allow-import", "env.f", "--allow-import",
    "env.g",
  ]).unwrap()
  let text = options.describe()
  assert_true(text.contains("fuel=42"))
  assert_true(text.contains("max-memory-pages=8"))
  assert_true(text.contains("max-table-elements=none"))
  assert_true(text.contains("allow-import=[env.f,env.g]"))
}

///|
test "instrument summary lists passes, notes, and output size" {
  let options = parse_args([
    "in.wasm", "-o", "out.wasm", "--fuel", "10", "--profile", "fuel-growth-v1",
  ]).unwrap()
  let summary = instrument_summary(
    options,
    @core.PassResult::new(
      "pipeline",
      @core.decode_wasm(b"\x00asm\x01\x00\x00\x00").unwrap(),
      stages=["FuelPass", "GrowthPass"],
      notes=["fuel: budget=10 functions=1 loops=2", "growth: helpers=0"],
    ),
    128,
  )
  assert_true(summary.contains("passes: FuelPass, GrowthPass"))
  assert_true(summary.contains("fuel: budget=10 functions=1 loops=2"))
  assert_true(summary.contains("growth: helpers=0"))
  assert_true(summary.contains("output bytes: 128"))
}

///|
async test "instrument file reports a missing input without writing output" {
  let options = parse_args([
    "definitely-missing-moonwasm-input.wasm", "-o", "definitely-missing-moonwasm-output.wasm",
    "--fuel", "10", "--profile", "fuel-growth-v1",
  ]).unwrap()
  match instrument_file(options) {
    Ok(_) => abort("expected a missing input error")
    Err(message) => assert_true(message.contains("failed to read input"))
  }
}

///|
test "the production CLI defaults to fuel-v2 and rejects retired options" {
  let args = [
    "in.wasm", "-o", "out.wasm", "--fuel", "10", "--max-stack-units", "5000", "--max-call-depth",
    "32",
  ]
  assert_true(parse_args(args).unwrap().config.codegen() is @core.FuelV2)
  for
    (option, values) in [
      (
        "--codegen",
        [
          "p0", "P1", "p2", "p2-prefix", "join-span", "join-span-cached", "join-span-compact",
          "join-span-compact-v2", "join-span-compact-future",
        ],
      ),
      ("--cost-model", ["fuel-v1", "fuel-v1.2", "fuel-v1-experimental"]),
    ] {
    for value in values {
      let error = parse_args([..args, option, value]).unwrap_err()
      assert_true(error.contains("retired \{option}"))
      assert_true(error.contains("original uninstrumented Wasm"))
    }
  }
  assert_true(
    parse_args([..args, "--codegen", "p3"])
    .unwrap_err()
    .contains("unknown --codegen"),
  )
  for option in ["--codegen", "--cost-model"] {
    assert_true(
      parse_args([..args, option, "fuel-v2", option, "fuel-v2"])
      .unwrap_err()
      .contains("duplicate"),
    )
  }
  assert_true(
    parse_args([
      "in.wasm", "-o", "out.wasm", "--fuel", "10", "--profile", "fuel-growth-v1",
      "--cost-model", "fuel-v2",
    ])
    .unwrap_err()
    .contains("requires --profile production-v1"),
  )
}
