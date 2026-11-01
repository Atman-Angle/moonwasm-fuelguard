///|
priv struct InstrumentOptions {
  input_path : String
  output_path : String
  config : @core.InstrumentConfig
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
  if text.length() == 0 {
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
fn parse_args(raw_args : Array[String]) -> Result[InstrumentOptions, String] {
  let mut input_path : String? = None
  let mut output_path : String? = None
  let mut fuel : Int32? = None
  let mut max_memory_pages : Int32? = None
  let mut max_table_elements : Int32? = None
  let allow_imports : Array[String] = []
  let mut index = 0
  while index < raw_args.length() {
    let argument = raw_args[index]
    let option = match argument {
      "-o"
      | "--fuel"
      | "--max-memory-pages"
      | "--max-table-elements"
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
        index += 1
        match name {
          "-o" =>
            if output_path is Some(_) {
              return Err("duplicate -o")
            } else {
              output_path = Some(value)
            }
          "--fuel" =>
            if fuel is Some(_) {
              return Err("duplicate --fuel")
            } else {
              match parse_decimal_option("--fuel", value) {
                Ok(parsed) => fuel = Some(parsed)
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
  let fuel_config = match @core.FuelConfig::new(fuel_budget) {
    Ok(config) => config
    Err(error) => return Err("invalid --fuel: \{error.message()}")
  }
  let guard_config = match
    @core.GuardConfig::new(
      max_memory_pages~,
      max_table_elements~,
      allowed_imports=allow_imports,
    ) {
    Ok(config) => config
    Err(error) => return Err("invalid guard limit: \{error.message()}")
  }
  Ok({
    input_path,
    output_path,
    config: @core.InstrumentConfig::new(fuel_config, guard_config),
  })
}
