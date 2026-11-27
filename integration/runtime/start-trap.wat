(module
  (global (export "__moonwasm_trap_code") (mut i32) (i32.const 0))
  (func $initialize unreachable)
  (start $initialize)
  (func (export "answer") (result i32) i32.const 42))
