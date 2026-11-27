///|
fn valid_sha256(text : String) -> Bool {
  if text.length() != 64 {
    return false
  }
  for char in text {
    if !(char >= '0' && char <= '9') && !(char >= 'a' && char <= 'f') {
      return false
    }
  }
  true
}

///|
priv struct ArtifactJoinSpan {
  first : Int32
  length : Int32
  function_index : Int32
  weight : Int64
}

///|
priv suberror JoinGuardError {
  MalformedJoinGuard
}

///|
fn valid_join_spans(
  spans : Array[Json],
  sites : Array[Json],
  guards : Array[ArtifactJoinSpan],
  fuel_v2~ : Bool = false,
) -> Bool {
  if spans.length() != guards.length() {
    return false
  }
  let instructions = []
  for site in sites {
    guard site is Json::Object(row) &&
      row.get("id") is Some(Json::Number(_, ..)) &&
      row.get("function_index") is Some(Json::Number(_, ..)) else {
      return false
    }
    match row.get("kind") {
      Some(Json::String("instruction")) => instructions.push(row)
      Some(Json::String("entry")) => ()
      _ => return false
    }
  }
  let mut cursor = 0
  for index, span in spans {
    let actual = guards[index]
    let function = Some(Json(actual.function_index))
    // Fuel v2 records only a span's first site in Wasm. Its length runs
    // to the next guard or to the end of this function's source site table.
    let length = if fuel_v2 {
      let next = guards.get(index + 1)
      let mut end = cursor
      while end < instructions.length() &&
            instructions[end].get("function_index") == function {
        if next is Some(next) &&
          next.function_index == actual.function_index &&
          instructions[end].get("id") == Some(Json(next.first)) {
          break
        }
        end += 1
      }
      end - cursor
    } else {
      actual.length
    }
    guard span is Json::Object(row) &&
      row.get("first_site") == Some(Json(actual.first)) &&
      row.get("length") == Some(Json(length)) &&
      length > 0 &&
      length <= instructions.length() - cursor else {
      return false
    }
    let mut remaining = actual.weight
    for i in 0..<length {
      let instruction = instructions[cursor + i]
      guard instruction.get("id") == Some(Json(actual.first + i)) &&
        instruction.get("function_index") == function else {
        return false
      }
      if fuel_v2 {
        guard instruction.get("opcode") is Some(Json::String(opcode)) &&
          @core.fuel_v1_rule(opcode) is Some(rule) &&
          rule.base > 0L &&
          rule.base <= remaining else {
          return false
        }
        remaining -= rule.base
      }
    }
    if remaining != 0L {
      return false
    }
    cursor += length
  }
  cursor == instructions.length()
}

///|
// Anchor the failure helper to the private globals of this artifact, not to
// a function index supplied by the sidecar.
fn join_failure_index(
  exports : Array[@lib.Export],
  functions : Array[@lib.Func],
  imported : Int32,
  fuel_v2 : Bool,
) -> @lib.FuncIdx? {
  let name = @lib.Name::from_string(@core.trap_export_name)
  let mut diagnostic = None
  for @lib.Export(key, target) in exports {
    if key == name && target is @lib.GlobalExternIdx(@lib.GlobalIdx(index)) {
      diagnostic = Some(index)
    }
  }
  guard diagnostic is Some(index) && index > 0U else { return None }
  let diagnostics = [
    @lib.Instruction::i32_const(@lib.I32::new(1)),
    @lib.Instruction::global_set(@lib.GlobalIdx::new(index)),
    @lib.Instruction::local_get(@lib.LocalIdx::new(0U)),
    @lib.Instruction::global_set(@lib.GlobalIdx::new(index + 1U)),
    @lib.Instruction::unreachable_(),
  ]
  let tail = [
    @lib.Instruction::local_get(@lib.LocalIdx::new(1U)),
    @lib.Instruction::global_set(@lib.GlobalIdx::new(index - 1U)),
    ..diagnostics,
  ]
  for i, @lib.Func(_, @lib.Expr(body)) in functions {
    if (fuel_v2 && body == diagnostics) ||
      (
        !fuel_v2 &&
        body.length() > tail.length() &&
        body[body.length() - tail.length():] == tail[:]
      ) {
      return Some(@lib.FuncIdx::new((imported + i).reinterpret_as_uint()))
    }
  }
  None
}

///|
fn inline_span_weight(body : Array[@lib.Instruction], index : Int32) -> Int64 {
  if index >= 6 &&
    body[index - 6:index]
    is [
      @lib.LocalGet(read),
      @lib.I64Const(@lib.I64(cost)),
      @lib.I64Sub,
      @lib.LocalTee(write),
      @lib.I64Const(@lib.I64(0L)),
      @lib.I64GeS,
    ] &&
    read == write {
    return cost
  }
  if index >= 6 &&
    body[index - 6:index]
    is [
      @lib.LocalGet(read),
      @lib.I64Const(@lib.I64(cost)),
      @lib.I64Sub,
      @lib.LocalTee(write),
      @lib.I64Const(@lib.I64(0L)),
      @lib.I64LtS,
    ] &&
    read == write {
    return cost
  }
  if index >= 7 &&
    body[index - 7:index]
    is [
      @lib.GlobalGet(read),
      @lib.I64Const(@lib.I64(cost)),
      @lib.I64Sub,
      @lib.GlobalSet(write),
      @lib.GlobalGet(balance),
      @lib.I64Const(@lib.I64(0L)),
      @lib.I64LtS,
    ] &&
    read == write &&
    read == balance {
    return cost
  }
  0L
}

///|
fn artifact_join_spans(
  body : Array[@lib.Instruction],
  helper : @lib.FuncIdx,
  function_index : Int32,
  rows : Array[ArtifactJoinSpan],
  compact : Bool,
  shared : @lib.FuncIdx?,
  fuel_v2~ : Bool = false,
) -> Unit raise JoinGuardError {
  for index, instruction in body {
    match instruction {
      @lib.Block(_, @lib.Expr(child)) | @lib.Loop(_, @lib.Expr(child)) =>
        artifact_join_spans(
          child,
          helper,
          function_index,
          rows,
          compact,
          shared,
          fuel_v2~,
        )
      @lib.If(_, yes, no) =>
        if fuel_v2 &&
          no is None &&
          yes[:] is [@lib.I32Const(@lib.I32(site)), @lib.Call(target)] &&
          target == helper {
          let weight = inline_span_weight(body, index)
          if site <= 0 || weight <= 0L {
            raise MalformedJoinGuard
          }
          rows.push({ first: site, length: 0, function_index, weight, })
        } else if fuel_v2 &&
          yes.is_empty() &&
          no is Some(failure) &&
          failure[:] is [@lib.I32Const(@lib.I32(site)), @lib.Call(target)] &&
          target == helper {
          let weight = inline_span_weight(body, index)
          if site <= 0 || weight <= 0L {
            raise MalformedJoinGuard
          }
          rows.push({ first: site, length: 0, function_index, weight, })
        } else if !fuel_v2 &&
          no is None &&
          yes[:]
          is [
            @lib.I32Const(@lib.I32(site)),
            @lib.LocalGet(_)
            | @lib.GlobalGet(_),
            @lib.I64Const(@lib.I64(profile)),
            @lib.Call(target),
          ] &&
          target == helper {
          rows.push({
            first: site,
            length: join_profile_length(profile, compact),
            function_index,
            weight: 0L,
          })
        } else {
          artifact_join_spans(
            yes,
            helper,
            function_index,
            rows,
            compact,
            shared,
            fuel_v2~,
          )
          if no is Some(other) {
            artifact_join_spans(
              other,
              helper,
              function_index,
              rows,
              compact,
              shared,
              fuel_v2~,
            )
          }
        }
      @lib.Call(target) if shared == Some(target) => {
        guard index >= 2 &&
          body[index - 2] is @lib.I32Const(@lib.I32(site)) &&
          body[index - 1] is @lib.I64Const(@lib.I64(profile)) else {
          raise MalformedJoinGuard
        }
        rows.push({
          first: site,
          length: join_profile_length(profile, true),
          function_index,
          weight: 0L,
        })
      }
      @lib.Call(target) if (compact || fuel_v2) && target == helper =>
        raise MalformedJoinGuard
      _ => ()
    }
  }
}

///|
fn join_profile_length(
  profile : Int64,
  compact : Bool,
) -> Int32 raise JoinGuardError {
  if compact {
    let mut weights = (profile >> 7) & ((1L << 57) - 1L)
    let mut total = 0L
    let mut count = 0
    while weights != 0L {
      let weight = weights & 7L
      if weight == 0L || weight == 7L {
        raise MalformedJoinGuard
      }
      total += if weight == 6L { 8L } else { weight }
      count += 1
      weights = weights >> 3
    }
    if count == 0 || total != (profile & 127L) || total > 95L {
      raise MalformedJoinGuard
    }
    return count
  }
  let mut count = 0
  while count < @core.JOIN_SPAN_LIMIT && ((profile >> (3 * count)) & 7L) != 0L {
    count += 1
  }
  count
}

///|
fn shared_join_index(
  functions : Array[@lib.Func],
  imported : Int32,
  replay : @lib.FuncIdx,
) -> @lib.FuncIdx? {
  let @lib.FuncIdx(index) = replay
  let next = index.reinterpret_as_int() + 1
  guard functions.get(next - imported) is Some(@lib.Func(_, @lib.Expr(body))) &&
    body[:]
    is [
      @lib.GlobalGet(read),
      ..,
      @lib.If(_, yes, None),
      @lib.LocalGet(@lib.LocalIdx(2U)),
      @lib.GlobalSet(write),
    ] &&
    read == write &&
    yes[:]
    is [
      @lib.LocalGet(@lib.LocalIdx(0U)),
      @lib.LocalGet(@lib.LocalIdx(2U)),
      @lib.LocalGet(@lib.LocalIdx(1U)),
      @lib.Call(target),
    ] &&
    target == replay else {
    return None
  }
  Some(@lib.FuncIdx::new(next.reinterpret_as_uint()))
}

///|
fn verify_join_span_bytes(
  wasm : Bytes,
  details : Map[String, Json],
  codegen : @core.CodegenLayout,
) -> Result[Unit, String] {
  guard details.get("fuel_spans") is Some(Json::Array(spans)) &&
    details.get("sites") is Some(Json::Array(sites)) else {
    return Err("incomplete manifest")
  }
  let module_ = match @core.decode_wasm(wasm) {
    Ok(module_) => module_
    Err(error) => return Err(error.message())
  }
  if codegen is @core.FuelV2 &&
    module_.custom_secs.any(fn(section) {
      let @lib.CustomSec(name, _) = section
      name == @lib.Name::from_string(@core.FUEL_V2_SPAN_SECTION)
    }) {
    return Err("Fuel v2 span proof requires manifest v2")
  }
  let imported = match module_.import_sec {
    Some(@lib.ImportSec(imports)) =>
      imports
      .filter(fn(item) { item is @lib.Import(_, _, @lib.FuncExternType(_)) })
      .length()
    None => 0
  }
  let rows : Array[ArtifactJoinSpan] = []
  let fuel_v2 = codegen is @core.FuelV2
  if module_.code_sec is Some(@lib.CodeSec(functions)) &&
    module_.export_sec is Some(@lib.ExportSec(exports)) &&
    join_failure_index(exports, functions, imported, fuel_v2) is Some(helper) {
    let compact = codegen is (@core.JoinSpanCompact | @core.JoinSpanCompactV2)
    let shared = if compact {
      shared_join_index(functions, imported, helper)
    } else {
      None
    }
    let @lib.FuncIdx(replay) = helper
    for index, @lib.Func(_, @lib.Expr(body)) in functions {
      if (compact || fuel_v2) && imported + index >= replay.reinterpret_as_int() {
        break
      }
      artifact_join_spans(
        body,
        helper,
        imported + index,
        rows,
        compact,
        shared,
        fuel_v2~,
      ) catch {
        MalformedJoinGuard =>
          return Err("malformed Wasm join-span metering guard")
      }
    }
  }
  if !valid_join_spans(spans, sites, rows, fuel_v2~) {
    return Err(
      "manifest fuel_spans or instruction sites do not match Wasm metering guards",
    )
  }
  Ok(())
}

///|
fn valid_packed_stack_config(config : Map[String, Json]) -> Bool {
  guard config.get("max_stack_units") is Some(Json::String(units)) &&
    config.get("max_call_depth") is Some(Json::String(depth)) &&
    parse_fuel_option("--max-stack-units", units) is Ok(units) &&
    parse_fuel_option("--max-call-depth", depth) is Ok(depth) else {
    return false
  }
  @core.StackConfig::new(units, depth) is Ok(_)
}

///|
fn valid_manifest_resource_limit(limit : Json?) -> Bool {
  match limit {
    Some(Json::Null) => true
    Some(Json::Number(value, ..)) =>
      value >= 0.0 && value <= 65536.0 && value.to_int().to_double() == value
    _ => false
  }
}

///|
fn complete_instrumentation(
  details : Map[String, Json],
  passes : Array[Json],
  codegen : @core.CodegenLayout,
) -> Bool {
  let stages = [Json("FuelPass"), Json("GrowthPass")]
  let profile = match details.get("profile") {
    Some(Json::String("production-v1" as profile)) => {
      stages.push(Json("StackPass"))
      profile
    }
    Some(Json::String("fuel-growth-v1" | "legacy" as profile)) => profile
    _ => return false
  }
  if passes != stages {
    return false
  }
  let stack_model = match details.get("stack_model") {
    Some(Json::String(version)) =>
      profile != "legacy" &&
      (version == @core.stack_model_version || version == "stack-v1")
    Some(Json::Null) => profile == "legacy"
    _ => false
  }
  details.get("fuel_model") == Some(Json(codegen.fuel_model())) &&
  details.get("growth_model") == Some(Json(@core.GROWTH_MODEL_VERSION)) &&
  details.get("diagnostics_abi") == Some(Json(@core.diagnostics_abi_version)) &&
  (codegen is @core.P0 || profile == "production-v1") &&
  stack_model &&
  details.get("config") is Some(Json::Object(config)) &&
  (
    profile != "production-v1" ||
    details.get("stack_model") != Some(Json(@core.stack_model_version)) ||
    valid_packed_stack_config(config)
  ) &&
  config.get("fuel") is Some(Json::String(_)) &&
  config.get("allowed_imports") is Some(Json::Array(_)) &&
  config.get("max_stack_units") is Some(Json::String(_) | Json::Null) &&
  config.get("max_call_depth") is Some(Json::String(_) | Json::Null) &&
  config.get("max_memory_pages") is Some(Json::Number(_, ..) | Json::Null) &&
  config.get("max_table_elements") is Some(Json::Number(_, ..) | Json::Null) &&
  details.get("appended") is Some(Json::Object(appended)) &&
  appended.get("types") is Some(Json::Object(_)) &&
  appended.get("functions") is Some(Json::Object(_)) &&
  appended.get("globals") is Some(Json::Object(_)) &&
  appended.get("locals") is Some(Json::Array(_)) &&
  appended.get("exports") is Some(Json::Array(_)) &&
  appended.get("custom_sections") is Some(Json::Array(_)) &&
  details.get("features") is Some(Json::Object(features)) &&
  features.get("memory_count") is Some(Json::Number(_, ..)) &&
  features.get("table_count") is Some(Json::Number(_, ..)) &&
  features.get("tables") is Some(Json::Array(_)) &&
  features.get("has_start") is Some(Json::True | Json::False) &&
  features.get("has_multi_value_signature") is Some(Json::True | Json::False) &&
  features.get("declared_value_types") is Some(Json::Array(_)) &&
  features.get("function_body_opcodes") is Some(Json::Array(_)) &&
  details.get("sites") is Some(Json::Array(_))
}

///|
fn verify_minimal_instrumentation(
  wasm : Bytes,
  details : Map[String, Json],
) -> Result[Unit, String] {
  let (profile, codegen, stack_model) = match details.get("profile") {
    Some(Json::String("production-v1")) =>
      (@core.ProductionV1, @core.FuelV2, Some(@core.stack_model_version))
    Some(Json::String("fuel-growth-v1")) =>
      (@core.FuelGrowthV1, @core.P0, Some(@core.stack_model_version))
    Some(Json::String("legacy")) => (@core.Legacy, @core.P0, None)
    _ => return Err("incomplete manifest")
  }
  guard details.length() == 7 &&
    details.get("fuel_model") == Some(Json(codegen.fuel_model())) &&
    details.get("stack_model") ==
    Some(stack_model.map(fn(version) { Json(version) }).unwrap_or(Json::null())) &&
    details.get("growth_model") == Some(Json(@core.GROWTH_MODEL_VERSION)) &&
    details.get("diagnostics_abi") == Some(Json(@core.diagnostics_abi_version)) &&
    details.get("codegen") == Some(Json(codegen.version())) &&
    details.get("config") is Some(Json::Object(config)) &&
    config.length() == 6 &&
    config.get("fuel") is Some(Json::String(fuel)) &&
    parse_fuel_option("--fuel", fuel) is Ok(budget) &&
    budget > 0L &&
    config.get("allowed_imports") is Some(Json::Array(imports)) &&
    valid_manifest_resource_limit(config.get("max_memory_pages")) &&
    valid_manifest_resource_limit(config.get("max_table_elements")) else {
    return Err("incomplete manifest")
  }
  for item in imports {
    guard item is Json::Object(entry) &&
      entry.length() == 2 &&
      entry.get("module") is Some(Json::String(_)) &&
      entry.get("name") is Some(Json::String(_)) else {
      return Err("incomplete manifest")
    }
  }
  if profile is @core.ProductionV1 {
    if !valid_packed_stack_config(config) {
      return Err("incomplete manifest")
    }
  } else if config.get("max_stack_units") != Some(Json::null()) ||
    config.get("max_call_depth") != Some(Json::null()) {
    return Err("incomplete manifest")
  }
  if @core.verify_builtin_artifact(wasm, profile, codegen~, stack_model?)
    is Err(error) {
    return Err(error.message())
  }
  let module_ = match @core.decode_wasm(wasm) {
    Ok(module_) => module_
    Err(error) => return Err(error.message())
  }
  if @core.validate_wasm(module_, "delivery") is Err(error) {
    return Err(error.message())
  }
  if codegen is @core.FuelV2 {
    @core.verify_fuel_v2_spans(module_, budget)
  } else {
    Ok(())
  }
}

///|
fn verify_delivery_manifest(
  wasm : Bytes,
  manifest : Bytes,
) -> Result[Unit, String] {
  let json = @json.parse(@utf8.decode(manifest), reject_duplicate_keys=true) catch {
    error => return Err("invalid manifest JSON: \{error}")
  }
  guard json is Json::Object(fields) &&
    fields.get("schema") is Some(Json::String(schema)) &&
    (schema == MANIFEST_SCHEMA || schema == LEGACY_MANIFEST_SCHEMA) else {
    return Err("missing or unsupported manifest schema")
  }
  guard fields.get("input_sha256") is Some(Json::String(input_hash)) &&
    valid_sha256(input_hash) &&
    fields.get("output_sha256") is Some(Json::String(output_hash)) &&
    valid_sha256(output_hash) &&
    fields.get("tool_version") is Some(Json::String(version)) &&
    version != "" &&
    fields.get("instrumentation") is Some(Json::Object(details)) else {
    return Err("incomplete manifest")
  }
  if sha256_hex(wasm) != output_hash {
    return Err("Wasm SHA-256 does not match manifest output_sha256")
  }
  if schema == MANIFEST_SCHEMA {
    if fields.length() != 6 || fields.get("deterministic") != Some(Json(true)) {
      return Err("incomplete manifest")
    }
    return verify_minimal_instrumentation(wasm, details)
  }
  guard fields.get("passes") is Some(Json::Array(passes)) else {
    return Err("incomplete manifest")
  }
  let codegen = match details.get("codegen") {
    Some(Json::String(version)) if version == @core.BUILTIN_CODEGEN_VERSION =>
      @core.P0
    Some(Json::String(version)) if version == @core.SHARED_CODEGEN_VERSION =>
      @core.P1
    Some(Json::String(version)) if version == @core.HYBRID_CODEGEN_VERSION =>
      @core.P2
    Some(Json::String(version)) if version == @core.PREFIX_CODEGEN_VERSION =>
      @core.P2Prefix
    Some(Json::String(version)) if version == @core.JOIN_CODEGEN_VERSION =>
      @core.JoinSpan
    Some(Json::String(version)) if version == @core.CACHED_JOIN_CODEGEN_VERSION =>
      @core.JoinSpanCached
    Some(Json::String(version)) if version == @core.COMPACT_JOIN_CODEGEN_VERSION =>
      @core.JoinSpanCompact
    Some(Json::String(version)) if version ==
      @core.COMPACT_JOIN_V2_CODEGEN_VERSION => @core.JoinSpanCompactV2
    Some(Json::String(version)) if version == @core.FUEL_V2_CODEGEN_VERSION =>
      @core.FuelV2
    _ => return Err("incomplete manifest")
  }
  if !complete_instrumentation(details, passes, codegen) {
    return Err("incomplete manifest")
  }
  let profile = match details.get("profile") {
    Some(Json::String("production-v1")) => @core.ProductionV1
    Some(Json::String("fuel-growth-v1")) => @core.FuelGrowthV1
    _ => @core.Legacy
  }
  let stack_model = match details.get("stack_model") {
    Some(Json::String(version)) => Some(version)
    _ => None
  }
  let checked = @core.verify_builtin_artifact(
    wasm,
    profile,
    codegen~,
    stack_model?,
  ).map_err(fn(error) { error.message() })
  if checked is Ok(_) &&
    (codegen.fuel_model() == @core.JOIN_FUEL_VERSION || codegen is @core.FuelV2) {
    verify_join_span_bytes(wasm, details, codegen)
  } else {
    checked
  }
}

///|
async fn read_delivery_file(path : String, input_limit? : Int64) -> Bytes {
  if @aio.kind(path) != @aio.Regular {
    raise DeliveryError("expected a regular file")
  }
  let file = @aio.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  if input_limit is Some(limit) && size > limit {
    raise DeliveryError("module bytes \{size} exceeds input limit \{limit}")
  }
  if file.kind() != @aio.Regular || size < 0L || size > 2_147_483_647L {
    raise DeliveryError("expected a regular file of representable size")
  }
  let bytes = file.read_exactly_at(size.to_int(), position=0L)
  if file.size() != size {
    raise DeliveryError("file size changed during verification")
  }
  bytes
}

///|
fn verify_read_error(role : String, path : String, error : Error) -> Int32 {
  let message = match error {
    DeliveryError(message) => message
    other => "\{other}"
  }
  println("instrument: failed to read \{role} '\{path}': \{message}")
  2
}

///|
async fn verify_delivery_command(args : Array[String]) -> Int32 noraise {
  guard args is ["verify", wasm_path, "--report", manifest_path] else {
    println(
      "instrument: usage: instrument verify <out.wasm> --report <manifest.json>",
    )
    return 2
  }
  let manifest = read_delivery_file(manifest_path) catch {
    error => return verify_read_error("manifest", manifest_path, error)
  }
  let wasm = read_delivery_file(wasm_path) catch {
    error => return verify_read_error("Wasm", wasm_path, error)
  }
  match verify_delivery_manifest(wasm, manifest) {
    Ok(_) => {
      println("verified '\{wasm_path}' against '\{manifest_path}'")
      0
    }
    Err(error) => {
      println("instrument: \{error}")
      2
    }
  }
}
