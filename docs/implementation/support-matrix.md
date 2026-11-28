# production-v1 支持矩阵与输入上限

冻结日期：2026-11-10。分片：S01。状态：**目标允许表已冻结；除解析/验证外，其余覆盖均未实现或未运行**。
本文记录原型的历史支持矩阵。v4 支持范围与验收见 [FuelGuard 生产规格 v4](../14_FuelGuard生产规格_v4.md)，S01 的实测命令、产物哈希与缺口见 [S01 证据](../evidence/S01.md)。
环境字段见 [environment-lock](environment-lock.md)。本文没有任何“生产支持已通过”的结论。

## 1. 判定规则

- 每个特性必须同时具备**解析、验证、计费、栈分析、改写、双运行时测试**六项覆盖，才可声称 production-v1 支持。解析成功不代表支持。
- 目标判定分三档：`ALLOW`（进入 production-v1 实现范围）、`CONDITIONAL`（进入实现范围，但缺少真实负载证据，必须补合成用例后才可声称支持）、`DENY`（明确拒绝，不得静默接受）。
- 覆盖状态分四档：`PASS`（本分片实测）、`NOT_IMPL`（待实现分片）、`NOT_RUN`（待运行分片）、`NO_EVIDENCE`（无任何实测输入）。
- 当时的允许表之外的指令、类型或模块形态一律判为 `DENY`。该表按当时的 v3 分片维护。

## 2. 认证输入负载（S01 实测）

四个产物均由 `moon build --target wasm --release` 生成，构建脚本可重复执行并产出**逐字节相同**的 wasm（哈希见证据文件）。

| ID | 负载类别 | 来源与版本 | 驱动输入 | 字节 | 定义函数 | SIMD | start | call_indirect |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| F0 | 最小基线 | 本仓库 `fixtures/hello`（原创） | sum_to/collatz/nested_sum | 5,387 | 43 | 无 | 无 | 无 |
| F1 | 数据解析 | `moonbitlang/x@0.5.7` 的 `json5` | 固定 JSON5 文档 ×200 轮 | 131,170 | 262 | 14 种 / 47 条 | 有 | 11 |
| F2 | 解释器递归 | `bobzhang/lisp_interpreter@0.1.4` | fib 18 树递归 + count 400 线性递归 | 86,315 | 349 | 10 种 / 53 条 | 有 | 43 |
| F3 | 计算密集 | `moonbitlang/x@0.5.7` 的 `crypto` | 4096 字节固定模式 ×32 轮 SHA-256 | 15,217 | 106 | 5 种 / 12 条 | 有 | 6 |

共同结构：1 个 `wasi_snapshot_preview1.fd_write` 函数 import；1 个定义 memory（初始 1 页，未声明 maximum，导出）；1 个内部固定 funcref table（min=max，不导入不导出）；1 个 active element 段；1 个 data 段；导出 `memory` 与 `_start`；custom section `name`、`producers`。F1/F2/F3 另有 core start section。

参考 stdout（**moonrun/V8、Windows，非认证运行时，仅供 S02 对照，不计入验收**）：

- F1：`json5 rounds=200 checksum=68600`
- F2：`Number(2584)`、`Number(0)`
- F3：`sha256 rounds=32 bytes=4096 checksum=132768` 与 `cfd7e96b613a248f444c75aea845bd83f003dcca657dad7c72330bb827d212f6`（已用独立 Python hashlib 复核一致）

## 3. 特性级允许表与六项覆盖

`解析`/`验证` 列的 PASS 依据：starshine 0.3.0 `decode_module` + `validate_module` 对 F0–F3 全部成功，且 `wasm-tools 1.263.0 validate` 独立通过；函数计数两者一致（43/262/349/106）。

| 特性 | 判定 | 解析 | 验证 | 计费 | 栈分析 | 改写 | 双引擎 | 真实证据 / 负责分片 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| wasm32 i32/i64 标量指令 | ALLOW | PASS | PASS | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | F0–F3；S04/S06/S10/S11/S02 |
| f32/f64 标量指令（含 load/store/convert/reinterpret） | ALLOW | PASS | PASS | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | F1/F2；NaN 分类比较见 09/10；S04/S16 |
| 结构化控制流 block/loop/if/else/end/br/br_if/br_table/return/unreachable/drop/select（数值） | ALLOW | PASS | PASS | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | F0–F3；S04/S05/S06/S10 |
| multi-value（结果数实测最大 4） | ALLOW | PASS | PASS | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | F1/F2/F3；S10/S11/S16 |
| 直接 call | ALLOW | PASS | PASS | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | F0–F3；S06/S11 |
| call_indirect（内部固定 funcref table） | ALLOW | PASS | PASS | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | F1/F2/F3；element 目标需包装改写；S11/S16 |
| 单 memory（定义、可导出、初始 1 页） | ALLOW | PASS | PASS | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | F0–F3；宿主不得并发扩容；S08/S13 |
| memory.size / memory.grow | ALLOW | PASS | PASS | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | F0–F3；动态费用 + 上限；S07/S08 |
| memory.copy / memory.fill | ALLOW | PASS | PASS | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | F0–F3；动态长度费用；S07/S08 |
| memory.init / data.drop | CONDITIONAL | NO_EVIDENCE | NO_EVIDENCE | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | 无真实负载发射；S07 动态计费 + S16/S17 合成用例后方可声称支持 |
| 单 funcref table（min=max、内部、不导入导出） | ALLOW | PASS | PASS | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | F0–F3；S09/S11 |
| active element 段（静态 func 引用） | ALLOW | PASS | PASS | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | F0–F3；目标改写需引用审计；S11 |
| externref table 及其 table.grow/size/fill/copy/init | CONDITIONAL | NO_EVIDENCE | NO_EVIDENCE | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | 无真实负载证据；S08 + S16/S17 合成覆盖；不得据此声称支持可变 funcref table |
| ref.null / ref.is_null（不透明引用值） | CONDITIONAL | NO_EVIDENCE | NO_EVIDENCE | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | 仅随 externref table 覆盖一并验证；S08/S16 |
| ref.func / 可逃逸函数引用 | DENY | — | — | — | — | — | — | 会绕开固定 table 与栈包装；S09 拒绝用例 |
| 可变 funcref table（table.set/grow/copy/init/fill 作用于调用表） | DENY | — | — | — | — | — | — | S09/S11；后续设计另行立项 |
| start section | ALLOW | PASS | PASS | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | F1/F2/F3；入口包装 + 初始化诊断不可用；S11/S13/S16 |
| 导出函数（`_start`） | ALLOW | PASS | PASS | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | F0–F3；wrapper 覆盖；S11 |
| 导出 memory | ALLOW | PASS | PASS | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | F0–F3；S09/S13 宿主契约 |
| 导出 table / 导入 memory / 导入 table | DENY | — | — | — | — | — | — | S09 拒绝用例 |
| 函数 import（allowlist 精确二元组） | ALLOW | PASS | PASS | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | F0–F3 需显式允许 `wasi_snapshot_preview1.fd_write`；禁止重入；S09/S13 |
| 未声明 import | DENY | — | — | — | — | — | — | 生产默认拒绝；S09 |
| mutable / immutable global（i32/i64） | ALLOW | PASS | PASS | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | F0–F3；S05/S06 |
| 模块内定义的 mutable / immutable f64 global | ALLOW | PASS | PASS | PASS | PASS | PASS | PASS | S16 补齐冻结的 F1；导入全局仍限 i32/i64 |
| SIMD 指令（全部，含 relaxed）与 v128 值类型 | DENY | PASS（拒绝路径） | PASS（拒绝路径） | PASS | PASS | PASS | PASS | S25：申报书范围外；preflight 对全部 SIMD opcode 与 v128 值类型显式拒绝；A15 有 16 条逐类边界 + relaxed 边界；负载已去 SIMD 重建 |
| GC 类型 / struct / array / i31 / ref.cast | DENY | — | — | — | — | — | — | 现有 policy 已拒绝；S09 |
| component model / 多模块链接 | DENY | — | — | — | — | — | — | S09 |
| memory64 / 共享 memory / threads / atomics | DENY | — | — | — | — | — | — | S09 |
| tail-call（return_call*） | DENY | — | — | — | — | — | — | 破坏调用前预留/释放模型；S09 |
| 异常处理（try/catch/throw/delegate） | DENY | — | — | — | — | — | — | S09 |
| stack switching | DENY | — | — | — | — | — | — | S09 |
| 多 memory / 多 table | DENY | — | — | — | — | — | — | 现有 policy 已拒绝；S09 |
| custom section（name/producers/未知） | ALLOW | PASS | PASS | NOT_IMPL | NOT_IMPL | NOT_IMPL | NOT_RUN | F0–F3；保留并计入字节上限；重复插桩标记扫描；S09/S14 |
| 已带本工具插桩标记 / 保留诊断名冲突 / 未知费用模型 | DENY | — | — | — | — | — | — | S09/S14；A15/A23 |

## 4. SIMD（全部拒绝，冻结）

S01 实测：F1/F2/F3 旧版（依赖 moonbitlang/x 与 bobzhang 库）全部发射同一组 16 条 SIMD 指令与 v128 值类型（来自 MoonBit core 的字符串/数组例程）；`moon build` 无关闭 SIMD 的选项。用户 2026-11-10 曾决策纳入该观测最小子集。

**2026-11-18 用户决策：申报书（docs/04 第 35 行）为准且不可修改，SIMD 整体在首版范围之外，前述纳入决议作废。** production-v1 现状：

- preflight 对全部 SIMD opcode（0xFD 前缀，含 relaxed）与 v128 值类型声明显式拒绝，消息为 "SIMD opcode N outside production-v1 allowlist" / "production-v1 value type"；relaxed SIMD 有独立消息。
- 费用表（cost_model）不含任何 SIMD 条目；独立预言机与差分语料不含 SIMD 路径。
- 三个真实负载 fixture 以**自持标量实现**重建（JSON5 扫描器、Lisp 解释器、SHA-256），移除 moonbitlang/x/json5、bobzhang/lisp_interpreter、moonbitlang/x/crypto 依赖；重建后四个负载与五个 holdout 全部零 SIMD（wasm-tools 反汇编核验），工作负载类别与真实性保持不变。
- 语料于 2026-11-18 重新冻结：`bench/dataset.json`（SHA-256 480f49811c5cf2a43262ce2e9aebb0198aecf0d9a360942a44880a8ed830fc45，含 SHA-256 填充边界修复后的 F3 重建）；旧语料清单保留为 `bench/dataset-v1-simd.json` 仅作历史记录。fixture 工具链为本地 moon 0.1.20261016（原 20261104 WSL 环境随事故丢失，重建时按 bench/README.md 哈希重装）。
- 栈模型 stack-v1 的 v128 保守计入条款（16 字节）保留为防御性深度，生产路径不可达。
- A15 拒绝用例覆盖 16 条指令逐类边界与 relaxed 边界（integration/generated/reject.py）。

## 5. 输入上限（PROVISIONAL，发布前必须由压力测试冻结）

依据：F0–F3 实测最大值 + 工程余量。**下列数值是 S01 提出的有限上限，不是已冻结的边界值**；按 05 第 3 节，S09 实现有界预检、S20 用至少三档规模与最大支持输入做压力测试后冻结并公开，未冻结前不得生产发布。

| 维度 | 实测最大（来源） | 暂定上限 | 余量 | 冻结责任 |
| --- | --- | --- | --- | --- |
| 模块字节 | 131,170（F1） | 4,194,304（4 MiB） | ≈32x | S09 预检 / S20 压测 |
| 函数总数（import + 定义） | 350（F2） | 4,096 | ≈12x | S09 / S20 |
| 类型数 | 59（F1/F2） | 1,024 | ≈17x | S09 / S20 |
| global 数 | 1,311（F1） | 16,384 | ≈12x | S09 / S20 |
| import 数 | 1（F0–F3） | 256 | — | S09 |
| export 数（含生成诊断导出） | 2（F0–F3） | 1,024 | — | S09 / S14 |
| memory 数 / 初始页 | 1 / 1 页 | 1 / 65,536 页 | 沿用现有 MAX_MEMORY_PAGES | S08 / S09 |
| table 数 / 元素数 | 1 / 15（F2） | 1 / 65,536 | — | S08 / S09 |
| element 段数 / 单段 func 引用数 | 1 / 14（F2） | 256 / 4,096 | — | S09 / S11 |
| data 段数 | 1（F0–F3） | 256 | — | S09 |
| 单函数参数数 | 10（F2） | 64 | ≈6x | S10 / S20 |
| 单函数结果数 | 4（F1/F2） | 16 | 4x | S10 / S20 |
| 单函数 local 数（不含参数） | 523（F2） | 4,096 | ≈8x | S10 / S20 |
| 结构化嵌套深度 | 42（F1） | 256 | ≈6x | S05/S09 / S20 |
| 单函数指令数 | 6,482（F1） | 65,536 | ≈10x | S05 / S20 |
| 模块指令总数 | 35,554（F2） | 1,048,576 | ≈30x | S05 / S20 |
| 名称字节数（import/export/custom） | 未单独测量 | 1,024，且必须为合法 UTF-8 | — | S09 |

执行约束：

- 字节上限必须在**解码之前**检查；函数/类型/段计数上限应在段头预检阶段检查，不能等无界解码完成后才声称防住恶意嵌套（05/12 要求）。
- 嵌套深度与 local/参数/结果上限同时是 S10 栈上界推导的输入；超出即拒绝，不得截断或静默降级。
- 上限触发必须给出明确错误类别与实测值，进入 A15 拒绝矩阵；拒绝用例不计入 A14 有效样本数。

## 6. 范围冲突与处理记录

| 冲突 | 事实 | 处理 | 影响 |
| --- | --- | --- | --- |
| SIMD 与 production-v1 排除条款 | F1/F2/F3 全部发射 16 条 SIMD 指令与 v128 类型；`moon build --help` 无 SIMD 开关，`--strip/--no-strip` 只影响调试信息 | 用户 2026-11-10 决策：纳入观测最小子集，relaxed SIMD 与其余 SIMD 仍拒绝；同步修订 05/06/09/12/07/08 | S04 权重、S10 v128 栈成本、S16 双引擎覆盖扩展；不是静默默许 |
| 生态包使用旧 `moon.mod.json` | `gmlewis/json@0.15.0`、`bobzhang/jsonl@0.2.0`（经 `moonbitlang/async`）、`jinser/json@0.0.1`、`hackwaly/regex@0.0.1`（经 `moonbitlang/quickcheck@0.9.8`）、`Guest0x0/dregex`、`bobzhang/html_parser`、`kawaz/unicodegrapheme` 均被当前工具链拒绝解析依赖图 | 不修改第三方源码、不手改 vendored 元数据；改用能在当前工具链干净解析的真实包（`moonbitlang/x@0.5.7`、`bobzhang/lisp_interpreter@0.1.4`） | 这是**构建格式不兼容**，不是插桩支持冲突；候选与失败原因全部留档，未用“容易通过的样例”替换目标兼容性 |
| 真实负载含 WASI import 与 start | F0–F3 均 import `fd_write`；F1/F2/F3 有 core start section | 生产配置要求显式 `--allow-import wasi_snapshot_preview1.fd_write`；start 必须由 wrapper 覆盖并计入生命周期性能 | S09/S11/S13/S18；不得用空导出调用替代 start 业务 |
| 真实负载含 f32/f64 | F1/F2 发射浮点运算与 reinterpret | 差分按 09/10 的 NaN 语义分类；观察位模式的程序移出严格跨引擎子集或另设规范化 profile | S16/S17 |
| Linux 认证环境缺失 | 本机 WSL 仅 `docker-desktop`（Stopped），无 wasmoon/Wasmtime 实测 | 记为缺口交 S02；不得以 Windows/moonrun 结果替代 | 双引擎列全部 NOT_RUN |

## 7. S02 交接结果

- [S02](../evidence/S02.md) 已记录 Linux 运行环境、工具版本与哈希、F0–F3 原模块及 Fuel 原型 F0 的双引擎结果，以及返回值和 trap 分类。上方双引擎列跟踪逐特性的完整插桩验证，待后续分片执行。
- `CONDITIONAL` 特性的合成输入（memory.init/data.drop、externref table 增长、ref.null/is_null）由 S07/S08/S16 补齐。认证硬件与电源模式由 S18 冻结。
