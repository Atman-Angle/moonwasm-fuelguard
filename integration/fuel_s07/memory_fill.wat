(module
  (memory 1)
  (type $fill (func (param i32 i32 i32) (result i32)))
  (func $fill (type $fill)
    local.get 0
    local.get 1
    local.get 2
    memory.fill
    i32.const 7)
  (export "fill" (func $fill)))
