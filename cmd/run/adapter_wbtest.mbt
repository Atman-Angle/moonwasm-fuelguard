///|
fn generated_module(
  wat : String,
  fuel : Int64,
  allow : Array[String],
) -> @types.Module raise {
  let source = @encoder.encode(@wat.parse(wat)).map(fn(n) { n.to_byte() })
  let input = @instrument.decode_wasm(Bytes::from_array(source)).unwrap()
  let config = @instrument.InstrumentConfig::new(
    @instrument.FuelConfig::new(fuel).unwrap(),
    @instrument.GuardConfig::new(allowed_imports=allow).unwrap(),
    stack=Some(@instrument.StackConfig::new(10_000L, 4L).unwrap()),
  )
  let protected_module = @instrument.Pipeline::builtin(config)
    .run(input)
    .unwrap()
  wasmoon_module(@instrument.encode_wasm(protected_module.output()).unwrap())
}

///|
fn Session::scalar(self : Self, call : Invocation) -> Int64 raise {
  guard self.invoke(call, None, None) is Returned([value]) else {
    fail("expected one scalar result")
  }
  value
}

///|
test "one live JIT instance keeps fuel and closes its Store after a trap" {
  check_environment()
  let module_ = generated_module(
    "(module (global $n (mut i32) (i32.const 0)) (func (export \"step\") (result i32) global.get $n i32.const 1 i32.add global.set $n global.get $n))",
    12L,
    [],
  )
  let call = invocation(module_, "step", [])
  let linker = @runtime.Linker::Linker()
  let store = linker.get_store()
  let session = open_session(module_, linker, artifact_diagnostics(module_))
  defer session.close()
  ignore(session.initialize(module_.start, None, None))
  assert_eq(session.scalar(call), 1L)
  assert_eq(session.scalar(call), 2L)
  assert_false(store.is_closed())
  let trapped = try session.invoke(call, None, None) catch {
    RunError(error) => error.describe()
  } noraise {
    _ => fail("fuel should be exhausted")
  }
  assert_eq(trapped, "resource-trap code=1 site=2: fuel exhausted")
  assert_true(store.is_closed())
  let discarded = try session.invoke(call, None, None) catch {
    RunError(error) => error.describe()
  } noraise {
    _ => fail("discarded instance was reused")
  }
  assert_eq(discarded, "host error: instance discarded")
}

///|
test "actual guest import cannot reenter its active session" {
  check_environment()
  let module_ = generated_module(
    "(module (import \"test\" \"reenter\" (func $callback)) (func (export \"inner\") (result i32) i32.const 42) (func (export \"outer\") (result i32) i32.const 1 if call $callback end i32.const 7))",
    100L,
    ["test.reenter"],
  )
  let owner : Ref[Session?] = Ref(None)
  let reentry_error = Ref("")
  let inner = invocation(module_, "inner", [])
  let outer = invocation(module_, "outer", [])
  let linker = @runtime.Linker::Linker()
  linker.add_host_func(
    "test",
    "reenter",
    fn(_) {
      guard owner.val is Some(active) else { abort("test session not set") }
      try {
        ignore(active.invoke(inner, None, None))
        reentry_error.val = "incorrectly allowed"
      } catch {
        RunError(error) => reentry_error.val = error.describe()
      }
      []
    },
    func_type=module_.func_type_at(0).unwrap(),
  )
  let session = open_session(module_, linker, artifact_diagnostics(module_))
  defer session.close()
  owner.val = Some(session)
  ignore(session.initialize(module_.start, None, None))
  assert_eq(session.scalar(outer), 7L)
  assert_eq(reentry_error.val, "host error: reentrant invocation rejected")
  assert_eq(session.scalar(inner), 42L)
}

///|
test "Fuel v2 keeps startup and subsequent invocation fuel in one JIT instance" {
  check_environment()
  let module_ = generated_module(
    "(module (func $boot i32.const 1 if nop end) (start $boot) (func (export \"step\") (result i32) i32.const 1 if nop end i32.const 17))",
    11L,
    [],
  )
  let call = invocation(module_, "step", [])
  let linker = @runtime.Linker::Linker()
  let store = linker.get_store()
  let session = open_session(module_, linker, artifact_diagnostics(module_))
  defer session.close()
  ignore(session.initialize(module_.start, None, None))
  assert_eq(session.scalar(call), 17L)
  assert_eq(session.scalar(call), 17L)
  let trapped = try session.invoke(call, None, None) catch {
    RunError(error) => error.describe()
  } noraise {
    _ => fail("core start and two invocations consume the entire budget")
  }
  assert_eq(trapped, "resource-trap code=1 site=6: fuel exhausted")
  assert_true(store.is_closed())
}
