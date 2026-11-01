///|
fn instrument_summary(
  options : InstrumentOptions,
  notes : Array[String],
  output_size : Int32,
) -> String {
  let mut text = "instrumented \{options.input_path} -> \{options.output_path}\n"
  text = text + "  " + options.describe() + "\n"
  text = text + "  passes: FuelPass, GuardPass\n"
  for note in notes {
    text = text + "  note: " + note + "\n"
  }
  text + "  output bytes: " + output_size.to_string()
}

///|
fn instrument_file(options : InstrumentOptions) -> Result[String, String] {
  let input = match @fs.read_file_bytes(options.input_path) {
    Ok(bytes) => bytes
    Err(error) =>
      return Err("failed to read input '\{options.input_path}': \{error}")
  }
  let wasm_module = match @core.decode_checked(input) {
    Ok(decoded) => decoded
    Err(error) => return Err(error.message())
  }
  let pipeline = @core.Pipeline::builtin(options.config)
  let result = match pipeline.run(wasm_module) {
    Ok(result) => result
    Err(error) => return Err(error.message())
  }
  let encoded = match @core.encode_wasm(result.output()) {
    Ok(bytes) => bytes
    Err(error) => return Err(error.message())
  }
  match @fs.write_file_bytes(options.output_path, encoded) {
    Ok(_) => ()
    Err(error) =>
      return Err("failed to write output '\{options.output_path}': \{error}")
  }
  Ok(instrument_summary(options, result.notes(), encoded.length()))
}
