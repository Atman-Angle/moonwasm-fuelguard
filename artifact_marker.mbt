///|
fn builtin_artifact_marker(
  profile : InputProfile,
  codegen : CodegenLayout,
  stack_model~ : String = stack_model_version,
) -> Bytes {
  let (name, suffix) = match profile {
    ProductionV1 => ("production-v1", "|stack=" + stack_model)
    FuelGrowthV1 => ("fuel-growth-v1", "|stack-audit=" + stack_model)
    Legacy => ("legacy", "")
  }
  let layout = if codegen is P0 { "" } else { "|codegen=" + codegen.version() }
  let model = codegen.fuel_model()
  let metering = if codegen.uses_join_spans() {
    "join-span"
  } else {
    "per-instruction"
  }
  @utf8.encode(
    "\{name}|\{model}|\{diagnostics_abi_version}|metering=\{metering}|growth=\{GROWTH_MODEL_VERSION}\{suffix}\{layout}",
  )
}

///|
/// Validate the selected profile and, when supplied, the manifest's stack version.
pub fn verify_builtin_artifact(
  bytes : Bytes,
  profile : InputProfile,
  codegen? : CodegenLayout,
  stack_model? : String,
) -> Result[Unit, InstrumentError] {
  try {
    let reader = InputReader::{ bytes, pos: 0, end: bytes.length(), }
    ignore(reader.take(8))
    if bytes[0:8].to_owned() != b"\x00asm\x01\x00\x00\x00" {
      reader.bad("expected a core Wasm module")
    }
    let marker_name = @utf8.encode(instrument_marker)
    if codegen is Some(layout) && !(layout is P0) && !(profile is ProductionV1) {
      raise Refused(
        UnsupportedFeature("shared or hybrid codegen requires production-v1"),
      )
    }
    let layouts = match (profile, codegen) {
      (ProductionV1, None) =>
        [
          P0,
          P1,
          P2,
          P2Prefix,
          JoinSpan,
          JoinSpanCached,
          JoinSpanCompact,
          JoinSpanCompactV2,
          FuelV2,
        ]
      _ => [codegen.unwrap_or(P0)]
    }
    let versions = match stack_model {
      Some(version) if !(profile is Legacy) &&
        (version == stack_model_version || version == "stack-v1") => [version]
      Some(_) => raise Refused(UnsupportedFeature("unsupported stack model"))
      None if profile is Legacy => [stack_model_version]
      None => [stack_model_version, "stack-v1"]
    }
    let expected_payloads = []
    for layout in layouts {
      for version in versions {
        expected_payloads.push(
          builtin_artifact_marker(profile, layout, stack_model=version),
        )
      }
    }
    let mut marked = false
    while reader.pos < bytes.length() {
      let id = reader.byte()
      let size = reader.uleb().reinterpret_as_int()
      let begin = reader.take(size)
      let finish = reader.pos
      if id == 0 {
        reader.pos = begin
        reader.end = finish
        let name_length = reader.count("custom section name bytes", 1024)
        let name = reader.take(name_length)
        if name_length == marker_name.length() &&
          bytes[name:reader.pos].to_owned() == marker_name {
          let matches = expected_payloads.any(fn(payload) {
            finish - reader.pos == payload.length() &&
            bytes[reader.pos:finish] == payload[:]
          })
          if marked || !matches {
            raise Refused(
              UnsupportedFeature(
                "duplicate or unsupported FuelGuard profile/model/ABI marker",
              ),
            )
          }
          marked = true
        }
        reader.pos = finish
        reader.end = bytes.length()
      }
    }
    if !marked {
      raise Refused(
        UnsupportedFeature(
          if profile is ProductionV1 {
            "missing FuelGuard production-v1 marker"
          } else {
            "missing FuelGuard compatibility profile marker"
          },
        ),
      )
    }
    Ok(())
  } catch {
    Refused(error) => Err(error)
  }
}

///|
/// Validate the built-in runner's supported artifact marker before engine loading.
pub fn verify_production_artifact(
  bytes : Bytes,
) -> Result[Unit, InstrumentError] {
  verify_builtin_artifact(bytes, ProductionV1)
}
