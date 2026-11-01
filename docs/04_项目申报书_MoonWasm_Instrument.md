# MoonWasm Instrument 项目申报书

#### 基本信息

- 项目名称：MoonWasm Instrument
- 参赛者：[姓名]
- 联系方式：[微信/邮箱]
- GitHub 仓库链接：https://github.com/Atman-Angle/moonwasm-instrument （申报时含不少于 10 个有效 commit）
- 项目方向：MoonBit WASM 运行时基础设施 / 开发者工具；通用性：任何 MoonBit 生成的 WASM 与 wasm5/wasmoon/wasmtime/浏览器宿主可用，Pass 框架可扩展。
- 是否为移植项目：否（原创；参考已有插桩实现，使用 starshine 作为解析/编码依赖）

#### 项目简介

MoonWasm Instrument 是纯 MoonBit 的 WASM 二进制插桩框架：输入 `moon build --target wasm` 的模块，输出带 fuel/budget、call trace、内存/表/导入守卫的模块，并提供统一宿主 ABI 与 wasm5/wasmoon/wasmtime 适配。它不重写 WASM parser，也不重复 moon_cove 的源码覆盖；补的是 starshine（解析/编码）与宿主之间的运行时控制层。

**痛点与生态位**：MoonBit 的主输出是 WASM，但 wasm5 没有 fuel/metering；wasmoon 有宿主特定的 cancellation/timeout/budget；starshine 有 parse/validate/optimize/encode 和 pass 框架，却没有 instrumentation pass；moon_cove 只做源码探针覆盖，不保留控制流边。Agent/边缘/插件宿主只能自己写宿主预算，或依赖 Rust/C++ 工具（paritytech/wasm-instrument、Binaryen、Wasmtime/Wasmer），无法在 MoonBit 工具链/浏览器/CI 里以纯 MoonBit 完成。MoonBit 正在推 WASM/Agent/边缘，但“能编译 WASM”和“能安全运行/计量 WASM”之间还缺这一层。

**竞品与优势**：优势不是发明 gas 算法，而是纯 MoonBit、宿主无关的 Pass 框架 + wasm5/wasmoon 集成 + tracing/guards。MoonBit 侧未发现直接提供通用 WASM 插桩的包；相邻的 starshine/wite/wasm5/wasmoon/moon_cove 分别覆盖 parser/静态分析/VM/runtime/源码覆盖。只做 fuel 就是移植；做 Pass 框架 + guards/tracing 才是独立项目。

#### 预期使用场景

1. **Agent / 插件沙箱**：宿主运行不可信 MoonBit/WASM 工具，插 fuel + 内存/表/导入守卫；超预算 trap 并记录 trace/audit；不依赖宿主内置 fuel。
2. **边缘 / Serverless 计费**：构建或部署时插桩；同一模块在 wasm5/wasmtime 上按同一预算模型限额/计费，避免运行时锁定。
3. **WASM 测试 / 模糊测试 / CI**：对 MoonBit wasm 插桩，记录函数/循环计数与运行时边覆盖；moon_cove 负责源码覆盖，本工具补确定性计数/边覆盖，接 CI 阈值。
4. **运行时 profiling**：函数/循环计数与 call trace，输出可喂火焰图的数据，定位热路径。

#### 核心功能范围

- **Pass 管线 + 公开 Pass API**：`decode → pass → validate → encode`，确定性顺序；第三方可写自己的 pass；库 + CLI。
- **Fuel/Budget Pass**：函数入口/loop backedge 扣费，mutable global，预算配置，超限 `unreachable` trap，可读剩余预算；粗粒度、可复现，不是逐指令 gas。
- **Trace Pass**：host import `moonwasm_trace(func_id)`，稳定 function ID，调用/循环跟踪，可关闭。
- **Guard Pass**：`memory.grow`/`table.grow` 上限、import allowlist、可选 stack-height；资源限制，不是安全沙箱。
- **宿主 ABI + 适配**：wasm5、wasmoon、wasmtime；设置预算/读 fuel、trace hook、trap 报告；同一插桩模块跨宿主运行。
- **正确性保障**：每 pass 后 starshine validate；原/插桩模块差分执行；控制流边界用例；fuzz；不支持特性明确报错。
- **CLI/工程**：`instrument`/`inspect`/`run`；JSON 配置；benchmark；README/demo；mooncakes 发布。
- **明确不做**：完整沙箱/安全边界；源码覆盖（moon_cove）；WASM parser/optimizer（starshine）；wasm-gc/component model/多模块链接；与 Wasmtime gas 等价；UI/托管服务。

#### 预期验收产物

- 发布 `Atman-Angle/moonwasm-instrument` 包，可通过 `moon add` 使用；CLI 可通过 `moonx` 运行。
- Pass 管线 + Fuel/Trace/Guard 三个 pass；wasm5（优先）+ wasmtime（至少一个端到端，第二个为目标）宿主适配。
- 差分与验证：≥30 个模块/用例（≥10 个控制流边界），0 个无法解释的语义差异；每个输出模块通过 validate。
- 在已适配宿主上，相同输入/预算的 fuel 计数与 trap 点一致；预算耗尽 trap 可复现；trace 关闭时不新增 import/开销。
- benchmark 报告（fuel-only / trace-off 的开销与体积）；README/demo；Apache-2.0 + NOTICE。
- 明确不承诺：完整沙箱、逐指令 gas、与 Wasmtime gas 等价、wasm-gc/component model。

#### 原创 / 参考说明

- 本项目为**原创项目，非移植**；参考 `paritytech/wasm-instrument`（https://github.com/paritytech/wasm-instrument，Apache-2.0/MIT）的 gas/stack 思路、`Binaryen`（https://github.com/WebAssembly/binaryen，Apache-2.0）的 trace/memory 插桩、`Wasmtime/Wasmer` 的 fuel 思路；不复制代码。
- 依赖 `starshine`（https://github.com/jtenner/starshine，MIT；NOTICE 列出 Apache-2.0 的 MoonBit Core/Binaryen 衍生部分）做解析/编码/校验；`wasm5`（https://github.com/moonbitlang/wasm5，Apache-2.0）做宿主/测试；`wasmtime`（Apache-2.0 with LLVM exception）做第二宿主。
- 本项目采用 Apache-2.0；`NOTICE`/`THIRD_PARTY` 记录来源、依赖与许可证。

#### 实现路径与技术理解

**常见路径**：① 从零写 parser/encoder + 插桩——重复 starshine，周期不可控；② 改 wasm5/wasmoon 运行时加 fuel——宿主特定、不可移植、靠近官方；③ 在 starshine 上做二进制插桩 pass——宿主无关、可复用、纯 MoonBit，本项目选这条。

**实现路径**：`starshine decode → typed pass pipeline（fuel/trace/guards）→ validate → encode`；定义宿主 ABI，适配 wasm5/wasmtime。Fuel 用 mutable global + 函数/loop 扣费；Trace 用 host import；Guards 重写 `memory.grow`/`table.grow` 与 import allowlist；每个 pass 后 validate，并对原/插桩模块差分执行。

**能力与理解**：需要 WASM 二进制/控制流、MoonBit、starshine API、wasm5/wasmtime 宿主 API、差分/模糊测试。插桩难点不是注入指令，而是控制流/索引重写后的验证与语义保持；fuel 的价值不是精确 gas，而是可移植、可复现的预算；Pass 框架比单点 gas 工具更有复用价值；GuardPass 是资源限制，不是安全沙箱。

**申报前检查**：仓库公开且 ≥10 个有效 commit；README/CI/示例/测试齐全；mooncakes 已发布；许可证/NOTICE 完整；`[]` 替换。
