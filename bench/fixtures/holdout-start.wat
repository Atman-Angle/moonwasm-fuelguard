(module
  (func $step (param i32) (result i32) local.get 0 i32.const 11 i32.mul)
  (func $work (result i32) (local $n i32) (local $sum i32)
    i32.const 5379 local.set $n
    loop $loop
      local.get $sum local.get $n call $step i32.add local.set $sum
      local.get $n i32.const 1 i32.sub local.tee $n br_if $loop
    end
    local.get $sum)
  (start $init) (func $init call $work i32.const 159164610 i32.ne if unreachable end))
