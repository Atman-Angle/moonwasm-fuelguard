///|
extern "c" fn now() -> Int64 = "fuelguard_bench_now"

///|
priv struct Prepared {
  module_ : @types.Module
  artifact : @wasmoon_jit.LoadedArtifact
}

///|
priv struct Instance {
  linker : @runtime.Linker
  compiled : @jit.JITModule
  references : @binding.FuncrefRegistration
  output : Array[Bytes]
}

///|
fn prepare(path : String) -> Prepared raise {
  let begin = now()
  let module_ = @parser.parse_module(@fs.read_file_to_bytes(path))
  @validator.validate_module(module_)
  let compiling = now()
  guard @commands.compile_module_to_jit(
      module_,
      false,
      false,
      0,
      false,
      enable_cancellation=true,
    )
    is Some((artifact, _)) else {
    abort("wasmoon compile failed")
  }
  let elapsed = now() - compiling
  let verifying = now()
  let artifact = @commands.verify_compiled_jit_artifact(artifact)
  println("compile \{compiling - begin} \{elapsed} \{now() - verifying}")
  { module_, artifact, }
}

///|
fn instantiate(prepared : Prepared, wasi : Bool) -> Instance raise {
  let { module_, artifact, } = prepared
  let output = []
  let linker = @runtime.Linker::Linker()
  if wasi {
    let context = @wasi.WasiContextBuilder::WasiContextBuilder()
      .stdout(fn(bytes) { output.push(bytes) })
      .build()
    @wasi.register_wasi(linker, context)
  }
  let store = linker.get_store()
  store.enable_c_heap()
  let instance = @executor.instantiate_module_with_imports_unstarted(
    store,
    module_,
    linker.build_imports(),
  )
  let compiled = @jit.JITModule::load_artifact_with_imports(
    artifact,
    @binding.build_func_signatures(module_),
    @binding.build_external_imports_for_jit(module_, instance, store),
    resource_budget=store.resource_budget,
  )
  guard compiled.configure_native_fiber_stack_size(16777216L) else {
    abort("could not configure 16 MiB fiber")
  }
  let references = @binding.register_owned_instance_funcrefs_for_jit(
    compiled, instance, store,
  )
  ignore(@binding.init_jit_memories_from_store(instance, store, compiled))
  let globals = @binding.init_jit_globals_from_store(instance, store, compiled)
  @binding.init_elem_segments(module_, compiled, instance, store)
  @binding.init_bulk_segments(module_, compiled, instance, store)
  let context = @binding.JITModuleContext::JITModuleContext(
    compiled,
    globals,
    instance.global_addrs[:],
    instance.table_addrs[:],
    instance.func_addrs[:],
    instance.func_type_indices[:],
    instance.canonical_type_indices[:],
    module_.types[:],
    module_.type_rec_groups[:],
    false,
  )
  context.install_hostcall_dispatcher(store, instance)
  let session = { linker, compiled, references, output, }
  if module_.start is Some(index) {
    guard session.call(index).is_empty() else { abort("start returned values") }
  }
  session
}

///|
fn Instance::close(self : Self) -> Unit {
  self.compiled.clear_hostcall_callback()
  self.references.release()
  self.compiled.close()
  self.linker.close()
}

///|
fn Instance::call(self : Self, index : Int32) -> Array[Int64] {
  guard self.compiled.get_func(index) is Some(function) else {
    abort("missing function")
  }
  let store = self.linker.get_store()
  store.begin_gc_tracing()
  let result = self.compiled.call_with_context_controlled(function, [])
  store.end_gc_tracing()
  match result {
    Completed(values) => values
    _ => abort("unexpected wasmoon trap or exit")
  }
}

///|
fn Instance::check(self : Self, expected : Bytes, repetitions : Int32) -> Unit {
  let mut index = 0
  for chunk in self.output {
    for byte in chunk {
      if expected.is_empty() || byte != expected[index % expected.length()] {
        abort("unexpected wasmoon stdout")
      }
      index += 1
    }
  }
  guard index == expected.length() * repetitions else {
    abort("unexpected wasmoon stdout length")
  }
  self.output.clear()
}

///|
fn entry_index(
  module_ : @types.Module,
  name : String,
  expects_i32 : Bool,
) -> Int32? {
  if name == "-" {
    guard !expects_i32 else {
      abort("result expected without a business entry")
    }
    return None
  }
  for item in module_.exports {
    if item.name == name && item.desc is @types.ExportDesc::Func(index) {
      let (parameters, results) = @binding.build_func_signatures(module_)[index]
      guard parameters.is_empty() &&
        (if expects_i32 { results[:] is [I32] } else { results.is_empty() }) else {
        abort("unexpected wasmoon entry signature")
      }
      return Some(index)
    }
  }
  abort("missing requested export")
}

///|
fn invoke(instance : Instance, index : Int32?, expected : Int32?) -> Unit {
  let values = match index {
    Some(index) => instance.call(index)
    None => []
  }
  match (expected, values[:]) {
    (None, []) => ()
    (Some(value), [seen]) if value == seen.to_int() => ()
    _ => abort("unexpected wasmoon scalar result")
  }
}

///|
fn main raise {
  let args = @env.args()
  guard args.length() >= 11 && args.length() <= 17 else {
    abort(
      "expected SCHEDULE WINDOW BATCH WASI ENTRY RETURN STDOUT and 3 to 9 modules",
    )
  }
  let schedule = @fs.read_file_to_bytes(args[1])
  let hot = args[2] == "hot"
  let batch = @string.parse_int(args[3])
  guard batch > 0 && !(hot && args[5] == "-") else {
    abort("invalid batch or hot entry")
  }
  let wasi = args[4] == "1"
  let entry = args[5]
  let expected = if args[6] == "-" {
    None
  } else {
    Some(@string.parse_int(args[6]))
  }
  let stdout = @fs.read_file_to_bytes(args[7])
  let modules = []
  for i in 8..<args.length() {
    modules.push(prepare(args[i]))
  }
  let entries = modules.map(fn(module_) {
    entry_index(module_.module_, entry, expected is Some(_))
  })
  let instances = if hot {
    let instances = []
    for module_ in modules {
      instances.push(instantiate(module_, wasi))
    }
    instances
  } else {
    []
  }
  for instance in instances {
    instance.check(b"", 1)
  }
  for variant in schedule {
    let index = variant.to_int()
    guard index < modules.length() else { abort("invalid schedule variant") }
    let mut setup = 0L
    let mut execution = 0L
    if hot {
      let instance = instances[index]
      let start = now()
      for _ in 0..<batch {
        invoke(instance, entries[index], expected)
      }
      execution = now() - start
      instance.check(stdout, batch)
    } else {
      for _ in 0..<batch {
        let start = now()
        let instance = instantiate(modules[index], wasi)
        let ready = now()
        invoke(instance, entries[index], expected)
        let finished = now()
        setup += ready - start
        execution += finished - ready
        instance.check(stdout, 1)
        instance.close()
      }
    }
    println("sample \{index} \{setup} \{execution}")
  }
  for instance in instances {
    instance.close()
  }
}
