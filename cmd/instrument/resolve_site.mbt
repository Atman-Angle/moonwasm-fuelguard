///|
fn resolve_delivery_site(
  source : Bytes,
  product : Bytes,
  report : Bytes,
  site : Int32,
) -> Result[@core.DiagnosticSite, String] {
  if verify_delivery_manifest(product, report) is Err(error) {
    return Err(error)
  }
  let manifest = @json.parse(@utf8.decode(report), reject_duplicate_keys=true) catch {
    error => return Err("invalid manifest JSON: \{error}")
  }
  guard manifest is Json::Object(fields) &&
    fields.get("schema") == Some(Json(MANIFEST_SCHEMA)) &&
    fields.get("instrumentation") is Some(Json::Object(details)) &&
    details.get("profile") == Some(Json("production-v1")) &&
    details.get("codegen") == Some(Json(@core.FUEL_V2_CODEGEN_VERSION)) else {
    return Err(
      "resolve-site requires a production Fuel v2 artifact and manifest v2",
    )
  }
  if fields.get("input_sha256") != Some(Json(sha256_hex(source))) {
    return Err("original Wasm SHA-256 does not match manifest input_sha256")
  }
  let original = match @core.decode_input(source, @core.ProductionV1) {
    Ok(original) => original
    Err(error) => return Err(error.message())
  }
  match @core.resolve_production_site(original, site) {
    Ok(Some(location)) => Ok(location)
    Ok(None) => Err("site \{site} does not exist in the original Wasm")
    Err(error) => Err(error.message())
  }
}

///|
async fn resolve_site_command(args : Array[String]) -> Int32 noraise {
  guard args
    is ["resolve-site", source_path, product_path, "--report", report_path, id] &&
    parse_fuel_option("site", id) is Ok(site) &&
    site > 0L &&
    site <= 2_147_483_647L else {
    println(
      "instrument: usage: instrument resolve-site <in.wasm> <out.wasm> --report <manifest.json> <positive-site>",
    )
    return 2
  }
  let source = read_delivery_file(
    source_path,
    input_limit=@core.PRODUCTION_MAX_INPUT_BYTES,
  ) catch {
    error => return verify_read_error("original Wasm", source_path, error)
  }
  let product = read_delivery_file(product_path) catch {
    error => return verify_read_error("protected Wasm", product_path, error)
  }
  let report = read_delivery_file(report_path) catch {
    error => return verify_read_error("manifest", report_path, error)
  }
  match resolve_delivery_site(source, product, report, site.to_int()) {
    Ok(location) => {
      let function = location.function_index
      match (location.instruction_ordinal, location.opcode) {
        (Some(ordinal), Some(opcode)) =>
          println(
            "site=\{site} function=\{function} instruction=\{ordinal} opcode=\{opcode}",
          )
        _ => println("site=\{site} function=\{function} entry=export-or-start")
      }
      0
    }
    Err(error) => {
      println("instrument: \{error}")
      2
    }
  }
}
