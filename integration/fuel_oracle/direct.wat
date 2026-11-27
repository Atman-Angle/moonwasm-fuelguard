(module
  (func $mul (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.mul
    return)
  (func (export "run") (result i32)
    i32.const 6
    i32.const 7
    call $mul
    return))
