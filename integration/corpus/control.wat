(module
  (type $unary (func (param i32) (result i32)))
  (table 4 4 funcref)
  (global $trace (export "trace") (mut i32) (i32.const 0))
  (func $boot i32.const 42 global.set $trace)
  (start $boot)
  (func (export "branch") (param i32) (result i32)
    local.get 0 if (result i32) i32.const 7 else i32.const 11 end)
  (func (export "switch") (param i32) (result i32)
    block $default
      block $one
        block $zero
          local.get 0 br_table $zero $one $default
        end
        i32.const 10 return
      end
      i32.const 20 return
    end
    i32.const 30)
  (func (export "nested") (param i32 i32) (result i32) (local $i i32) (local $total i32)
    block $done
      loop $outer
        local.get 0 i32.eqz br_if $done
        local.get 1 local.set $i
        block $row_done
          loop $inner
            local.get $i i32.eqz br_if $row_done
            local.get $total local.get $i i32.add local.set $total
            local.get $i i32.const 1 i32.sub local.set $i
            br $inner
          end
        end
        local.get 0 i32.const 1 i32.sub local.set 0
        br $outer
      end
    end
    local.get $total)
  (func $even (export "even") (type $unary)
    local.get 0 i32.eqz if i32.const 1 return end
    local.get 0 i32.const 1 i32.sub call $odd)
  (func $odd (export "odd") (type $unary)
    local.get 0 i32.eqz if i32.const 0 return end
    local.get 0 i32.const 1 i32.sub call $even)
  (elem (i32.const 0) func $even $odd $boot)
  (func (export "indirect") (param i32 i32) (result i32)
    local.get 0 local.get 1 call_indirect (type $unary))
  (func $pair (export "pair") (export "pair_alias") (param i32) (result i32 i64)
    local.get 0 i64.const -7 return)
  (func (export "call_pair") (param i32) (result i32 i64)
    local.get 0 call $pair)
  (func (export "typed_branch") (param i32) (result i32 i64)
    block (result i32 i64)
      i32.const 17 i64.const 19 local.get 0 br_if 0
      drop drop i32.const 23 i64.const 29
    end))
