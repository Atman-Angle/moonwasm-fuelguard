# MoonWasm FuelGuard 任务分片与执行计划 v3.2

> **已归档（2026-11-20）：**本文为历史任务分片记录（evidence 链索引）；后续分片与验收以 [14 生产规格 v4](14_FuelGuard生产规格_v4.md) 为准。

更新日期：2026-11-18。S01–S19 已执行，当前状态与证据见第 2 节。本版保留U0-U10里程碑含义，细分为S01-S23，另设 S24-S29 为 S20 解除阻塞专项（对应 M0-M5，诊断结论与实测依据见各片条目）；后续按S编号执行，不把旧U项当成另一个重复任务。专项推荐顺序 S24→S25→S26→S27→S28→S29→S21→S22→S23。

## 1. 基线和使用方法

当前代码已有函数/循环固定扣1的FuelPass、基础验证、instrument CLI；Guard配置仍未实现，run仍是脚手架。新模型、Stack和双运行时生产验收未完成。S01 曾按当时用户决策把 16 条 SIMD 指令纳入观测最小子集；2026-11-18 用户决策改为申报书（docs/04）优先且不可修改，SIMD 收敛为全部显式拒绝并重建语料，见 S25。认证 Linux 环境仍缺失。开始每片先检查实际源码与git状态，不能以本表替代证据。

每个分片的短提示词只给目标和验收入口，直接复制其代码块执行；总入口见 [13_任务提示词使用指南](13_任务提示词使用指南.md)。默认一片一个实现会话，完成后再启动下一片；本计划不启动子代理或新聊天。无需因分片而重写基础架构。

总体架构见 [06](06_架构设计_MoonWasm_Instrument.md)，实现细节见 [12](12_FuelGuard高性能实现方案.md)，A01-A24标准见 [09](09_验证与验收计划.md)。每片的A项表示本片承担的部分，只有最终完整运行才能关闭整个A项。

## 2. 状态与依赖总表

状态NOT_STARTED表示尚未执行，DONE必须附本片证据。实现状态与验收PASS/FAIL分开；缺环境不是PASS。

| ID | U里程碑 | 分片 | 前置 | 状态 | 提示词 |
| --- | --- | --- | --- | --- | --- |
| S01 | U0 | 冻结支持矩阵与工程边界 | 无 | DONE | [执行提示词](prompts/S01.md) |
| S02 | U1 | 建立Linux双运行时验证驱动 | S01 | DONE | [执行提示词](prompts/S02.md) |
| S03 | U2 | 验证调用前栈保护的关键路径 | S01, S02 | DONE | [执行提示词](prompts/S03.md) |
| S04 | U3 | 冻结费用模型与独立计费预言机 | S01 | DONE | [执行提示词](prompts/S04.md) |
| S05 | U4 | 实现索引、函数事实与插桩计划 | S01, S04 | DONE | [执行提示词](prompts/S05.md) |
| S06 | U4 | 实现P0静态块计费与i64迁移 | S02, S04, S05 | DONE | [执行提示词](prompts/S06.md) |
| S07 | U4 | 实现动态长度费用与溢出保护 | S06 | DONE | [执行提示词](prompts/S07.md) |
| S08 | U5 | 实现memory与externref table增长保护 | S07 | DONE | [执行提示词](prompts/S08.md) |
| S09 | U5 | 落实输入限制与导入策略 | S01, S05, S08 | DONE | [执行提示词](prompts/S09.md) |
| S10 | U6 | 实现最终代码栈成本分析 | S03, S05, S08 | DONE | [执行提示词](prompts/S10.md) |
| S11 | U6 | 实现Stack改写与所有入口包装 | S09, S10 | DONE | [执行提示词](prompts/S11.md) · [验收证据](evidence/S11.md) |
| S12 | U6 | 集成完整生产管线与不变式审计 | S06, S07, S08, S09, S11 | DONE | [执行提示词](prompts/S12.md) · [验收证据](evidence/S12.md) |
| S13 | U7 | 实现Linux产品runner与诊断生命周期 | S02, S12 | DONE | [执行提示词](prompts/S13.md) · [验收证据](evidence/S13.md) |
| S14 | U7 | 实现生产CLI、manifest与site映射 | S12, S13 | DONE | [执行提示词](prompts/S14.md) · [验收证据](evidence/S14.md) |
| S15 | U7 | 实现可恢复文件交付与故障测试 | S14 | DONE | [执行提示词](prompts/S15.md) · [验收证据](evidence/S15.md) |
| S16 | U8 | 完成具名差分语料与演示 | S04, S13, S15 | DONE | [执行提示词](prompts/S16.md) · [验收证据](evidence/S16.md) |
| S17 | U8 | 生成变异语料与统一验收入口 | S16 | DONE | [执行提示词](prompts/S17.md) · [验收证据](evidence/S17.md) |
| S18 | U9 | 建立P0性能基线与冻结数据集 | S17 | DONE | [执行提示词](prompts/S18.md) · [验收证据](evidence/S18.md) |
| S19 | U9 | 实现本项目P1共享计费候选 | S18 | DONE | [执行提示词](prompts/S19.md) · [验收证据](evidence/S19.md) |
| S20 | U9 | 实现本项目P2静态混合候选 | S19 | BLOCKED（S29 正式比较无合格布局） | [执行提示词](prompts/S20.md) · [证据](evidence/S20.md) · [S29 裁决](evidence/S29.md) |
| S21 | U9 | 独立验收冻结默认布局的完整保护性能（M5） | S29 | NOT_STARTED | [执行提示词](prompts/S21.md) · [M5 入口](prompts/M5.md) |
| S22 | U10 | 完成迁移、包与干净环境复现 | S21 | NOT_STARTED | [执行提示词](prompts/S22.md) |
| S23 | U10 | 独立复核并汇总验收报告 | S22 | NOT_STARTED | [执行提示词](prompts/S23.md) |
| S24 | U9 | 固化S20证据基线与实验分支记录（M0） | S19 | NOT_STARTED | [执行提示词](prompts/M0.md) |
| S25 | U9 | SIMD范围收敛与语料重建（M0.5） | S24 | NOT_STARTED | [执行提示词](prompts/M0.5.md) |
| S26 | U9 | fuel-v1.2合并计费块划分与性能试点（M1） | S25 | 冻结对照 3.285× 触发停止线，后续缓存候选试点 2.090× 达到 S27 进入条件 | [执行提示词](prompts/M1.md) · [原试点](evidence/S26.md) · [缓存试点](evidence/Fuel-optimization.md) |
| S27 | U9 | fuel-v1.2正确性重推导（M2） | S26 | DONE（双布局正确性验收通过） | [执行提示词](prompts/M2.md) · [证据](evidence/S27.md) |
| S28 | U9 | 体积与构建门禁收敛（M3） | S27 | DONE（A19 四项 FAIL，A20 最大输入 PASS） | [执行提示词](prompts/M3.md) · [证据](evidence/S28.md) |
| S29 | U9 | 正式布局重跑与默认冻结（M4） | S28 | BLOCKED（正式比较与补采完成，后续候选仍未通过 A19） | [执行提示词](prompts/M4.md) · [证据](evidence/S29.md) · [裁决](evidence/S29-decision.json) · [后续实验](evidence/S29-autoresearch.md) |

## 3. 执行顺序和阶段出口

推荐顺序为S01→S02→S03→S04…→S23。依赖表定义真正前置：例如Linux被阻塞时，S04/S05仍可推进，不把整个项目误判为无事可做。执行提示词不授权跳过前置验证。

| 阶段 | 分片 | 退出条件 |
| --- | --- | --- |
| 风险和语义冻结 | S01-S04 | 输入范围、运行环境、栈可行性与费用预期有证据 |
| 自主P0核心 | S05-S12 | Fuel/Growth/Stack完整组合，逐pass与独立验证通过 |
| 可用产品路径 | S13-S15 | runner、CLI、manifest及文件故障行为可复现 |
| 正确性门禁 | S16-S17 | 具名语料、有效生成语料、统一结果入口；未做性能项不能PASS |
| 性能实现与选择 | S18-S21 | 本项目P0/P1/P2、冻结数据集、完整保护性能门禁 |
| S20 解除阻塞 | S24-S29 | 基线固化、SIMD 收敛、fuel-v1.2 划分与试点、正确性、体积与默认冻结；冻结失败保留数据交用户决策 |
| 交付与复核 | S22-S23 | 包/迁移/证据完整，生产最终状态由实际结果判定 |

原U映射：U0=S01；U1=S02；U2=S03；U3=S04；U4=S05-S07；U5=S08-S09；U6=S10-S12；U7=S13-S15；U8=S16-S17；U9=S18-S21；U10=S22-S23。

## 4. 逐片执行规格

修改范围中的“拟新增”表示建议实现位置，尚不存在；执行时可按仓库约定细调，但必须保留职责边界。文件所有权不是删改用户其他工作的许可。

### S01 冻结支持矩阵与工程边界

- 前置：无；里程碑：U0。
- 范围：现有：policy.mbt、config.mbt、moon.mod、fixtures/hello、docs/05、06、09、12。拟新增：docs/implementation/support-matrix.md、environment-lock.md。
- 实现：前移至少三类真实MoonBit应用负载的选择，记录来源版本、输入、构建选项及特性；逐项列出解析/验证/计费/栈/改写/双引擎覆盖；冻结production-v1允许/拒绝矩阵、完整指令类别、输入字节/函数/参数/返回值/local/嵌套上限；记录工具版本、i64/API迁移、费用/栈模型和诊断ABI；给出构建时间/内存工程预算及待测硬件字段，不能把待测值写成实测。
- 验收：A15、A23的规格前置；每个实际fixture有特性清单；所有范围冲突有明确处理；未能核实的运行环境字段列出缺口，交给S02补齐。
- 不做：不实施Fuel/Stack改写，不把解析器支持等同于产品支持；SIMD 已按 S01 实测与用户决策纳入观测最小子集（16 条 + v128 类型），relaxed SIMD、其余 SIMD、GC 与可变 funcref 表仍拒绝，不得继续默许扩展。（S25 起作废：SIMD 全部拒绝）
- 交接：`docs/evidence/S01.md`（已创建），包含实际命令、结果和产物标识；冻结结果见 [支持矩阵](implementation/support-matrix.md) 与 [环境锁定](implementation/environment-lock.md)。
- 提示词：[prompts/S01.md](prompts/S01.md)。

### S02 建立Linux双运行时验证驱动

- 前置：S01；里程碑：U1。
- 范围：现有：fixtures、runner/moon.pkg、moon.mod。拟新增：integration/runtime、scripts中明确区分平台的测试入口、环境锁定记录。
- 实现：检查实际可用Linux/WSL环境；固定wasmoon、Wasmtime和wasm-tools版本；建立最小原模块、WASI stdout、返回值、普通trap和start失败执行驱动，并实际运行S01选定的三类真实负载原模块；记录诊断导出可读性、原生栈设置、超时保护和退出码；支持冲突先明确处理，不在后期换容易样例掩盖；独立工具只用于验证，不进入核心。
- 验收：A01、A13的基础能力；两个引擎都实际执行fixture；编码后独立验证可运行；可复现环境命令与版本完整。缺Linux时完成驱动与明确缺口，但不得判运行验收通过。
- 不做：不切换Windows默认环境，不借docker-desktop冒充已配置Linux开发环境，不实现生产runner或新增通用Host框架。
- 交接：[S02 证据](evidence/S02.md) 与 [Linux 复现入口](../integration/runtime/README.md)，包含实际命令、结果和产物标识。
- 提示词：[prompts/S02.md](prompts/S02.md)。

### S03 验证调用前栈保护的关键路径

- 前置：S01, S02；里程碑：U2。
- 范围：拟新增：integration/stack_probe和最小Wasm fixture；只在可隔离的原型区域实现，不让原型默认进入产品pipeline。
- 实现：实现可执行的直接调用前预算检查、export/start/固定表间接入口包装原型；验证大local、操作数峰值、递归、multi-value返回、早退；为受管代码、生成模板及入口余量建立可审计的保守映射依据，并以受测引擎压力探针反证/验证；说明wrapper自身入口开销、宿主责任前提和start诊断不可用情况。
- 验收：A05-A08可行性证据；能区分自己的stack trap和引擎先溢出；生成引用映射用例实际通过；结论注明受测范围。
- 不做：不把深度计数当完整栈限制，不删除难例或修改引擎配置后隐瞒原始失败，不宣称已完成S10-S12。
- 交接：[S03 证据](evidence/S03.md)，包含实际命令、结果和产物标识。
- 提示词：[prompts/S03.md](prompts/S03.md)。

### S04 冻结费用模型与独立计费预言机

- 前置：S01；里程碑：U3。
- 范围：拟新增：cost_model.mbt、测试专用oracle、docs/implementation/fuel-v1.md。现有：fuel_pass_wbtest.mbt。
- 实现：为允许指令定义完整权重（含 S01 冻结的 16 条 SIMD 指令，均为静态费用，`v128.load/store` 按可能 trap 的保守边界处理）、动态a+b*n公式、canonical块边界表、块预扣语义、错误优先级和site定义；明确合法前缀合并，不默认逐load/store检查；按05冻结栈优先于深度、动态超i64报code1及间接/外部入口顺序；无规则指令拒绝；实现独立的小程序执行轨迹/手算预言机，覆盖分支、循环、调用、动态费用及溢出；模型哈希和版本稳定。（S25 起费用表不含 SIMD 条目）
- 验收：A02-A04预期值有独立依据；C>=2时C-1/C/C+1行为明确；预言机不调用生产块分析器；零成本循环被拒绝或证明不可形成。
- 不做：不凭微基准宣称费用等于CPU时间，不复用未来生产分析器制造期望值，不实现完整Wasm解释器。
- 交接：[S04 证据](evidence/S04.md)，包含实际命令、结果和产物标识。
- 提示词：[prompts/S04.md](prompts/S04.md)。

### S05 实现索引、函数事实与插桩计划

- 前置：S01, S04；里程碑：U4。
- 范围：现有：ast.mbt、policy.mbt、pass.mbt。拟新增：module_index.mbt、function_facts.mbt、instrument_plan.mbt。
- 实现：用密集数组一次构建含import偏移的ModuleIndex；实现显式工作栈、原始指令编号、控制边界、FunctionFacts/MeterSite/FunctionPlan；区分共享SemanticPlan、候选结构InstrumentPlan及最终StackLayout，候选生成前冻结数量/签名/索引/模板，成本常量后填不得改变结构；稳定分配追加索引，登记export/start/element引用；预估重建容量并保证源AST不变。
- 验收：A01、A16：重复分析计划相同；import偏移与多值控制流正确；预留新项不改变旧数值索引；无函数内反复扫描全module。
- 不做：不引入通用SSA/优化器，不以哈希表遍历顺序决定site或输出顺序，不公开所有内部结构。
- 交接：`docs/evidence/S05.md`（执行时创建），包含实际命令、结果和产物标识。
- 提示词：[prompts/S05.md](prompts/S05.md)。

### S06 实现P0静态块计费与i64迁移

- 前置：S02, S04, S05；里程碑：U4。
- 范围：现有：fuel_pass.mbt、fuel_state.mbt、config.mbt、instrument_error.mbt、trap.mbt、Fuel测试；必要的CLI类型适配。
- 实现：按plan实现P0块入口内联；每函数复用i64临时local；比较后扣减，失败内联code/site/unreachable；迁移预算范围与报错，版本区分旧粗粒度产物；补分支、回边、长直线块、import偏移和原生trap前后边界。
- 验收：A02/A03、A16：独立预言机一致，两引擎执行核心用例；正常路径一次fuel读/写无新call和site写；失败位置确定；动态操作未完成时显式拒绝。
- 不做：不保留旧扣1作为静默fallback，不使用外部gas生成器，不因为类型迁移就宣称production-v1完整。
- 交接：`docs/evidence/S06.md`（执行时创建），包含实际命令、结果和产物标识。
- 提示词：[prompts/S06.md](prompts/S06.md)。

### S07 实现动态长度费用与溢出保护

- 前置：S06；里程碑：U4。
- 范围：现有：Fuel生成器及plan。拟新增：dynamic_cost.mbt和对应fixture/测试。
- 实现：实现允许bulk操作的unsigned长度拓宽、参数只求值一次、a+b*n检查及费用扣减；grow的动态模板作为供S08调用的组件，按规定资源检查后才收费；静态基础费用与动态附加费用不得重算。
- 验收：A04：0/1/边界/最大unsigned、b=0和乘加溢出用例与预言机一致；操作数和引用类型保持；输出通过独立验证；尚未组合的grow仍拒绝。
- 不做：不让FuelPass提前为grow收取应由资源检查之后收的费用，不把未知动态成本按固定1处理。
- 交接：`docs/evidence/S07.md`（执行时创建），包含实际命令、结果和产物标识。
- 提示词：[prompts/S07.md](prompts/S07.md)。

### S08 实现memory与externref table增长保护

- 前置：S07；里程碑：U5。
- 范围：现有：builtin_passes.mbt、config.mbt。拟新增：growth_pass.mbt及按签名复用的helper生成代码。
- 实现：实现初始超限拒绝、current与limit检查、unsigned delta<=limit-current；复用S07动态模板；上限内保留原grow返回-1且不退款；固定memory/table元素类型和参数顺序；funcref动态表继续拒绝。
- 验收：A09/A10：零、恰好上限、超1、大delta、初始超限、声明maximum导致-1及多限制同点失败；无新增import；两引擎结果符合各自原/插桩语义。
- 不做：不支持可变funcref表，不以signed负数判断替代unsigned容量判断，不复制一套不同的动态收费算法。
- 交接：`docs/evidence/S08.md`（执行时创建），包含实际命令、结果和产物标识。
- 提示词：[prompts/S08.md](prompts/S08.md)。

### S09 落实输入限制与导入策略

- 前置：S01, S05, S08；里程碑：U5。
- 范围：现有：policy.mbt、codec.mbt、config.mbt、instrument_error.mbt。拟新增：有界二进制预检、支持矩阵拒绝测试。
- 实现：实现production-v1允许表（取 [支持矩阵](implementation/support-matrix.md)）、限额（第 5 节暂定上限，边界值由 S20 压测冻结）及保留名称/重复标记检查；区分module/name二元组，明确CLI转义/拒绝策略；profile禁止项不能被allowlist放行；将大小/深度防护放在可能无界解码前，依赖缺口需修复或显式报告。
- 验收：A11/A15/A23：四类import、歧义、禁用特性（含 relaxed SIMD 与未列入允许表的 SIMD 指令）、畸形/过深输入都有明确错误；旧兼容路径有标记；有界预检实际覆盖解码前资源风险。（S25 起 A15 含全部 SIMD 指令的逐类拒绝边界）
- 不做：不静默放宽S01矩阵，不用解码之后的检查冒充解码资源保护，不接受缺规则指令。
- 交接：`docs/evidence/S09.md`（执行时创建），包含实际命令、结果和产物标识。
- 提示词：[prompts/S09.md](prompts/S09.md)。

### S10 实现最终代码栈成本分析

- 前置：S03, S05, S08；里程碑：U6。
- 范围：拟新增：stack_analysis.mbt、stack_layout.mbt、手算typed stack fixture；读取Fuel/Growth产物。
- 实现：实现参数/local/typed operand峰值及固定帧成本分析，v128 local 与 v128 操作数栈值按 16 字节保守计入（真实负载实测最多 48 个 v128 local），处理unreachable栈多态和multi-value分支；冻结覆盖P0/P1/P2模板族的统一C(f)，按实际布局计算A并构建期核验A<=C；顺序/互斥辅助路径取峰值，同时活跃的嵌套帧、挂起caller及存活wrapper相加且归属唯一；导出可审计的StackLayout，不需生成三个产品来求C。
- 验收：A05/A07：手算和独立fixture一致；原程序及新增local/helper均覆盖；无生成helper递归分析环；不支持形态明确拒绝。
- 不做：不只扫描push/pop，不把抽象单位说成物理字节，不在这片中扩展支持矩阵。
- 交接：`docs/evidence/S10.md`（执行时创建），包含实际命令、结果和产物标识。
- 提示词：[prompts/S10.md](prompts/S10.md)。

### S11 实现Stack改写与所有入口包装

- 前置：S09, S10；里程碑：U6。
- 范围：拟新增：stack_pass.mbt、wrapper生成与引用审计；现有：trap.mbt和plan。
- 实现：原始调用前预留统一C(callee)和逻辑深度，正常返回释放；生成export/start/element包装且防止双计；已预留helper不新增现场预算检查或逻辑深度；保持multi-value返回；覆盖wrapper入口余量、生成helper开销及内联失败诊断；按05落实错误顺序，完成受限call_indirect和全部允许引用的改写审计。
- 验收：A05-A08：大帧/递归/间接/早退/导出/start均受控；输出独立验证；正常多次调用计数恢复；受测安全范围内不先原生栈溢出。
- 不做：不在callee入口检查后就声称调用前保护，不给helper无限套wrapper，不继续使用trap后实例。
- 交接：[S11 实际命令、结果与产物标识](evidence/S11.md)。
- 提示词：[prompts/S11.md](prompts/S11.md)。

### S12 集成完整生产管线与不变式审计

- 前置：S06, S07, S08, S09, S11；里程碑：U6。
- 范围：现有：pipeline.mbt、builtin_passes.mbt、pass.mbt、codec.mbt、config.mbt及集成测试。
- 实现：集成分析/plan→Fuel→Growth→Stack；每步校验并在encode前再校验；统一原始/生成节点标记、诊断状态和模型ABI；最终审计import不变、引用完整、生成代码栈成本、重复插桩拒绝；只有全部所需配置可用才接受production profile。
- 验收：A01-A11、A15/A16/A23的核心组合测试；两引擎完整保护原型闭环；第三方pass组合不能自动获得生产保证；旧入口迁移有明确结果。
- 不做：不通过跳过validate优化性能，不用空Pass或占位返回值接受生产配置。
- 交接：[S12 实际命令、结果与产物标识](evidence/S12.md)。
- 提示词：[prompts/S12.md](prompts/S12.md)。

### S13 实现Linux产品runner与诊断生命周期

- 前置：S02, S12；里程碑：U7。
- 范围：现有：runner/、cmd/run/、相应moon.pkg；必要的依赖清单。
- 实现：把测试驱动能力落地为Linux wasmoon runner；默认_start和受支持export调用；显式WASI/import配置、禁止重入、认证栈配置检查；分类正常、资源trap、原生trap、timeout/cancel和初始化失败；诊断后废弃trap实例。
- 验收：A08/A13/A23：正常退出0、执行失败1、配置/输入/环境错误2；code0..5/未知值/start不可读不误判；wasm instrument构建仍不依赖native运行包。
- 不做：不新增公开Wasmtime runner、不做Windows native、不把timeout当Fuel成功拦截。
- 交接：[S13 实际命令、结果与产物标识](evidence/S13.md)。
- 提示词：[prompts/S13.md](prompts/S13.md)。

### S14 实现生产CLI、manifest与site映射

- 前置：S12, S13；里程碑：U7。
- 范围：现有：cmd/instrument/cli.mbt、file_pipeline.mbt、cli_wbtest.mbt；拟新增：确定性manifest序列化及site map。
- 实现：实现profile/model/fuel/stack/depth/resource/import/report参数和错误校验；为存在资源要求明确上限；输出工具/ABI/费用模型/栈模型/codegen版本、哈希、site映射和追加项目；区分静态manifest与运行报告，保留旧参数迁移提示。
- 验收：A16/A23：同输入配置重复输出相同；未知/冲突参数拒绝；诊断指向原始指令；时间戳不污染确定性manifest；摘要反映真实pass。
- 不做：不伪造测试通过状态，不承诺源码行号，不在本片顺便发布包。
- 交接：[S14 实际命令、结果与产物标识](evidence/S14.md)。
- 提示词：[prompts/S14.md](prompts/S14.md)。

### S15 实现可恢复文件交付与故障测试

- 前置：S14；里程碑：U7。
- 范围：现有：cmd/instrument/file_pipeline.mbt；拟新增：可故障注入的文件层与平台适配测试。
- 实现：同目录临时写入、默认拒绝覆盖；阻止输入输出同文件和路径别名；多文件以manifest最后写入为完成标记；失败清理仅限本次临时文件；实现权限、磁盘满、中途失败和哈希校验测试。
- 验收：A21：已有文件哈希不变；无有效完整manifest；消费者拒绝缺失/不匹配产物；实际可用平台文件API不足时明确阻塞，不能模拟成功。
- 不做：不宣称跨文件原子事务，不删除用户原文件或用跨shell递归清理。
- 交接：[S15 实际命令、结果与产物标识](evidence/S15.md)。
- 提示词：[prompts/S15.md](prompts/S15.md)。

### S16 完成具名差分语料与演示

- 前置：S04, S13, S15；里程碑：U8。
- 范围：拟新增：integration/corpus、真实MoonBit fixture、对应构建与运行脚本、差异清单。
- 实现：完成60个具名用例、20个控制流/栈边界，对 S01 已冻结的 F0–F3 四个真实产物（基线 + 数据解析/解释器递归/计算密集）做完整插桩验证，实际执行其字符串/数组处理路径（S25 起负载为零 SIMD 标量实现）；原/插桩逐引擎比较与严格子集跨引擎比较；WASI/NaN/分配失败单列；为支持矩阵中 `CONDITIONAL` 特性（memory.init/data.drop、externref table 增长、ref.null/is_null）补合成用例；制作同迭代次数长短循环体费用不同、有限计算提高预算完成、无限循环始终Fuel终止、深递归与浅调用大帧分别受控、资源增长边界demo。
- 验收：A01-A13/A15/A16/A21/A23覆盖矩阵有caseID；正常结果及受控code/site/前缀一致；0个未解决实现差异；每例输入/命令/预期可复现。
- 不做：不把允许差异当未解释缺陷忽略，不减少支持特性来隐藏实现错误，不说无限循环加预算可完成。
- 交接：`docs/evidence/S16.md`（执行时创建），包含实际命令、结果和产物标识。
- 提示词：[prompts/S16.md](prompts/S16.md)。

### S17 生成变异语料与统一验收入口

- 前置：S16；里程碑：U8。
- 范围：拟新增：测试生成器、缩减驱动、统一验收脚本/包和机器可读报告；文档09、11。
- 实现：固定生成配置/种子，至少10000个不同有效支持域内输入进入插桩执行验证；拒绝语料另计；反例最小化回归；统一入口支持门禁分组，输出PASS/FAIL/BLOCKED/NOT_RUN，失败退出1、环境/未实现退出2；性能和发布尚未完成时整体不能PASS。
- 验收：A14/A15及A24工具基础；样本去重和实际执行数可审计；故意注入失败/缺工具/未实现时入口正确失败；报告覆盖24项但不伪造未完成项。
- 不做：不通过生成10000个非法模块凑数，不写只打印PASS的脚本，不以外部硬超时当成功。
- 交接：`docs/evidence/S17.md`（执行时创建），包含实际命令、结果和产物标识。
- 提示词：[prompts/S17.md](prompts/S17.md)。

### S18 建立P0性能基线与冻结数据集

- 前置：S17；里程碑：U9。
- 范围：拟新增：bench/或等价性能harness、原始数据schema、调优/验收语料清单、阶段计时。
- 实现：固定硬件/引擎/参数；分离调优集和保留验收集，在调优前冻结哈希；仅在调优集测原模块/Fuel-only/完整P0，覆盖业务生命周期（含core start）和适用热调用窗口，记录构建阶段、体积和内存；实现进程分组采样、95%区间和p95规则；最终保留集在S21启用，保存原始样本。
- 验收：A17/A19/A20测量工具可复现且校验结果；所有统计有原始数据；当前P0超标如实FAIL；P1/P2未完成不计最终验收。
- 不做：不更换负载掩盖开销，不在建立基准时降低2x/3x门槛，不把引擎编译耗时混入纯执行指标。
- 交接：`docs/evidence/S18.md`（执行时创建），包含实际命令、结果和产物标识。
- 提示词：[prompts/S18.md](prompts/S18.md)。

### S19 实现本项目P1共享计费候选

- 前置：S18；里程碑：U9。
- 范围：本项目codegen/plan/StackLayout和benchmark；拟新增：共享charge模板。
- 实现：以同一费用模型和site生成共享本地charge(cost,site)；不新增import；重新计算调用参数、helper帧和失败路径的A并核验统一C，不改用户收费或增helper检查；保持预算语义/输出前缀；在调优集对比P0并保留失败候选数据。
- 验收：A01-A16受影响项通过；P0/P1相同预算语义；新增栈成本已审计；有本项目源码位置和产物哈希；性能结果真实。
- 不做：不调用外部gas工具，不因为P1较慢就隐藏结果，不以不同费用表制造优势。
- 交接：`docs/evidence/S19.md`（执行时创建），包含实际命令、结果和产物标识。
- 提示词：[prompts/S19.md](prompts/S19.md)。

### S20 实现本项目P2静态混合候选

- 前置：S19；里程碑：U9。
- 范围：本项目codegen选择规则、manifest codegen版本、StackLayout和调优实验。
- 实现：仅依据原模块静态特征在P0/P1间选择；用调优集冻结P2规则/阈值，按09比较各引擎和计时窗口的合格P0/P1/P2，选定并冻结默认布局、源码及模型哈希；生成后重算A并核验统一C，同输入配置确定性输出；最终保留集仅供S21确认，不参与规则或默认选择。
- 验收：A16/A18：规则可解释、固定、无机器依赖；包括临界预算的语义与P0/P1一致；阈值和默认仅来自调优集；有最终验收前的冻结凭据；无调优合格候选则不得进入最终验收。
- 不做：不预设P2胜出，不运行时自适应改变收费，不将测试集信息隐藏进启发式。
- 交接：`docs/evidence/S20.md`（执行时创建），包含实际命令、结果和产物标识。
- 提示词：[prompts/S20.md](prompts/S20.md)。

### S21 独立验收冻结默认布局的完整保护性能

- 前置：S29（M5 为本片的等价入口，提示词见 [prompts/M5.md](prompts/M5.md)）；里程碑：U9。
- 范围：bench/、统一验收入口、原始报告及默认codegen配置。
- 实现：对冻结独立验收集在两引擎确认S29已冻结默认的完整保护，生命周期和适用热调用窗口分别比较95%上界、中位数/p95、体积、构建时间/内存；可报告其他候选对照，但不得据此切换默认；默认失败时保留结果，回到调优并另建独立确认集，产物改变重跑受影响正确性。
- 验收：A17-A20真实结果完整；冻结默认在每引擎/窗口分别几何平均上界<=2x、逐项中位数/p95<=3x且体积达标；默认失败即本片未通过，其他候选不能替代；全体调优候选和最终对照数据可审计。
- 不做：不删除保护或跳校验过关，不静默放宽门槛，不以单个快引擎抵消另一个引擎。
- 交接：`docs/evidence/S21.md`（执行时创建），包含实际命令、结果和产物标识。
- 提示词：[prompts/S21.md](prompts/S21.md)。

### S22 完成迁移、包与干净环境复现

- 前置：S21；里程碑：U10。
- 范围：现有：moon.mod、README、THIRD_PARTY、NOTICE、docs/04、11；拟新增：迁移说明与安装复现记录。
- 实现：同步已验证能力和新minor/模型ABI迁移；核对依赖许可、包内容和dry-run；准备本地包并在干净环境构建/运行真实fixture，验证moonx可执行分发路径；未公开版本的远程安装不能假装已验证，明确发布后检查项。
- 验收：A22/A23发布前证据齐全；实际包安装构建可复现；旧产物识别可靠；远程发布后检查单独标NOT_RUN且生产最终状态不得冒充PASS。
- 不做：不实际publish、push、tag、发消息或提交报名表；这些不属于本次任务分片授权。
- 交接：`docs/evidence/S22.md`（执行时创建），包含实际命令、结果和产物标识。
- 提示词：[prompts/S22.md](prompts/S22.md)。

### S23 独立复核并汇总验收报告

- 前置：S22；里程碑：U10。
- 范围：只读复核默认；docs/11实例化报告、统一验收输出、所有源码与产物证据。发现代码缺陷回到所属分片修复。
- 实现：核查A01-A24实际命令、结果、commit/工作树快照和产物哈希；复跑关键边界与基准可复现性；检查数据集隔离、生成代码栈成本、诊断和失败文件行为；汇总通过/失败/阻塞/未执行项及剩余发布后动作。
- 验收：A24：每个PASS有证据且独立复核能重现；缺远程发布后证据时最终保留NOT_RUN/BLOCKED；出具可用于申报的真实阶段结论。
- 不做：不把文档写完当实现完成，不自动发版，不为获得全部PASS删测试或涂改未执行状态。
- 交接：`docs/evidence/S23.md`（执行时创建），包含实际命令、结果和产物标识。
- 提示词：[prompts/S23.md](prompts/S23.md)。

### S24 固化S20证据基线与实验分支记录（M0）

- 前置：S19；里程碑：U9。
- 范围：main 工作树相对 b6a4783 的全部未提交变更（S20 与 S20-prefix 工作约 2,294 行插入）；docs/evidence/S20.md、S20-prefix.md、S20-freeze.json 与 `_build/s20*`；三个实验工作树 `../moonwasm-fuelguard-experiments/`（compact-fuel、shared-stack、weighted-prefix，均停在 b6a4783 带未提交实验）。
- 实现：逐文件审计 main 工作树与 b6a4783 的差异，核对 S20.md、S20-prefix.md 的命令、产物哈希与归档可重放；把三个实验工作树的候选结果整理为 A18 保留候选记录——至少包含 shared-stack 的 `decision.json`（p2-loop-inline：A19/A20 PASS、A17 最差几何上界 5.27x）、formal/fuel 试点报告、compact 家族体积检查数据与 weighted-prefix 的实现状态（未测）——逐条注明来源工作树路径与未提交状态；标记可复用件（weighted-prefix 树 `weighted_prefix.mbt` 的冷路径权重回放、compact 树的 span helper 结构，复用发生在 S26）；产出 main 的提交文件清单与提交说明草案。提交与推送须用户单独确认（AGENTS.md 约束）；未获确认时仅交付清单与审计结论，不执行 git 提交。
- 验收：evidence/S24.md 记录全部候选原始数据索引、实验工作树状态快照与可复用件清单；main 提交完成或明确记录未获提交授权；三个实验分支/worktree 原样保留。
- 不做：不把实验代码合并进 main；不删除、不重置、不推送实验 worktree；不改任何门槛数值。
- 交接：`docs/evidence/S24.md`（执行时创建），包含实际命令、结果和产物标识。
- 提示词：[prompts/M0.md](prompts/M0.md)。

### S25 SIMD范围收敛与语料重建（M0.5）

- 前置：S24；里程碑：U9。
- 范围：cost_model.mbt、cost_model_wbtest.mbt、fixtures/workloads/*、bench/dataset.py、integration/generated/recipes.py、integration/generated/reject.py、integration/corpus/check.py、docs/implementation/support-matrix.md、docs/05、09、12、THIRD_PARTY.md。
- 依据：申报书 docs/04 第 35 行把 SIMD 列入首版范围之外，申报书不可修改（用户 2026-11-18 决策），S01 的"16 条 SIMD 纳入"决议作废。实测占比：F1 47 条、F2 53 条、F3 12 条（各约 0.2%），F0 为零，来源均为库依赖（json5、lisp_interpreter、crypto 及核心库向量化字符串操作）。
- 实现：从 cost_model.mbt 摘除全部 SIMD 条目（Barrier 表的 v128.load/store 与 base-2 Prefix 的 v128/i8x16/i16x8/i32x4/i64x2 各条），拒绝沿用既有 "opcode outside fuel-v1 pricing allowlist" 路径；cost_model_wbtest 的权重断言改为拒绝断言；recipes.py 的 SIMD 配方移出有效样本并入 reject.py 作 A15 拒绝用例（16 条逐类边界）；corpus/check.py 的 simd_path 改为拒绝验证；support-matrix.md 第 4 节与 docs/05（V1 表）、09（V1/V6 行）、12 第 4 节中"16 条 SIMD"的表述统一改为"SIMD 全部拒绝，边界用例归 V6"；用 `moon build --output-wat` 定位三个负载的 v128 发射点，把库依赖替换为 vendored 标量实现（标量字符串比较、标量 sha256），重编译并逐字节核验零 SIMD，vendored 库登记 THIRD_PARTY.md（moonbitlang/x 系 Apache-2.0）；在全新目录运行 bench/dataset.py 重建 dataset.json、记录新哈希并更新 S01 冻结记录，五个 holdout 同步重建；旧语料（含 SIMD）上的 S18-S20 数据声明为历史记录，正式门禁全部改在新语料上执行；跑 moon test --target wasm 全绿与 A16 三次构建一致性。
- 验收：production-v1 对含任何 SIMD 指令的输入显式拒绝且 16 条逐类有边界用例；四负载与五 holdout 零 SIMD、插桩执行输出与期望逐字节一致；语料重新冻结且新旧哈希均记录在案。
- 不做：不改申报书；不动 stack-v1 的 v128 保守计入条款（避免触发栈模型版本变更）；不重写 07/09 的门禁数值；不用旧语料数据冒充新语料结果。
- 交接：`docs/evidence/S25.md`（执行时创建），包含实际命令、结果和产物标识。
- 提示词：[prompts/M0.5.md](prompts/M0.5.md)。

### S26 fuel-v1.2合并计费块划分与性能试点（M1）

- 前置：S25；里程碑：U9。
- 依据（实测，2026-11-18）：S20 消融显示完整保护与 Fuel-only 差距仅约 5%（wasmoon 热 F1 9.35x vs 8.93x），开销主体是扣费本身；F1 的 p2-prefix 产物 code 段含 13,846 条 i64.lt_s 扣费序列对 29,595 条计费指令（平均 span 约 3 条，热循环校准约 2.6 条），每 span 内联 9 指令，wasmoon 线性模型 1+9/span_len 与实测 4.41x 吻合。根因是 fuel-v1 边界表把每个 Barrier（load/store/global.set/call/结构指令）当 span 终点，属实现过度保守；docs/05 第 55 行明确"保守边界不要求每条 load/store 或可能 trap 的指令独立收费，具体边界表随模型冻结"，docs/04 第 18/29 行的口径是"加权计费块预扣"。MoonBit 产物的控制流汇聚点密度（F1 约 2.5K：1,165 个 if 臂、约 400 个 br 目标、108 个 loop 头、262 个函数入口）支持 join-span 平均长度约 12 条指令，预计站点数降 4-5 倍。
- 范围：cost_model.mbt（边界表）、fuel_state.mbt、compact_fuel.mbt、fuel_pass.mbt、pipeline.mbt、manifest_details.mbt、artifact_marker.mbt、cmd/instrument（版本与拒绝）、integration/fuel_oracle（仅划分重推导入口，实现在 S27）；可复用 S24 标记的 weighted_prefix.mbt 冷路径回放与 compact span helper。
- 实现：发布版本化边界表 fuel-v1.2——权重表、i64 预算、动态费用与陷阱指令级位置语义不变，仅块划分规则变更为 join-span：span 为最大"必然顺序执行"直线索材，起点为函数入口、条件臂入口（if 的 then/else 体）、loop 头、br/br_table 目标标签与动态操作站点；段内可穿越全部非控制 Barrier（load/store/global.set/div/mul/浮点/call 等，静态费用计入段总费用，call 的栈检查仍在调用点自身）；br/br_if 指令本身计入所在 span，br_if 后的条件落穿处是新 span；span 长度上限由冷路径权重 profile 编码宽度决定，超限段在边界保守切开且仍精确；全部候选共用同一划分（docs/05 要求），profile 打包编码随版本冻结。热路径内联不超过 8 条指令、W 常量只编码一次、不追加临时 local（参考 debit-first 形态：global.get / i64.const W / i64.sub / global.set / global.get / i64.const 0 / i64.lt_s / if{冷路径}；须给出"操作数与预算均 < 2^63 才可用带符号下溢判据"的不变式与预算上界校验，禁止把未验证的回绕当正常费用）。冷路径为每模块至多一个共享失败 helper，收 (site, 预算, profile)，按权重逐条回放：paid 为可付前缀、fuel 扣除 paid、trap site = 首站点 + 已付指令数，保持指令级诊断精度。artifact marker、manifest 与 CLI 记 fuel-v1.2，拒绝旧 fuel-v1 产物伪标，迁移说明写明划分差异、预言机重推导入口与旧产物处置。试点：在冻结 Linux 环境（沿用 S18 硬件、引擎、预算与种子）对新语料 F0-F3 跑 30 样本×3 进程试点，对照 original 与既有 p2-prefix，输出 span 长度分布与热点函数划分统计。
- 判据（本片成败点）：F1 wasmoon 热调用中位数比 ≤2.2x。达标进入 S27；若 ≥2.5x，先输出热循环汇聚密度解剖（span 长度分布、热点函数的站点数）并停下向用户报告，不硬推。
- 验收：模型、manifest、CLI 三处版本一致且互相拒绝错配；A16 同输入同配置三次构建同哈希；试点报告含双引擎数字与 span 统计，判据结论明确（达标/解剖/停止）。
- 不做：不改 2x/3x/2x 门禁数值；不用保留集调参；不引入外部计费后端；不新增 import；不把未执行 span 的分支计费（loop 头按体总扣的摊销路线违反 docs/05"不能把未执行分支收费"，禁止）；不在本片关闭 A17。
- 交接：`docs/evidence/S26.md`（执行时创建），包含实际命令、结果和产物标识。
- 提示词：[prompts/M1.md](prompts/M1.md)。

### S27 fuel-v1.2正确性重推导（M2）

- 前置：S26；里程碑：U9。
- 范围：integration/fuel_oracle、integration/p1/check.py、integration/corpus/check.py、integration/generated/*、integration/stack_pass、integration/pipeline、integration/runner、全部 wbtest 与具名用例。
- 实现：独立计费预言机升到 fuel-v1.2 划分（不改权重与动态费用）；新增边界用例：span 穿越 load/store/global.set/call 的扣费与陷阱位置、预算恰在 span 内第 k 条指令处耗尽的 trap site 与 paid、span 中途原生 trap 的预扣过付、C-1/C/C+1 与 i64 上界全覆盖、动态操作（memory.copy/fill/init、grow、table 系列）仍独立站点与失败优先级、冷路径部分扣费与诊断写序、br_if 条件落穿与 loop 回边入口站点；A16 三次构建一致；10,000 个新种子生成/变异样本（新语料）双引擎执行与受控陷阱核对；具名差分 60 用例（含至少 20 控制流/栈边界）双引擎原/插桩对照；`moon check --target wasm --deny-warn`、`moon test --target wasm` 全绿，结束时 `moon info && moon fmt` 并审查 .mbti 差异；A≤C 栈审计沿用 stack-v1，核对缓存布局新增的 i64 local、helper 与 wrapper 共用相同 C。
- 验收：A02/A03/A04 边界值在 v1.2 语义下通过；A14 语料数量与覆盖不低于旧版；V1/V4 相关既有用例零未解决差异；.mbti 变化与预期一致。
- 不做：不为凑过预言机改预言机语义；不删旧 fuel-v1 用例（保留为迁移对照）；不用"能加载"替代执行验证。
- 交接：[S27 验收证据](evidence/S27.md)，包含实际命令、结果和产物标识。
- 提示词：[prompts/M2.md](prompts/M2.md)。

### S28 体积与构建门禁收敛（M3）

- 前置：S27；里程碑：U9。
- 范围：fuel/stack/growth 代码生成序列、cmd/instrument CLI、bench 体积与构建账本。
- 实现：在新语料上实测 F0-F3 的 A19（≥10KiB 模块体积比 ≤2x、小模块新增 ≤10KiB，sidecar 另报）与 A20（沿用 10 s 与 524,288 KiB 上限及分阶段账本）。优先核对 F2 与 F3，冻结清单中两者原件分别为 10,268 B 和 10,219 B。字节收敛顺序为热路径单 W 常量与紧凑冷路径编码 → 冷函数（仅静态特征：函数无 loop 且静态调用图不可达自任何含 loop 函数）改共享调用站点 → 栈检查序列字节精简。每步改动后重跑 A17 试点确认热路径时间无回退（允许噪声内波动，回退即撤回该步）。A20 沿既有三档分阶段构建账本重测。
- 验收：四负载 A19、A20 有真实判定（PASS，或 FAIL 时记录超差字节数与已试步骤）；任何字节换时间的改动都有前后 A17 试点对照数据。
- 不做：不删保护或跳校验换体积；不把 sidecar 并入体积统计口径；不为 A19 反向牺牲 A17。
- 交接：[S28 证据](evidence/S28.md)，包含实际命令、结果和产物标识。
- 提示词：[prompts/M3.md](prompts/M3.md)。

### S29 正式布局重跑与默认冻结（M4）

- 前置：S28；里程碑：U9。
- 范围：bench/run.py、bench/summarize.py、docs/evidence/S20 系列、docs/07 状态表、冻结凭据。
- 实现：在冻结 Linux 环境对全部候选（P0、P1、P2、p2-prefix、fuel-v1.2 新候选）执行正式 300 样本×3 进程交错布局比较，A17/A18/A19/A20 全门禁判定，保留全部候选原始数据（禁止只报胜者）；A16/A18 正确性证据齐备后，若 performance_eligible 含合格默认，则冻结默认布局、规则、阈值、源码与模型哈希（冻结时间早于 S21），更新 07 状态表与 evidence；若仍无合格默认，保留全部数据与 FAIL 状态并停止，把"按 docs/09 第 3 节作为独立需求变更评审门槛"的决策连同完整数据交用户，期间不得改默认、不得用其他候选的通过结果替代。
- 验收：performance_eligible 与冻结凭据完整可审计，或 BLOCKED 状态与数据链完整；A17 判定用的置信区间上界与补采规则符合 docs/09 第 8 节。
- 不做：不静默放宽门槛；不用独立验收集反向调参或换默认；不在本片宣称 production-v1。
- 交接：[S29 证据](evidence/S29.md) 与 [机器裁决记录](evidence/S29-decision.json)，包含实际命令、结果和产物标识，并入 S20 系列记录。
- 提示词：[prompts/M4.md](prompts/M4.md)。

## 5. 所有分片的共同完成要求

1. 前置接口和证据可核验，代码保持可构建；尚未实现能力明确拒绝。
2. 本片新增行为有意义的边界/运行验证；环境受限时保留NOT_RUN，不以静态校验代替执行。
3. 典型代码检查为moon check --target wasm --deny-warn、moon test --target wasm；native适配另在Linux执行native检查和双引擎用例。结束时moon info、moon fmt并审查.mbti。
4. 证据包含源码commit及未提交快照哈希、真实日期/命令/退出码、版本、caseID、输出哈希、失败和剩余项。无需为了记录commit而自动提交。
5. README只在能力真实完成时更新；需求/架构不可为凑PASS被静默缩减。
6. 每片可单独审查，后续修复回到原责任分片；生成代码改变后重新检查栈成本与相关性能，不能沿用不匹配产物的证据。

## 6. 阻塞、发布和申报

缺Linux、工具或前置接口时列出可复现阻塞和可继续部分；不引入替代生产宿主绕过既定架构。性能无合格候选时保留FAIL，依据本项目热点改进，禁止降低保护强度。

S22为发布准备，不包含外部发布。A22中公开mooncakes/moonx远程获取如需新版本发布，作为独立发布后验证保留NOT_RUN；本计划不授权publish、push、tag或提交报名表，S23不能因此伪造全部PASS。

官方反馈的重新申报期限为2026-11-30。日期不等于实施工期承诺；届时只能提交已验证成果和明确的未完成项。生产通过要求A01-A24全部满足，不能靠文档修改关闭。
