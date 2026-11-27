(module
  (global $diagnostic (export "__moonwasm_trap_code") i32 (i32.const 0))
  (func (export "answer") (result i32) i32.const 42)
  (func (export "read_diagnostic") (result i32) global.get $diagnostic))
