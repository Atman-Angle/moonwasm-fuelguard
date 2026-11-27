///|
priv struct InstrumentOptions {
  input_path : String
  output_path : String
  report_path : String?
  config : @core.InstrumentConfig
  stack_layout : Bool
}

///|
fn describe_limit(limit : Int32?) -> String {
  match limit {
    Some(value) => value.to_string()
    None => "none"
  }
}

///|
fn InstrumentOptions::describe(self : Self) -> String {
  let guard_config = self.config.guard_config()
  let mut allowed = ""
  for item in guard_config.allowed_imports() {
    if allowed.length() > 0 {
      allowed = allowed + ","
    }
    allowed = allowed + item
  }
  let memory_limit = describe_limit(guard_config.max_memory_pages())
  let table_limit = describe_limit(guard_config.max_table_elements())
  "input=\{self.input_path} output=\{self.output_path} fuel=\{self.config.fuel().budget()} max-memory-pages=\{memory_limit} max-table-elements=\{table_limit} allow-import=[\{allowed}]"
}

///|
fn parse_decimal_option(name : String, raw : String) -> Result[Int32, String] {
  let text = raw.trim()
  if text.length() == 0 || text == "-" {
    return Err("missing value for \{name}")
  }
  let mut value = 0
  let mut negative = false
  let mut first = true
  for c in text {
    if first && c == '-' {
      negative = true
      first = false
      continue
    }
    first = false
    if c < '0' || c > '9' {
      return Err("\{name} expects a decimal integer, got '\{raw}'")
    }
    let digit = c.to_int() - '0'.to_int()
    if value > (2_147_483_647 - digit) / 10 {
      return Err("\{name} is out of range: '\{raw}'")
    }
    value = value * 10 + digit
  }
  if first {
    return Err("missing value for \{name}")
  }
  if negative {
    Ok(-value)
  } else {
    Ok(value)
  }
}

///|
fn parse_fuel_option(name : String, raw : String) -> Result[Int64, String] {
  let text = raw.trim()
  if text.length() == 0 || text == "-" {
    return Err("missing value for \{name}")
  }
  let mut value = 0L
  let mut negative = false
  let mut first = true
  let maximum = 9_223_372_036_854_775_807L
  for c in text {
    if first && c == '-' {
      negative = true
      first = false
      continue
    }
    first = false
    if c < '0' || c > '9' {
      return Err("\{name} expects a decimal integer, got '\{raw}'")
    }
    let digit = c.to_int().to_int64() - 48L
    if value > (maximum - digit) / 10L {
      return Err("\{name} is out of range: '\{raw}'")
    }
    value = value * 10L + digit
  }
  if first {
    return Err("missing value for \{name}")
  }
  if negative {
    Ok(0L - value)
  } else {
    Ok(value)
  }
}

///|
fn parse_args(raw_args : Array[String]) -> Result[InstrumentOptions, String] {
  let mut stack_layout = false
  let mut profile : @core.InputProfile? = None
  let mut model : String? = None
  let mut codegen = false
  let mut input_path : String? = None
  let mut output_path : String? = None
  let mut report_path : String? = None
  let mut fuel : Int64? = None
  let mut stack_units : Int64? = None
  let mut call_depth : Int64? = None
  let mut max_memory_pages : Int32? = None
  let mut max_table_elements : Int32? = None
  let allow_imports : Array[String] = []
  let allow_import_pairs : Array[(String, String)] = []
  let mut index = 0
  while index < raw_args.length() {
    let argument = raw_args[index]
    if argument == "--allow-import-pair" {
      if index + 2 >= raw_args.length() {
        return Err(
          "--allow-import-pair requires a module name and a field name",
        )
      }
      allow_import_pairs.push((raw_args[index + 1], raw_args[index + 2]))
      index += 3
      continue
    }
    if argument == "--stack-layout" {
      if stack_layout {
        return Err("duplicate --stack-layout")
      }
      stack_layout = true
      index += 1
      continue
    }
    let option = match argument {
      "-o"
      | "--profile"
      | "--cost-model"
      | "--codegen"
      | "--fuel"
      | "--max-stack-units"
      | "--max-call-depth"
      | "--max-memory-pages"
      | "--max-table-elements"
      | "--report"
      | "--allow-import" => Some(argument)
      _ =>
        if argument.has_prefix("-") {
          return Err("unknown option: \{argument}")
        } else {
          None
        }
    }
    match option {
      None =>
        if input_path is Some(_) {
          return Err("unexpected extra argument: \{argument}")
        } else {
          input_path = Some(argument)
        }
      Some(name) => {
        if index + 1 >= raw_args.length() {
          return Err("missing value for \{name}")
        }
        let value = raw_args[index + 1]
        if value.length() == 0 ||
          ((name == "-o" || name == "--report") && value.has_prefix("-")) {
          return Err("missing value for \{name}")
        }
        index += 1
        match name {
          "-o" =>
            if output_path is Some(_) {
              return Err("duplicate -o")
            } else {
              output_path = Some(value)
            }
          "--report" =>
            if report_path is Some(_) {
              return Err("duplicate --report")
            } else {
              report_path = Some(value)
            }
          "--profile" => {
            if profile is Some(_) {
              return Err("duplicate --profile")
            }
            profile = match value {
              "production-v1" => Some(@core.ProductionV1)
              "fuel-growth-v1" => Some(@core.FuelGrowthV1)
              "legacy" => Some(@core.Legacy)
              _ => return Err("unknown --profile '\{value}'")
            }
          }
          "--codegen" => {
            if codegen {
              return Err("duplicate --codegen")
            }
            if value != @core.FUEL_V2_VERSION {
              let label = if value.to_lower()
                is ("p0"
                | "p1"
                | "p2"
                | "p2-prefix"
                | "join-span"
                | "join-span-cached") ||
                value.has_prefix("join-span-compact") {
                "retired"
              } else {
                "unknown"
              }
              return Err(
                "\{label} --codegen '\{value}'; use the default fuel-v2 layout with the original uninstrumented Wasm",
              )
            }
            codegen = true
          }
          "--cost-model" => {
            if model is Some(_) {
              return Err("duplicate --cost-model")
            }
            if value != @core.FUEL_V2_VERSION {
              let label = if value.has_prefix("fuel-v1") {
                "retired"
              } else {
                "unknown"
              }
              return Err(
                "\{label} --cost-model '\{value}'; use the default fuel-v2 model with the original uninstrumented Wasm",
              )
            }
            model = Some(value)
          }
          "--fuel" =>
            if fuel is Some(_) {
              return Err("duplicate --fuel")
            } else {
              match parse_fuel_option("--fuel", value) {
                Ok(parsed) => fuel = Some(parsed)
                Err(error) => return Err(error)
              }
            }
          "--max-stack-units" =>
            if stack_units is Some(_) {
              return Err("duplicate --max-stack-units")
            } else {
              match parse_fuel_option(name, value) {
                Ok(parsed) => stack_units = Some(parsed)
                Err(error) => return Err(error)
              }
            }
          "--max-call-depth" =>
            if call_depth is Some(_) {
              return Err("duplicate --max-call-depth")
            } else {
              match parse_fuel_option(name, value) {
                Ok(parsed) => call_depth = Some(parsed)
                Err(error) => return Err(error)
              }
            }
          "--max-memory-pages" =>
            if max_memory_pages is Some(_) {
              return Err("duplicate --max-memory-pages")
            } else {
              match parse_decimal_option("--max-memory-pages", value) {
                Ok(parsed) => max_memory_pages = Some(parsed)
                Err(error) => return Err(error)
              }
            }
          "--max-table-elements" =>
            if max_table_elements is Some(_) {
              return Err("duplicate --max-table-elements")
            } else {
              match parse_decimal_option("--max-table-elements", value) {
                Ok(parsed) => max_table_elements = Some(parsed)
                Err(error) => return Err(error)
              }
            }
          "--allow-import" => allow_imports.push(value)
          _ => return Err("unknown option: \{name}")
        }
      }
    }
    index += 1
  }
  let input_path = match input_path {
    Some(path) => path
    None => return Err("missing input wasm path")
  }
  let output_path = match output_path {
    Some(path) => path
    None => return Err("missing required -o output path")
  }
  let fuel_budget = match fuel {
    Some(budget) => budget
    None => return Err("missing required --fuel budget")
  }
  if report_path == Some(input_path) || report_path == Some(output_path) {
    return Err("--report must differ from the input and output paths")
  }
  if input_path == output_path {
    return Err("output path already exists: output must differ from input")
  }
  let fuel_config = match @core.FuelConfig::new(fuel_budget) {
    Ok(config) => config
    Err(error) => return Err("invalid --fuel: \{error.message()}")
  }
  let guard_config = match
    @core.GuardConfig::new(
      max_memory_pages~,
      max_table_elements~,
      allowed_imports=allow_imports,
      allowed_import_pairs=allow_import_pairs,
    ) {
    Ok(config) => config
    Err(error) => return Err("invalid guard limit: \{error.message()}")
  }
  let stack = match (stack_units, call_depth) {
    (None, None) => None
    (Some(units), Some(depth)) =>
      match @core.StackConfig::new(units, depth) {
        Ok(config) => Some(config)
        Err(error) => return Err(error.message())
      }
    _ =>
      return Err(
        "--max-stack-units and --max-call-depth must be provided together",
      )
  }
  let selected = profile.unwrap_or(@core.ProductionV1)
  if (codegen || model is Some(_)) && !(selected is @core.ProductionV1) {
    return Err("fuel-v2 requires --profile production-v1")
  }
  if selected is @core.ProductionV1 && stack is None {
    return Err(
      "production-v1 requires --max-stack-units and --max-call-depth (use --profile fuel-growth-v1 for the previous Fuel/Growth mode)",
    )
  }
  if selected is @core.Legacy && stack_layout {
    return Err("stack analysis requires production-v1 or fuel-growth-v1")
  }
  if selected is @core.Legacy &&
    (allow_imports.length() > 0 || allow_import_pairs.length() > 0) {
    return Err("--allow-import requires production-v1 or fuel-growth-v1")
  }
  if !(selected is @core.ProductionV1) && stack is Some(_) {
    return Err("stack limits require production-v1")
  }
  Ok({
    stack_layout,
    input_path,
    output_path,
    report_path,
    config: @core.InstrumentConfig::new(
      fuel_config,
      guard_config,
      profile=selected,
      stack~,
    ),
  })
}
