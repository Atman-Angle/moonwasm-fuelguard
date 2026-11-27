///|
fn print_usage() -> Unit {
  println("MoonWasm FuelGuard instrument CLI")
  println("")
  println("Usage:")
  println("  instrument <in.wasm> -o <out.wasm> --fuel <N>")
  println("             [--profile production-v1|fuel-growth-v1|legacy]")
  println(
    "             [--max-stack-units <N> --max-call-depth <N>] (1..=2147483647 each)",
  )
  println("             [--stack-layout] [--max-memory-pages <N>]")
  println("             [--max-table-elements <N>]")
  println(
    "             [--allow-import <module.name>]... [--report <manifest.json>]",
  )
  println("  instrument verify <out.wasm> --report <manifest.json>")
  println("  --allow-import-pair <module> <field> permits an exact import pair")
  println(
    "  instrument resolve-site <in.wasm> <out.wasm> --report <manifest.json> <site>",
  )
  println("")
  println(
    "Diagnostics: \{@core.trap_export_name} and \{@core.trap_site_export_name}",
  )
  println(
    "--report writes the versioned configuration and input/output SHA-256.",
  )
  println("Choose new output and manifest paths. Existing files are rejected.")
  println(
    "Default profile: production-v1, requiring both stack and depth limits.",
  )
  println("Production uses the fuel-v2 model and layout.")
  println("Specify an explicit limit for every memory or table in the input.")
  println("Indirect calls require a fixed internal funcref table.")
  println("Use --profile fuel-growth-v1 for earlier Fuel/Growth commands.")
}

///|
async fn main_impl(args : Array[String]) -> Int32 noraise {
  if args.length() == 0 {
    print_usage()
    return 2
  }
  match args[0] {
    "help" | "--help" | "-h" => {
      if args.length() != 1 {
        println("instrument: help must be used alone")
        return 2
      }
      print_usage()
      0
    }
    "--version" => {
      if args.length() != 1 {
        println("instrument: --version must be used alone")
        return 2
      }
      println(TOOL_VERSION)
      0
    }
    "verify" if !args.contains("-o") => verify_delivery_command(args)
    "resolve-site" if !args.contains("-o") => resolve_site_command(args)
    _ =>
      match parse_args(args) {
        Ok(options) =>
          match instrument_file(options) {
            Ok(summary) => {
              println(summary)
              0
            }
            Err(message) => {
              println("instrument: \{message}")
              2
            }
          }
        Err(message) => {
          println("instrument: \{message}")
          2
        }
      }
  }
}

///|
fn trim_program_name(argv : Array[String]) -> Array[String] {
  if argv.length() == 0 {
    return []
  }
  let out = Array(capacity=argv.length() - 1)
  let mut index = 1
  while index < argv.length() {
    out.push(argv[index])
    index += 1
  }
  out
}

///|
#cfg(target="wasm")
fn wasm_exit(code : UInt32) -> Unit = "wasi_snapshot_preview1" "proc_exit"

///|
#cfg(target="wasm")
async fn main {
  let code = main_impl(trim_program_name(@env.args()))
  if code != 0 {
    wasm_exit(code.reinterpret_as_uint())
  }
}

///|
#cfg(target="native")
extern "c" fn native_exit(code : Int32) -> Unit = "quick_exit"

///|
#cfg(target="native")
async fn main {
  let code = main_impl(trim_program_name(@env.args()))
  if code != 0 {
    native_exit(code)
  }
}
