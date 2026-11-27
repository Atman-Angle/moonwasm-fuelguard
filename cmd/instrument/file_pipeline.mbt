///|
fn instrument_summary(
  options : InstrumentOptions,
  result : @core.PassResult,
  output_size : Int32,
) -> String {
  let mut text = "instrumented \{options.input_path} -> \{options.output_path}\n"
  text = text + "  " + options.describe() + "\n"
  let passes = result.stages().join(", ")
  text = text + "  passes: \{passes}\n"
  for note in result.notes() {
    text = text + "  note: " + note + "\n"
  }
  text + "  output bytes: " + output_size.to_string()
}

///|
async fn instrument_file(
  options : InstrumentOptions,
) -> Result[String, String] noraise {
  let input = match options.config.profile() {
    Legacy =>
      match @fs.read_file_bytes(options.input_path) {
        Ok(bytes) => bytes
        Err(error) =>
          return Err("failed to read input '\{options.input_path}': \{error}")
      }
    _ =>
      read_delivery_file(
        options.input_path,
        input_limit=@core.PRODUCTION_MAX_INPUT_BYTES,
      ) catch {
        DeliveryError(message) =>
          return Err("failed to read input '\{options.input_path}': \{message}")
        error =>
          return Err("failed to read input '\{options.input_path}': \{error}")
      }
  }
  let wasm_module = match @core.decode_input(input, options.config.profile()) {
    Ok(decoded) => decoded
    Err(error) => return Err(error.message())
  }
  let pipeline = @core.Pipeline::builtin(options.config)
  let result = match
    pipeline.run(wasm_module, manifest=options.report_path is Some(_)) {
    Ok(result) => result
    Err(error) => return Err(error.message())
  }
  let encoded = match @core.encode_wasm(result.output()) {
    Ok(bytes) => bytes
    Err(error) => return Err(error.message())
  }
  let report = if options.report_path is Some(path) {
    guard result.manifest_details() is Some(details) else {
      return Err("built-in pipeline did not provide manifest details")
    }
    Some((path, manifest_bytes(input, encoded, details)))
  } else {
    None
  }
  deliver_files(options.output_path, encoded, report) catch {
    DeliveryError(message) => return Err(message)
    error => return Err("file delivery failed: \{error}")
  }
  let mut summary = instrument_summary(options, result, encoded.length())
  if report is Some((path, _)) {
    summary = summary + "\n  manifest: " + path
  }
  if options.stack_layout {
    for row in result.stack_layout() {
      let frame = row.final_frame
      summary = summary +
        "\n  stack function=\{row.function_index} params=\{frame.parameters} results=\{frame.results} locals=\{frame.locals} operands=\{frame.operands} fixed=\{frame.fixed} auxiliary=\{row.auxiliary_peak} entry=\{row.entry_wrapper} A=\{row.actual_cost} C=\{row.shared_cost}"
    }
  }
  Ok(summary)
}
