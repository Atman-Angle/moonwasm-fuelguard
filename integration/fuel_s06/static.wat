(module
  (type $result (func (result i32)))
  (func $run (type $result)
    i32.const 40
    i32.const 2
    i32.add)
  (export "run" (func $run)))
