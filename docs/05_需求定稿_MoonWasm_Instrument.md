# MoonWasm Instrument 需求定稿

> 状态：v2，已按 2026-11-01 对抗审计更新；宿主可行性待后台审计确认
> 日期：2026-11-01
> 定位：MoonBit WASM 的运行时控制层
> 关联：`03_MoonBit_黑客松_立项调研报告_2026-11.md`；`04_项目申报书_MoonWasm_Instrument.md`（草稿，最终版另写）

## 0. 一句话

在构建时给 MoonBit `--target wasm` 产物注入 fuel 和资源限制，使模块在任何标准 WASM 宿主上自带预算并能确定性 trap；宿主不需要实现 fuel。

## 1. 项目目标

### 1.1 目标

把一个普通的 MoonBit WASM 模块变成“自带运行时契约”的模块：

- 模块内部维护 fuel 预算，函数入口和循环迭代按固定规则扣费；
- 预算耗尽时在确定位置 `unreachable`，并留下可读的 trap 原因；
- `memory.grow` / `table.grow` 受上限约束，超限确定性失败；
- 插桩不新增 import，只新增内部 global/function 和一个只读诊断导出；
- 同一份插桩模块可以被任何标准 WASM 宿主加载；不要求宿主提供 fuel、budget 或 guard API。

Pass API 和 CLI 是目标的实现与使用方式，不是目标本身。

### 1.2 首要成功标准

1. 一个真实的 MoonBit `moon build --target wasm` 模块（含循环和 `memory.grow`）插桩后，在 wasmoon 上按配置的 fuel 在固定点 trap，重复运行结果一致。
2. 同一个模块用不同 fuel 预算插桩，trap 点随预算单调变化；预算足够时正常完成，输出与原始模块一致。
3. `memory.grow` / `table.grow` 超过配置上限时确定性失败；初始内存/表已超上限时在插桩阶段拒绝。
4. 至少 30 个确定性模块/用例、10 个控制流边界完成原/插桩差分；非 fuel/guard 用例无输出或返回值差异。
5. 一个挂起的 MoonBit wasm 测试能在固定 fuel 点 trap，CI 以非零码失败，并给出可复现的预算/输入。
6. 插桩后的模块通过 starshine `validate_module`；每个 pass 后都校验，编码前再校验。
7. 若宿主审计确认 wasm5 可用：至少 10 个无 import 用例的同一插桩模块在 wasm5 上运行，fuel/trap 语义与 wasmoon 一致；若不可用，不承诺跨宿主实测，只保留设计属性。

### 1.3 不追求

- 不追求逐指令 gas、与 Wasmtime/Wasmer 的 gas 等价；
- 不追求完整沙箱或安全边界；Guard 是资源限制，不是安全隔离；
- 不追求函数级 call trace、调用序列、火焰图 profiling；
- 不追求 wasm-gc、component model、多模块链接；
- 不追求运行期修改预算（fuel 在插桩时写入）；
- 不追求浏览器/wasmtime 的实测适配。

## 2. 范围

### 2.1 首月交付

| 项 | 内容 | 验收方式 |
|---|---|---|
| FuelPass | 函数入口 + 循环体首扣费；mutable global；超限 trap；固定预算 | 真实 MoonBit wasm 上 trap 点可复现 |
| GuardPass | `memory.grow` / `table.grow` 上限；import allowlist | 超限 trap；不允许的 import 在插桩阶段拒绝 |
| Pass API + pipeline | 公开 Pass 接口；确定性顺序；每个 pass 后 validate | 第三方 pass 可插入；非法输出被拒绝 |
| wasmoon 主适配 | 跑标准 MoonBit wasm（WASI）；报告 trap | 正常输出与原模块一致；trap 原因可报告 |
| wasm5 验证宿主 | 只跑无 import 模块；不做 WASI | **待定**：公共 API 需 vendor/CLI；宿主审计后决定是否保留 |
| CLI | `instrument`、`run` | 一条命令完成插桩；一条命令运行并报告 trap |
| 差分/验证 | ≥30 确定性用例，≥10 控制流边界 | 0 个未解释差异；例外有最小化记录 |
| 主要场景 | CI/模糊测试 | 挂起测试在固定 fuel 点 trap，失败可复现 |

> wasm5 是验证宿主，不是公开适配承诺。公共包目前只 re-export 类型别名和 `parse`，`Instance::new` 在 internal/runtime；若不能以 vendor 或 CLI 方式干净使用，就放弃 wasm5 验证，不伪造“跨宿主”证据。

### 2.2 明确不做

- TracePass、调用序列、函数/循环计数导出、profiling；
- 运行期 fuel set/get（只读 trap code 除外）；
- wasmtime、浏览器实测；
- wasm-gc、component model、多模块链接；
- stack-height guard；
- 完整沙箱、安全隔离；
- 源码覆盖（moon_cove）、WASM parser/optimizer（starshine）、通用 inspect（moonbit-wasm-inspect）、WAT 转换（wasmtools）；
- UI、托管服务、JSON 配置文件（首月只用 CLI 参数）。

> wasm-gc 是“范围外”，不是“技术上不可能”：starshine 已能对一个简单 GC 模块完成 decode/validate/encode/插桩；但宿主支持（wasm5 不支持 GC）和更广的测试矩阵未验证，首月不承诺。

## 3. 功能语义

### 3.1 输入边界

- 输入：`moon build --target wasm` 生成的 `.wasm`；非 GC、线性内存；允许 MoonBit 实际产出的 post-MVP 特性（bulk memory、multi-value、reference types、SIMD）。
- 拒绝：wasm-gc、component model、多模块、多个 memory/table、无法被 starshine 解码或无法通过 validate 的模块。
- 拒绝必须是明确错误，不能静默输出一个可能损坏的模块。
- 首月只处理“一个 memory、一个 table”的模块；超过则报错。
- 不要求输出与输入 byte-identical：starshine 的 encode 会 canonicalize（例如 8,366 → 8,340 字节），第二次 encode 才幂等；验收只要求 validate + 语义一致。

**已实测的实现约束（starshine 0.3.0）**：

- `Module` 是只读 record，必须通过 `Module::with_*` 重建 section；
- 枚举值是 read-only，要用 `Instruction::global_get` 等命名 helper，不能直接构造 `GlobalGet`；
- `Expr.0` 是 mutable array，浅拷贝共享底层数组；pass 必须复制数组或走重建器，不能原地改源模块；
- 函数/global 索引空间包含 import；计算新索引时要加 imported 数量；
- `encode_module` 不自动 validate，必须显式调用 `validate_module`。

### 3.2 FuelPass

- 每个**已定义函数**入口扣 1 单位；每个 `Loop` 体开始扣 1 单位（包括第一次进入和每次 continue）。
- 导入函数没有函数体，不扣费；宿主函数的执行时间不计入 fuel。
- 总预算在插桩时写入一个 i32 mutable global；预算必须 > 0，超过 i32 上限则报错。
- 扣费顺序：先减 1，再检查剩余是否 < 0；若不足，先写 trap code，再执行 `unreachable`。
- 不按函数/循环配置权重；不按基本块/指令计费；不做运行期重设。
- 内置顺序是 **FuelPass → GuardPass**；GuardPass 追加的 helper 不扣 fuel。
- 同一模块、同一输入、同一预算，trap 点必须一致；不同预算的 trap 点必须可复现。
- Fuel 只约束被插桩的函数体；宿主 import 的副作用、宿主侧等待时间不在 fuel 范围内。

### 3.3 GuardPass

- `memory.grow`：改写为 helper；若 `delta < 0` 或 `current_pages + delta > max_memory_pages`，写 trap code 2 并 `unreachable`；否则调用原 `memory.grow` 并返回结果。
- `table.grow`：改写为 helper；若 `delta < 0` 或 `current_elements + delta > max_table_elements`，写 trap code 3 并 `unreachable`；否则调用原 `table.grow` 并返回结果。
- 上限由插桩参数给出；未给某项上限时，该项不设 guard。
- 模块初始内存/表已超过配置上限时，插桩阶段直接拒绝。
- `--allow-import module.name` 可重复；提供时，任何不在列表中的 import（func/memory/table/global）在插桩阶段拒绝；未提供时不过滤。精确匹配，不支持通配符；未被任何 import 使用的 allowlist 项给 warning。
- 语义变化要写进 README：超过上限时不再返回 `-1`，而是 trap。需要 `-1` 语义的模块不使用 GuardPass，或后续加兼容模式。
- Guard 不限制初始内存内的写入、不限制宿主 import、不限制未被插桩的代码；它不是安全沙箱。

### 3.4 Trap code 与报告

- 新增一个只读导出（getter 函数或导出 global，二选一，架构阶段定）：
  - `0`：无 guard/fuel trap；
  - `1`：fuel 耗尽；
  - `2`：memory guard；
  - `3`：table guard。
- 若发生 trap 且 code 为 0，`run` 报告为“模块自身 trap”。
- CLI `run` 输出 trap 原因并以非零码退出；正常完成输出结果并退出 0。
- **已验证**：wasmoon 0.18.0 在 trap 后不会污染 store/instance，仍能读导出 global、调用 getter、继续调用其他 export；`call_exported_func_with_options` 的结构化失败能区分 `Trap` / `TimedOut` / `Cancelled` / `UnsupportedOption`。wasm5 0.1.1 在 trap 后也能读/写导出 global。trap code 功能不再标为待验证。
- **注意**：wasm5 的公共 API 不暴露 `Instance::new`；若保留 wasm5 验证，需要 vendor 或改用 CLI，具体待宿主审计。

### 3.5 Pass API 与 pipeline

- 公开 Pass 接口；内置 pipeline 顺序固定为 `FuelPass → GuardPass`；第三方 pass 可以通过库 API 插入。
- 每个 pass 输入/输出都是完整 `Module`；pipeline 在每个 pass 后调用 `validate_module`，失败立即中止并报错。
- `encode_module` 只负责编码；编码前必须再 validate 一次，不能依赖 encode 自校验。
- 首月内置 pass 只做“改写现有函数体 / 追加 global / 末尾追加函数”：
  - 不新增 import；
  - 不改变既有函数/global/type 索引；
  - 不实现通用索引重映射。
- 第三方 pass 如果新增 import 或改变既有索引，不在首月验收范围；文档要明确这是扩展点，不是已交付能力。
- starshine 0.3.0 的 `Module` 是只读 record，pass 必须通过 `Module::with_*` 重建 section；不允许原地改数组导致 section 不一致。

### 3.6 宿主

- **wasmoon 0.18.0（主适配，待 Windows 构建确认）**：加载标准 MoonBit `--target wasm` 模块，注册 WASI（`@wasi.register_wasi` / `WasiContextBuilder::inherit_stdout`），调用 `_start` 或导出函数；捕获 trap 并读取 trap code。当前已知风险：wasmoon CLI 是 native-only，Windows/MSVC 构建出现 undefined `*_msvc_guest` 符号；若不能在 Windows 原生跑通，需改用 WSL/Linux、clang/prebuilt 或替代宿主，架构前必须定。
- **wasm5 0.1.1（验证宿主，待公共 API 确认）**：只加载无 import 模块；用库 API 实例化、调用导出、读 global/memory；不做 WASI，不承诺公共适配。公共包只 re-export 类型别名和 `parse`，`Instance::new` 在 internal/runtime；可行路径只有 vendor、CLI（spectest、无 WASI）或放弃。若放弃，不承诺跨宿主实测。
- **wasmtime / 浏览器**：首月不安装、不适配、不承诺；申报书不能写“已验证”。
- “任何宿主”精确表述：**任何标准 WASM 宿主；插桩不新增 import，只新增内部 global/function 和一个只读诊断导出**。首月实测范围以宿主审计结果为准。

### 3.7 CLI

`instrument`：

```text
moonx Atman-Angle/moonwasm-instrument instrument <in.wasm> -o <out.wasm> \
  --fuel <N> \
  [--max-memory-pages <N>] \
  [--max-table-elements <N>] \
  [--allow-import <module.name>]...
```

- 输出插桩后的 `.wasm`；成功时打印摘要：预算、内存/表上限、允许的 import、插桩的函数数/循环数、pass 顺序。
- 任何 pass 失败、validate 失败、输入不支持，均以非零码退出，不写出半成品。

`run`：

```text
moonx Atman-Angle/moonwasm-instrument run <in.wasm>
moonx Atman-Angle/moonwasm-instrument run <in.wasm> --invoke <export>
```

- 默认执行 `_start`；`--invoke` 只支持无参导出函数（带参数的调用由测试 harness 直接使用 wasmoon API）。
- 使用 wasmoon（宿主待确认）；继承 stdout；报告 trap 原因；非零码退出。
- 不提供通用 `inspect`；不做 WAT 输入输出；不做 JSON 配置。

### 3.8 差分与验证

- 每个输出模块必须通过 `validate_module`。
- 语料：≥30 个**确定性**模块/用例；≥10 个控制流边界。以 MoonBit `--target wasm` 产物为主，允许少量预编译 wasm fixture 覆盖 br_table / call_indirect 等 MoonBit 不常生成的形态；不引入 WAT 解析依赖。
- **确定性边界**：差分语料不使用 WASI clock/random/network/env 等非确定输入；这些模块仍然可以被插桩，但不进入差分对照。若将来要覆盖，必须提供固定 host stub。
- 非 fuel/guard 用例：原/插桩模块在 wasmoon 上的 stdout、返回值、正常 trap 一致；0 个未解释差异。
- Fuel/guard 用例：按 trap code 对照；预算不足/超限必须按预期 trap；预算足够时输出一致。
- fuel trap 发生在输出中途时，只比较 trap code 和已确定的前缀，不做逐字节全量比较。
- wasm5 子集（若保留）：≥10 个无 import 用例，同一插桩模块在 wasm5 上运行，fuel/trap 语义与 wasmoon 一致。
- 记录 fuel-only 的运行开销和代码体积变化，写进 README/验收报告；**软目标 ≤3x**（固定 benchmark）。超过 3x 必须解释根因并尝试优化，但不阻塞交付；首月不设硬门槛。

### 3.9 打包与许可证

- 发布 `Atman-Angle/moonwasm-instrument` 到 mooncakes；库可通过 `moon add` 使用；CLI 可通过 `moonx` 运行。
- 本项目 Apache-2.0；`NOTICE` / `THIRD_PARTY` 记录 starshine、wasmoon、wasm5 及参考项目。
- starshine 0.3.0 的许可证是混合的：原始代码 MIT，MoonBit 模块/Binaryen 衍生部分 Apache-2.0；以其 LICENSE/NOTICE 为准，不能只看 `moon.mod` 的 license 字段。
- 不复制 paritytech/wasm-instrument、Binaryen、Wasmtime/Wasmer 的代码；只参考思路。

## 4. 差异与技术深度

### 4.1 对外一句话

**不是 gas 算法，也不是宿主 budget；插桩不新增 import，标准 WASM 宿主都能加载；原模块能跑的宿主，插桩后仍能跑。**

### 4.2 技术深度主句

产品差异是“可移植运行时契约”；技术深度落在四件事：

1. 安全改写：在只读、结构化的 starshine AST 上注入/改写，不破坏 section 一致性和既有索引；
2. 正确性：每个 pass 后 validate，encode 前再 validate；
3. 差分：真实 MoonBit wasm + 控制流边界 + 确定性语料，证明语义不变；
4. trap 语义：fuel/memory/table/module trap 可区分、可复现，跨 trap 后仍可读取。

不把“Pass 框架”或“fuel 成本模型”当成技术深度主句；它们是实现手段，不是差异本身。

### 4.3 需求证据

- **CI/模糊测试（主场景，证据最强）**：`moon test` 没有 timeout/fuel 参数（`--limit` 是 expect-test 更新次数）；`moon_cove` 是覆盖率报告，不是 fuzzer；`moonrun` 是 V8-based；wasm5/wasmoon 都没有 budget API。一个挂起的 wasm 测试会卡住 CI，这是真实、可检查的缺口。
- **Agent/插件（示例，需求存在但燃料需求未验证）**：`tuya-me/aegisrun` 确实跑 WASM，但核心是 wasmtime WASI 沙箱，资源限制是策略式的；Golem 1.5 有 MoonBit 支持，但预算由平台负责；没有证据表明它们需要“模块内 fuel”。
- **Serverless 构建时预算（示例，证据最弱）**：CPU 限制通常由平台强制，MoonBit 工具链没有钩子。
- **MoonBit 生态缺口**：2026-10-31 的 mooncakes 索引（921 owners / 3,509 packages）没有 fuel/metering/tracing/memory-table-guard 包；相邻的是 `moonbit-wasm-inspect`、`moonsize`、`wasmslim`、`wasmtools`、`wasm_core`、`wasm5`、`wasmoon`。没有直接竞品。
- **宿主现状**：wasmoon 有 safepoint cancellation/timeout/budget，但 `fuel`/`budget` 选项明确 `UnsupportedOption`；wasm5 没有 fuel/metering；starshine 没有 instrumentation pass；Rust/C++ 工具无法以纯 MoonBit 嵌进 MoonBit 工具链/浏览器/CI。

### 4.4 不声称

- 不声称“跨宿主已验证”，除非 wasmoon + wasm5 无 import 子集都完成实测；
- 不声称浏览器可用；
- 不声称支持 wasm-gc/component/多模块；
- 不声称 Guard 是安全沙箱；
- 不声称与 Wasmtime gas 等价；
- 不声称输出 byte-identical。

## 5. 三个完整使用场景

### 5.1 CI / 模糊测试（主场景）

- **谁**：维护 MoonBit WASM 库的 CI 或 fuzz 流程。
- **输入**：库的 `--target wasm` 产物 + 一组确定性测试输入/种子。
- **插桩**：固定 fuel 和 memory/table 上限；不使用 import allowlist（测试模块可能依赖 WASI）。
- **宿主**：wasmoon（待 Windows 构建确认）；无 import 子集可在 wasm5 上跑（若保留）。
- **成功**：正常输入输出一致；死循环/失控内存增长在固定点 trap，失败可复现；记录最小 fuel 预算或复现命令。
- **失败/边界**：moon_cove 继续负责源码覆盖；本工具补的是确定性执行边界，不替代覆盖率和语义断言。

### 5.2 Agent / 插件资源预算（示例，不是安全沙箱）

- **谁**：运行第三方 MoonBit WASM 工具/插件的 Agent 平台或宿主。
- **输入**：插件构建产物 `plugin.wasm`，以及一份插件声明的 import 列表。
- **插桩**：`instrument plugin.wasm -o plugin.guarded.wasm --fuel 5000000 --max-memory-pages 64 --max-table-elements 1024 --allow-import wasi_snapshot_preview1.fd_write`。
- **宿主**：wasmoon；宿主只负责加载、调用、捕获 trap，不实现 fuel。
- **成功**：正常输入返回结果；插件死循环在固定 fuel 点 trap（code 1）；插件申请超过 64 页时 trap（code 2）；不在 allowlist 的 import 在插桩阶段被拒绝。
- **失败/边界**：宿主仍需自己隔离崩溃、限制墙钟时间、限制文件/网络副作用；Guard 不是安全沙箱。该场景是“资源预算”，不是“安全隔离”。

### 5.3 Serverless 构建时预算

- **谁**：希望在构建期给 MoonBit 函数设定资源档位的 Serverless/边缘平台。
- **输入**：每个函数档位的 wasm 产物。
- **插桩**：按档位在构建时写固定 fuel 和 memory/table 上限；不按请求动态改预算。
- **宿主**：wasmoon（待确认）。
- **成功**：同一档位的函数在任何时候运行都在同一预算点 trap；超预算作为配额/告警信号；换宿主不需要重写宿主 fuel 逻辑。
- **失败/边界**：首月没有运行期 set/get；按请求动态预算需要为每个档位重新插桩，或后续加 setter。该场景证据最弱，作为示例而非主场景。

> profiling 不作为首月场景；它依赖 Trace，已出局。

## 6. 验收清单

- [ ] `Atman-Angle/moonwasm-instrument` 在 mooncakes 可 `moon add`；CLI 可 `moonx`。
- [ ] 真实 MoonBit `--target wasm` 模块可被 `instrument` 处理，输出通过 validate；不要求 byte-identical。
- [ ] Fuel：固定预算 trap 点可复现；不同预算 trap 点单调变化；预算足够时输出一致。
- [ ] Guard：memory/table 超限 trap code 正确；初始超限拒绝；allowlist 在插桩阶段生效。
- [ ] Trap code：`run` 能区分 fuel / memory / table / 模块自身 trap（wasmoon/wasm5 的 trap 后读取已验证）。
- [ ] 差分：≥30 个确定性用例、≥10 个控制流边界、0 未解释差异；clock/random/network 不在差分范围。
- [ ] 主场景 demo：一个挂起的 MoonBit wasm 测试在固定 fuel 点 trap，CI 非零码失败，并给出复现命令。
- [ ] wasm5：若宿主审计确认可用，≥10 个无 import 用例语义一致；若不可用，删除该项，不声称跨宿主实测。
- [ ] CLI 摘要、错误信息、README、demo 可复现。
- [ ] 记录 fuel-only 开销与体积变化；软目标 ≤3x，超过必须解释并尝试优化。
- [ ] Apache-2.0 + NOTICE/THIRD_PARTY；starshine 混合许可证说明正确。
- [ ] 不出现 trace / wasmtime / wasm-gc / 浏览器 / 安全沙箱 / “跨宿主已验证”的过度承诺。

## 7. 待验证 / 待补

| 项 | 为什么 | 何时处理 |
|---|---|---|
| wasmoon 能否在 Windows 原生构建/运行 | CLI 是 native-only；MSVC 链接失败会挡住主适配和 demo | 架构前，宿主审计 |
| wasm5 公共 API / CLI 是否可支持验证宿主 | `Instance::new` 在 internal/runtime；否则只能 vendor 或放弃 | 架构前，宿主审计 |
| wasm5 无 import 子集的 trap 语义（若保留） | 决定“第二个宿主”证据强度 | 实现后验证 |
| Fuel/Guard 的开销与体积 | 决定 README 的性能表述和是否触发优化 | 实现后测量 |
| 11 月赛截止时间、提交次数 | 决定 10 个 commit 的最晚开始时间 | 用户从微信通知补充 |
| 仓库当前 404 | 申报前置条件 | 需求确认后创建 |
| starshine 0.3.0 API 稳定性 | 版本很新；encode 会 canonicalize；无公开 remapper | 架构时 pin 版本 |

> 已从风险表移除：wasmoon/wasm5 的 trap 后 global 读取（已验证）；starshine 真实 MoonBit wasm 往返（已验证）。wasm-gc 的简单模块往返也能跑，但仍是范围外，不是技术不可能。

## 8. 下一步

1. 确认这份需求 v2（目标、范围、语义、差异、场景、验收）。
2. 等宿主审计结论：wasmoon Windows 构建路径、wasm5 公共 API/CLI；若两者都不可用，先决定替代宿主，再进入架构。
3. 进入架构设计：模块边界、Pass API、trap code 机制、CLI/host 接口、测试矩阵。架构单独评审，不先写代码。
4. 架构确认后再创建公开仓库、完成 ≥10 个有意义的 commit，再提交申报。
5. 申报书最终版按这份需求重写；当前 `04_项目申报书_MoonWasm_Instrument.md` 只作草稿。
