# 环境锁定、版本与迁移规则

更新日期：2026-11-18。S01/S02 开发与运行环境，以及 S18 性能参考环境均有实际测量。
实测命令与输出见 [S01 证据](../evidence/S01.md) 和 [S02 证据](../evidence/S02.md)。
本文记录原型环境和 v3 迁移计划。v4 交付与验收见 [FuelGuard 生产规格 v4](../14_FuelGuard生产规格_v4.md)。

## 1. 已实测的开发环境

| 字段 | 值 | 来源 |
| --- | --- | --- |
| 开发宿主 OS | Microsoft Windows 11 家庭版 中文版，build 10.0.26300 | `Get-CimInstance Win32_OperatingSystem` |
| 开发宿主 CPU / 内存 | Intel Core Ultra 9 185H / 31.4 GiB | `Get-CimInstance Win32_Processor`、`Win32_ComputerSystem` |
| MoonBit 工具链 | `moon 0.1.20261016 (1af328f 2026-10-16)`，feature flags `rr_moon_mod,rr_moon_pkg` | `moon version` |
| 独立校验/反汇编 | `wasm-tools 1.263.0 (7a2fa422c 2026-10-30)`，x86_64-windows 官方 release | `wasm-tools --version` |
| wasm-tools 下载 URL | `https://github.com/bytecodealliance/wasm-tools/releases/download/v1.263.0/wasm-tools-1.263.0-x86_64-windows.zip` | S01 实际下载 |
| wasm-tools zip SHA-256 | `0803df158b4dbea6b029d11f4206c414f432f0447af91542817061e4f0bd912e` | `sha256sum` |
| wasm-tools.exe SHA-256 | `3be416990124225fb4b683c8add1d910ea5bccb67de0963dab13a5599b685829` | `sha256sum` |
| 辅助脚本运行时 | Python 3.13.7、Git 2.53.0.windows.2、Node v24.11.1 | `--version` |
| 本地 registry index HEAD | `b37dc2aa3e98345c394ab51d355cbe09d3c50a6c`（2026-11-01） | `git -C ~/.moon/registry/index log -1` |
| mooncakes 可达性 | 2026-11-10 `https://mooncakes.io/api/v0/modules` 与 github.com 均 HTTP 200 | `curl` |
| WSL 发行版 | 仅 `docker-desktop`，VERSION 2，STATE Stopped | `wsl.exe -l -v` |

工具存放位置：`_build/tools/`（已被 `.gitignore` 忽略）。wasm-tools 只作独立验证/反汇编，不进入 MoonBit 插桩核心，也不作产品 runner。

## 2. 依赖与负载版本锁定

| 用途 | 模块 | 版本 | 备注 |
| --- | --- | --- | --- |
| 插桩核心 codec/validator | `jtenner/starshine` | 0.3.0 | `moon.mod` 精确版本；解析/验证/编码 |
| starshine 传递依赖 | `moonbitlang/x` | 0.5.1 | `moon tree` 实测 |
| F1/F3 负载 | `moonbitlang/x` | 0.5.7 | `json5`、`crypto` 包 |
| F2 负载 | `bobzhang/lisp_interpreter` | 0.1.4 | 无外部传递依赖（仅 core） |
| 本模块 | `Atman-Angle/moonwasm-fuelguard` | 0.1.0 | 原型版本，v3 发布需升 minor |

锁定缺口（必须公开，不得当作已锁定）：

- `.mooncakes/.moon-lock` 实测为 **0 字节空文件**，当前工具链未提供内容级锁；依赖复现靠 `moon.mod` 精确版本 + 本文与证据中的产物 SHA-256。S22 必须在干净环境重新解析并比对产物哈希，才能声称可复现。
- S01 在工作区生成了 `fixtures/workloads/<name>/<name>.wasm`，`build.sh` 重跑实测**逐字节一致**（哈希见证据）。这三份基线文件属于待归档的 fixture，入库约定见 [README](../../README.md#repository-layout)。
- S02 在独立 WSL2 发行版构建并执行了 wasmoon 0.18.0，同时验证了 Wasmtime 50.0.0 与 Linux wasm-tools 1.263.0。工具归档和可执行文件哈希见 [S02 证据](../evidence/S02.md)。

## 3. Linux 运行环境与性能认证字段

| 字段 | 状态 | 关闭条件 |
| --- | --- | --- |
| 可用 Linux 发行版 / 内核 / glibc | S02 实测 Ubuntu 24.04.3 x86_64 / WSL2 6.6.114.1 / glibc 2.39 | 独立发行版 `FuelGuard-S02` |
| wasmoon 版本 + 构建哈希 | 0.18.0，native release，默认 JIT 路径 | 构建哈希及 F0–F3 实际执行见 S02 |
| Wasmtime 版本 + 配置（含 fuel/epoch 关闭说明） | 50.0.0（ebe5e8df1），fuel/epoch 默认关闭 | F0–F3 实际执行见 S02 |
| wasm-tools Linux 版本 + 哈希 | 1.263.0（7a2fa422c） | 归档/二进制哈希、编码后正反例见 S02 |
| 原生栈大小 / 线程栈配置 | 进程栈软限 8 MiB，硬限无限；wasmoon JIT native fiber 16 MiB；Wasmtime Wasm 栈 512 KiB | [S03](../evidence/S03.md) 记录同形探针的实测余量 |
| S18 性能参考硬件 | Core Ultra 9 185H，16 核/22 线程，Ubuntu 24.04.3 WSL2，来宾内存 16,081,464 KiB，Windows 11 build 26300 平衡方案、接交流电 | [S18 实测](../evidence/S18.md) |
| 计时器精度 / 后台干扰控制规则 | CLOCK_MONOTONIC 标称 1 ns，绑定来宾 vCPU 4、各进程串行、保留全部样本 | [冻结数据集与采样参数](../../bench/dataset.json) |

## 4. 模型、ABI 与 codegen 版本标识

| 标识 | 取值 | 冻结分片 | 现状 |
| --- | --- | --- | --- |
| profile | `production-v1` | S01（本文 + 支持矩阵） | 目标允许表已冻结，实现未完成 |
| 费用模型 | `fuel-v1` | S04 | [权重与 canonical 边界](fuel-v1.md)已冻结，块分析与改写由 S05–S08 实现 |
| 栈模型 | `stack-v1` | S10 | 统一 C(f) 模板族与 v128 计入规则未冻结 |
| 诊断 ABI | `moonwasm-diag-v1`（原型）→ `moonwasm-diag-v2`（目标） | S12/S14 | 原型只有 `__moonwasm_trap_code`，code 0..3 |
| codegen 布局 | P0 `inline-per-instruction-v1`，P1 `p1-helper-v1`，P2 `p2-hybrid-loop-inline-sites21-v1` | S18–S21 | [S20 调优与冻结记录](../evidence/S20.md) |
| 工具版本 | 0.1.0（原型）→ 0.2.0（v3 首个不兼容发布） | S22 | 迁移说明未编写 |

诊断 ABI 约定：

- v1（现状，实测于 `trap.mbt`）：导出 `__moonwasm_trap_code`，`TrapCode` 为 `NoTrap/Fuel/Memory/Table` = 0/1/2/3；未知值报 `InvalidTrapCode`。
- v2（目标）：保留同名导出并扩展为 0..5（新增 4 Stack、5 Depth），新增稳定 site ID 导出与 ABI 版本标记；成功路径不写 site；start/实例化失败拿不到实例时报告 `initialization-trap/diagnostic-unavailable`，不得推断 code。
- v1 产物只能按 v1 解释，**不得标注为 `fuel-v1` 或 `moonwasm-diag-v2`**；未知 ABI/模型版本必须明确拒绝（A23）。

## 5. 不兼容变更与迁移规则

| 项 | 原型（0.1.0，实测） | v3 目标（0.2.0） | 迁移规则 |
| --- | --- | --- | --- |
| 预算类型 | `Int32`，`MAX_FUEL = 2_147_483_647`，范围 1..=2147483647 | `Int64`，范围 1..=2^63-1 | 旧配置值可提升为 i64；超出旧范围的值在旧版本必须报错，不得回绕；错误文案与 `InvalidFuelBudget` 载荷类型同步变更 |
| 计费语义 | 函数入口 + 每次 Loop 迭代各扣 1 | 版本化加权计费块 + 动态长度费用 | 旧产物标记为原型模型，拒绝按 `fuel-v1` 解释；不提供静默 fallback |
| 资源上限 | `GuardConfig` 可选，未配置即放行；`MAX_MEMORY_PAGES = 65_536` | production profile 要求为存在的资源显式设上限 | 缺上限即拒绝，禁止静默降低保护等级；旧“未配置=无保护”行为需在迁移说明中点名 |
| import 策略 | `allowed_imports : Array[String]` | module/name 二元组精确匹配，默认拒绝未声明 import | 点号写法歧义必须拒绝或提供转义；旧字符串拼接语义不兼容，需迁移提示 |
| pass 顺序 | FuelPass → GuardPass（Guard 为空实现） | analysis/plan → Fuel → Growth → Stack | 第三方 Pass 组合仍为实验性，不继承生产保证 |
| trap code | 0..3 | 0..5 | 新增 4/5；未知值仍为无效诊断 |
| CLI | `--fuel` 为必填预算参数，合法值用于粗粒度 Fuel 插桩；显式配置 memory/table 上限或 import allowlist 会被拒绝（exit 2） | `--profile/--cost-model/--fuel/--max-stack-units/--max-call-depth/--max-memory-pages/--max-table-elements/--allow-import/--report` | 旧参数保留并给出迁移提示；未知/冲突参数拒绝 |
| 索引稳定性 | 保留已有数值索引 | 保留数值索引，但允许有计划改写 export/start/element 目标 | 改写必须有清单与独立引用完整性测试（A01/A06） |
| 错误类型 | `InstrumentError` 含 `NotImplemented(String)` | 生产路径不得用占位错误接受配置 | 未实现能力必须显式拒绝，不得返回空 Pass 成功 |

发布要求：模型/ABI/profile 任一变更都触发受影响验证；0.2.0 必须附迁移说明、旧产物识别规则与可复现证据（A22/A23）。

## 6. 构建期工程预算

按 09 A20，首轮基准前必须填写具体数值与参考硬件。S01 提出以下**工程预算**，S20 实测后冻结或走独立需求变更：

| 项 | 工程预算 | 适用输入 | 状态 |
| --- | --- | --- | --- |
| 插桩端到端构建时间 | ≤ 10 s | 最大支持输入（4 MiB / 4,096 函数 / 1,048,576 指令） | S20 的 P0 超限 |
| 插桩峰值内存 | ≤ 512 MiB | 同上 | S20 的 P0、P1、P2 均超限 |
| 规模趋势检查 | 至少三档输入，时间/内存不得出现超线性退化 | 小/中/最大 | [S20 构建账本](../evidence/S20.md#构建体积与默认裁决) |
| 跨版本回退阻塞 | 执行/构建时间或峰值内存回退 > 5% 且复测仍存在则阻塞发布 | 冻结基线 | [S18 P0 基线](../evidence/S18.md)，S20 冻结候选 |
| 参考硬件 | S18 固定 Linux 环境 | 见第 3 节 | [S18](../evidence/S18.md) |

分阶段报告要求：ModuleIndex 建表、块分析、各次改写、每次 validate、编码、引擎编译、实例化、执行与端到端分别计时；依赖库耗时可单列但必须计入用户端到端结果，不得隐藏。
