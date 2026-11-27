///|
priv enum SessionState {
  Initializing
  Ready
  Running
  Closed
}

///|
priv enum InvocationResult {
  Returned(Array[Int64])
  Exited
}

///|
priv struct Session {
  linker : @runtime.Linker
  instance : @runtime.ModuleInstance
  compiled : @jit.JITModule
  references : @binding.FuncrefRegistration
  diagnostics : Diagnostics
  mut state : SessionState
}

///|
fn Session::close(self : Self) -> Unit {
  if self.state is Closed {
    return
  }
  self.state = Closed
  self.compiled.clear_hostcall_callback()
  self.references.release()
  self.compiled.close()
  self.linker.close()
}

///|
fn open_session(
  module_ : @types.Module,
  linker : @runtime.Linker,
  diagnostics : Diagnostics,
) -> Session raise RunError {
  let mut opened = false
  defer (if !opened { linker.close() })
  let store = linker.get_store()
  store.enable_c_heap() catch {
    error => raise RunError(@runner.HostError("native heap setup: \{error}"))
  }
  let instance = @executor.instantiate_module_with_imports_unstarted(
    store,
    module_,
    linker.build_imports(),
  ) catch {
    UnknownImport(_, _)
    | TypeMismatch
    | LinkError
    | LinkErrorDetail(_) as error =>
      raise RunError(@runner.InputError("linking imports: \{error}"))
    error => raise RunError(@runner.InitializationFailure(error.to_string()))
  }
  let (artifact, debug_db) = match
    @commands.compile_module_to_jit(
      module_,
      false,
      false,
      0,
      false,
      enable_cancellation=true,
    ) {
    Some(value) => value
    None => raise RunError(@runner.HostError("wasmoon JIT compilation failed"))
  }
  let compiled = try {
    let loaded = @commands.verify_compiled_jit_artifact(artifact)
    @jit.JITModule::load_artifact_with_imports(
      loaded,
      @binding.build_func_signatures(module_),
      @binding.build_external_imports_for_jit(module_, instance, store),
      function_names=@commands.build_jit_function_names(module_),
      debug_db~,
      resource_budget=store.resource_budget,
    )
  } catch {
    error => raise RunError(@runner.HostError("loading JIT artifact: \{error}"))
  }
  defer (if !opened { compiled.close() })
  if !compiled.configure_native_fiber_stack_size(FIBER_BYTES) {
    host_error("failed to configure the 16 MiB native Wasm fiber stack")
  }
  let references = @binding.register_owned_instance_funcrefs_for_jit(
    compiled, instance, store,
  ) catch {
    error =>
      raise RunError(@runner.HostError("binding JIT functions: \{error}"))
  }
  defer (if !opened { references.release() })
  try {
    ignore(@binding.init_jit_memories_from_store(instance, store, compiled))
    let globals = @binding.init_jit_globals_from_store(
      instance, store, compiled,
    )
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
  } catch {
    error => raise RunError(@runner.HostError("binding JIT instance: \{error}"))
  }
  opened = true
  { linker, instance, compiled, references, diagnostics, state: Initializing, }
}

///|
fn Session::read_diagnostic(self : Self, index : Int32) -> Int32? {
  let value = self.linker
    .get_store()
    .get_global(self.instance.global_addrs[index])
    .get() catch {
      _ => return None
    }
  match value {
    I32(n) => Some(n)
    _ => None
  }
}

///|
fn Session::diagnose(
  self : Self,
  trap : @jit.JITTrap,
  initializing : Bool,
) -> @runner.RunFailure {
  if initializing {
    return @runner.InitializationFailure(trap.to_string())
  }
  if !(trap is @jit.JITTrap::JITTrap(_)) {
    return @runner.ExecutionError(trap.to_string())
  }
  match
    (
      self.read_diagnostic(self.diagnostics.code),
      self.read_diagnostic(self.diagnostics.site),
    ) {
    (Some(code), Some(site)) =>
      @runner.diagnose_instance_trap(code, site, trap.to_string())
    _ => @runner.DiagnosticError("diagnostic-unavailable")
  }
}

///|
fn Session::execute(
  self : Self,
  index : Int32,
  args : Array[Int64],
  initializing : Bool,
  timeout_ms : Int32?,
  cancel : (() -> Bool)?,
) -> InvocationResult raise RunError {
  guard self.compiled.get_func(index) is Some(function) else {
    self.close()
    raise RunError(@runner.HostError("JIT function is unavailable: \{index}"))
  }
  let store = self.linker.get_store()
  self.state = Running
  store.begin_gc_tracing()
  let result = self.compiled.call_with_context_controlled(
    function,
    args,
    cancel~,
    timeout_ms~,
  )
  store.end_gc_tracing()
  let phase = if initializing { "start" } else { "invoke" }
  let failure : @runner.RunFailure = match result {
    Completed(values) => {
      self.state = Ready
      return Returned(values)
    }
    TimedOut => @runner.TimedOut(phase)
    Cancelled => @runner.Cancelled(phase)
    Failed(JITExit(status)) => {
      if status == 0 {
        self.close()
        return Exited
      }
      @runner.WasiExit(status)
    }
    Failed(JITUncaughtException(exception) as trap) => {
      exception.close()
      self.diagnose(trap, initializing)
    }
    Failed(trap) => self.diagnose(trap, initializing)
    UnsupportedCancellation | InvalidTimeout =>
      @runner.HostError("wasmoon rejected the configured execution controls")
  }
  self.close()
  raise RunError(failure)
}

///|
fn Session::initialize(
  self : Self,
  start : Int32?,
  timeout_ms : Int32?,
  cancel : (() -> Bool)?,
) -> InvocationResult raise RunError {
  guard self.state is Initializing else {
    raise RunError(@runner.HostError("invalid initialization state"))
  }
  if start is Some(index) {
    self.execute(index, [], true, timeout_ms, cancel)
  } else {
    self.state = Ready
    Returned([])
  }
}

///|
fn Session::invoke(
  self : Self,
  invocation : Invocation,
  timeout_ms : Int32?,
  cancel : (() -> Bool)?,
) -> InvocationResult raise RunError {
  match self.state {
    Ready =>
      self.execute(invocation.index, invocation.args, false, timeout_ms, cancel)
    Running =>
      raise RunError(@runner.HostError("reentrant invocation rejected"))
    Closed => raise RunError(@runner.HostError("instance discarded"))
    Initializing =>
      raise RunError(@runner.HostError("instance is not initialized"))
  }
}
