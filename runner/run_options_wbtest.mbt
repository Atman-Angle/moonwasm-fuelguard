///|
test "fuel trap code is diagnosed" {
  let failure = match diagnose_trap_code(1) {
    Ok(failure) => failure
    Err(_) => abort("valid trap code")
  }
  assert_eq(failure.exit_code(), 1)
  assert_eq(failure.describe(), "fuel exhausted")
}

///|
test "zero trap code is a module trap" {
  let failure = match diagnose_trap_code(0) {
    Ok(failure) => failure
    Err(_) => abort("valid trap code")
  }
  assert_eq(failure.exit_code(), 1)
  assert_eq(failure.describe(), "module trap")
}

///|
test "unknown trap code is rejected" {
  assert_true(diagnose_trap_code(7) is Err(_))
}

///|
test "host and input failures use exit code two" {
  assert_eq(HostError("missing wasmoon").exit_code(), 2)
  assert_eq(InputError("missing input").exit_code(), 2)
}
