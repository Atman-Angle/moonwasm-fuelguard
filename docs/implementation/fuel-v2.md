# Fuel v2 计费模型

静态权重和动态费用系数沿用无 SIMD 的 [Fuel v1](fuel-v1.md)
`fuel_v1_rule` 表。初始预算为 `[1, 2^63−1]`。

| 位置 | 划分规则 |
| --- | --- |
| 函数入口 | 从首条计费指令开始 |
| `if` | 指令本身计入当前 span。非空分支臂和汇合点各自开新 span。唯一落穿的显式 else 可与后续指令合并 |
| `loop` | 指令本身计入当前 span。循环体首条计费指令开新 span，回边重新预扣 |
| `block` | 顺序入口可合并。被分支引用的出口开新 span |
| `br`、`br_if`、`br_table`、`return`、`unreachable` | 计入当前 span 并结束它 |
| 调用、可陷阱操作、grow 和 bulk 操作 | 静态基本费用随当前 span 预扣。动态附加费用在原操作处扣除 |
| 其余静态指令 | 顺序合并，长度不设上限 |

站点按原指令先序编号，与原有 Stack 入口站点共用编号空间。`else`
和 `end` 不占站点。首次扣费失败时，共享 helper 接收 span 首条源指令
的站点，设置 code 1 后陷阱。动态费用或其溢出在原操作的站点报错。
多 span 函数用 i64 local 缓存余额，在调用、动态费用、可陷阱操作和
函数退出前按需同步，调用和动态扣费正常返回后重载。

## 静态扣费模板

- 缓存路径依次执行 `local.get balance / i64.const W / i64.sub /
  local.tee balance / i64.const 0 / i64.lt_s / if`。
- 全局路径使用 `global.get fuel` 读取余额，减去 W 后通过
  `global.set fuel / global.get fuel` 写回并读取扣后余额，再判断符号。
- 负余额分支为 `i32.const first_site / call failure`。共享 helper 的签名为
  `(i32) -> ()`，依次写入 code 1、首站点并执行 `unreachable`。

W 是 span 内静态权重之和。每条指令最多计 8，站点计数受 Int32 约束，
因此 W 在 i64 范围内。Wasm 用有符号 LEB128 编码 `i64.const W`，
正数跨过 63 和 8,191 时分别增至 2 和 3 个立即数字节。预算和 W
均在非负 i64 范围内，减法结果可表示，负数表示预扣失败。

## 选择与迁移

使用 `--cost-model fuel-v2`，或在库中选择 `CodegenLayout::FuelV2`。
产物 marker 和 manifest 记录 `fuel-v2` 与 `fuel-v2-inline-v1`。
从未插桩的原件重建 Wasm 和 manifest。已有 `fuel-v1` 与 `fuel-v1.2`
产物继续按各自 marker 解释。

`fuel-v1.2` 的 19 条上限和动态操作前后切分会增加 span 数。其静态失败
诊断回放权重 profile 来定位首条不可支付指令。`fuel-v2` 的静态失败
定位到入口预扣所在的 span 首条指令。动态附加费失败仍定位到原操作。

[模型指纹](fuel-v2.sha256) 为 `cost_model.mbt`、`join_fuel.mbt` 和
本页内容按顺序用 NUL 分隔后计算的 SHA-256，采用 UTF-8 和 LF。
旧模型指纹保留用于复现兼容布局的费用表。
运行 `python -B -m unittest integration.fuel_oracle.test_fingerprint`
验证当前指纹。
