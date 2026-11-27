///|
extern "c" fn now() -> Int64 = "fuelguard_bench_now"

///|
fn[T] checked(result : Result[T, @core.InstrumentError]) -> T {
  match result {
    Ok(value) => value
    Err(error) => abort(error.message())
  }
}

///|
fn main raise {
  let args = @env.args()
  guard args.length() == 7 else {
    abort("expected VARIANT INPUT OUTPUT STACK_UNITS DEPTH WASI")
  }
  let stack = @core.StackConfig::new(
    @string.parse_int64(args[4]),
    @string.parse_int64(args[5]),
  ).unwrap()
  let allow = if args[6] == "1" {
    ["wasi_snapshot_preview1.fd_write"]
  } else {
    []
  }
  let fuel = @core.FuelConfig::new(9223372036854775807L).unwrap()
  let codegen = match args[1] {
    "fuel" | "fuel-v2" => @core.FuelV2
    _ => abort("unsupported build variant; use fuel-v2 or reproduce retired layouts from their historical checkout")
  }
  let config = @core.InstrumentConfig::new(
    fuel,
    @core.GuardConfig::new(
      max_memory_pages=Some(64),
      max_table_elements=Some(64),
      allowed_imports=allow,
    ).unwrap(),
    stack=Some(stack),
    codegen~,
  )
  let marks : Array[(String, Int64)] = []
  let stage = fn(name) { marks.push((name, now())) }
  stage("read")
  let bytes = @fs.read_file_to_bytes(args[2])
  let module_ = checked(@core.decode_input(bytes, @core.ProductionV1, stage~))
  let fuel_only = args[1] == "fuel"
  let result = checked(
    @core.Pipeline::builtin(config).run(module_, fuel_only~, stage~),
  )
  let encoded = checked(@core.encode_wasm(result.output(), stage~))
  stage("write")
  @fs.write_bytes_to_file(args[3], encoded)
  stage("complete")
  for i in 0..<(marks.length() - 1) {
    let (label, start) = marks[i]
    println("\{label} \{marks[i + 1].1 - start}")
  }
}
