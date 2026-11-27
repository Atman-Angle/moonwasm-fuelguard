///|
#derive(ToJson)
priv struct Outcome {
  case_id : String
  stages : Array[String]
  error : String?
}

///|
fn instrument(
  input_path : String,
  output_path : String,
  fuel : Int64,
  codegen : @core.CodegenLayout,
) -> Result[Array[String], String] {
  let input = match @fs.read_file_bytes(input_path) {
    Ok(bytes) => bytes
    Err(error) => return Err("read: " + error)
  }
  let module_ = match @core.decode_input(input, @core.ProductionV1) {
    Ok(value) => value
    Err(error) => return Err("decode: " + error.message())
  }
  let config = @core.InstrumentConfig::new(
    @core.FuelConfig::new(fuel).unwrap(),
    @core.GuardConfig::new(max_memory_pages=Some(2), max_table_elements=Some(2)).unwrap(),
    profile=@core.ProductionV1,
    codegen~,
    stack=Some(@core.StackConfig::new(100000L, 64L).unwrap()),
  )
  let result = match @core.Pipeline::builtin(config).run(module_) {
    Ok(value) => value
    Err(error) => return Err("pipeline: " + error.message())
  }
  let output = match @core.encode_wasm(result.output()) {
    Ok(bytes) => bytes
    Err(error) => return Err("encode: " + error.message())
  }
  match @fs.write_file_bytes(output_path, output) {
    Ok(_) => Ok(result.stages())
    Err(error) => Err("write: " + error)
  }
}

///|
fn main {
  let args = @env.args()
  let (start, codegen) = match args.get(1) {
    Some("--fuel-v2") => (2, @core.FuelV2)
    Some("--p1") => (2, @core.P1)
    Some("--p2") => (2, @core.P2)
    Some("--p2-prefix") => (2, @core.P2Prefix)
    Some("--join-span") => (2, @core.JoinSpan)
    Some("--join-span-cached") => (2, @core.JoinSpanCached)
    Some("--join-span-compact") => (2, @core.JoinSpanCompact)
    Some("--join-span-compact-v2") => (2, @core.JoinSpanCompactV2)
    _ => (1, @core.P0)
  }
  guard args.length() > start && (args.length() - start) % 4 == 0 else {
    abort(
      "expected optional codegen flag followed by CASE FUEL INPUT OUTPUT for each corpus sample",
    )
  }
  for i = start; i < args.length(); i = i + 4 {
    let case_id = args[i]
    let fuel = @string.parse_int64(args[i + 1]) catch {
      _ => abort("invalid fuel in batch request")
    }
    let outcome : Outcome = match
      instrument(args[i + 2], args[i + 3], fuel, codegen) {
      Ok(stages) => { case_id, stages, error: None, }
      Err(error) => { case_id, stages: [], error: Some(error), }
    }
    println(ToJson::to_json(outcome).stringify())
  }
}
