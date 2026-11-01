///|
fn print_usage() -> Unit {
  println("MoonWasm FuelGuard native run adapter")
  println("")
  println("Usage:")
  println("  run <in.wasm>")
  println("  run <in.wasm> --invoke <export>")
  println("")
  println(
    "Status: scaffold only; the Linux wasmoon adapter is not implemented.",
  )
}

///|
fn main_impl(args : Array[String]) -> Int32 {
  if args.length() == 0 {
    print_usage()
    return 2
  }
  match args[0] {
    "help" | "--help" | "-h" => {
      print_usage()
      0
    }
    "--version" => {
      println("0.1.0")
      0
    }
    _ => {
      let _options = @runner.RunOptions::new()
      println("run: scaffold only; use --help for the target CLI contract")
      2
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
fn main {
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
fn main {
  let code = main_impl(trim_program_name(@env.args()))
  if code != 0 {
    native_exit(code)
  }
}
