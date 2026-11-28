# FuelGuard F1 性能攻坚

2026-11-19，北京时间。实验在 `feat/s26-join-span` 既有候选上开展。判据为
F1 wasmoon 热调用完整保护中位数相对原版 ≤2.2×。保留 S26 的数据和产物。

## 历史依据

| 记录 | 影响本轮的结果 |
| --- | --- |
| S18 P0 | 逐指令内联使 wasmoon 热调用应用几何均值达到 7.06×，体积及最大构建规模超限。 |
| S19 P1 | 共享收费 helper 收敛了部分体积和构建时间，A17 仍失败，最大构建 RSS 超限。 |
| S20 P2 | 混合选择和共享 Stack 相关候选改善构建或体积，正式执行门禁仍失败。 |
| S20 精确前缀 | 合并单价纯前缀显著改善性能和构建开销，wasmoon 热调用应用几何均值仍为 2.70×，旧语料 F1/F2 较慢。 |
| S24 实验保留 | 共享 Stack、逐站点 debit-first 和循环位置混合布局的失败结果保留。混合权重前缀当时未测。 |
| S25 | 换为 SIMD-free 冻结语料。S18–S20 的比值只作为历史线索。 |
| S26 | join-span 在新语料 F1 测得 3.285×，其中 76.9% 的动态扣费发生于长度 1–5 的 span。 |

证据链接 [S18](S18.md) · [S19](S19.md) · [S20](S20.md) · [S20 前缀](S20-prefix.md) · [S24](S24.md) · [S25](S25.md) · [S26](S26.md)

## 定向实验

F1 热调用定向实验沿用 S26 归档中逐字节相同的 worker 和 Wasmtime 库，
绑定同一 vCPU，按每引擎三进程 × 30 计时样本交错运行。每轮中位数与该轮
原版比较。不同轮环境噪声以同场 `join-span` 对照反映，原始记录完整保留。

| 对照 | 同场 wasmoon `join-span` | 实验 wasmoon | 实验 Wasmtime | 结论 |
| --- | ---: | ---: | ---: | --- |
| `fuel-v1.2` Fuel-only | 3.437× | 2.218× | 2.580× | 完整保护比 Fuel-only 多 3.400 ms。Stack/Growth 有值得单独验证的空间。 |
| 静态扣费 `local.tee` 替换第二次 global 读 | 3.229× | 3.495× | 2.800× | 单独变差，重复替换全局读尚不足以节省时间。 |
| 负立即数加法替代减法 | 3.229× | 3.454× | 2.973× | 两引擎结果没有支持这条路线。 |
| 打包 Stack，显式 `i64.ne` 判断 | 3.321× | 2.761× | 2.661× | 两引擎均改善，保留为组合基础。 |
| 打包 Stack，倒置条件和 `else` 冷路径 | 3.321× | 2.839× | 2.856× | 同场较常规写法慢。 |
| 打包 Stack 加静态扣费 `local.tee` | 3.321× | 2.614× | 2.722× | wasmoon 受益，单项结果无法相加预测。 |
| 打包 Stack 加闭合叶调用检查 | 3.355× | 2.337× | 2.602× | 去掉叶调用的计数器往返仍有明确收益。 |
| 再加函数内 Fuel 缓存 | 3.355× | **2.071×** | 2.457× | 达到目标的最强 wasmoon 探针。 |
| 小叶函数内联探针 | 3.355× | 2.181× | **1.989×** | 同场 Wasmtime 最快，wasmoon 余量较小，且要额外审计调用与栈布局。 |
| MoonBit 初始 `join-span-cached` | 3.165× | **2.026×** | 2.340× | 复现探针收益。后续发现其初始 Stack 全局值无法通过产品 runner 校验。 |
| 入口延迟打包的最终产物 | 3.555× | **2.104×** | 2.320× | 原 S26 worker 定向运行达标，同一产物通过产品 runner。 |

消融数字表明 Stack/Growth 组合开销明显。进一步打包及闭合叶调用对照把
可节约的一部分定位到原调用点更新。函数内缓存带来相对于叶调用对照的
额外收益，和单次 `local.tee` 替换结果形成反例。WAT 探针删去产物生产 marker，
独立校验后交给冻结 worker，仅用来决定哪些方案值得用 MoonBit 实现。

实现选择 `join-span-packed-cache-v1`，镜像 CLI 选项为 `--codegen join-span-cached`。
该候选与冻结 `join-span` 共用 fuel-v1.2 边界表和费用。函数内缓存、打包上限、
低位借位、冷路径顺序与栈审计见 [边界表](../implementation/fuel-v1.2.md#缓存布局及-stack-预算打包)。

原生入口反例发现初始打包在实例化前被 runner 的预算校验判为超限。最终版
保留原有两个声明值，在首次导出或 start 包装器入口安装打包状态，重入时
沿用该状态。初版整轮 2.055× 和原生入口拒绝保存在 `initial-packed/`。
入口修复后，用重建 worker 的整轮结果为 2.226×，保存在 `rebuilt-workers/`。
这两个目录保留各自的报告、原始账本和环境摘要。

## 完整保护复测

**F1 中位数目标 PASS。** F1 wasmoon 热调用从 S26 的 **3.285×** 降到
**2.090×**，配对 bootstrap 95% 区间 **[1.987×, 2.210×]**。本轮中位数
低于 2.2×，置信上界略高于 2.2×。同轮原版、`join-span` 和
`join-span-cached` 的中位数为 2.850、9.458 和 5.957 ms。
与同轮 `join-span` 相比缩短 37.0%。

| 负载 | wasmoon 生命周期 | wasmoon 热调用 | Wasmtime 生命周期 | Wasmtime 热调用 |
| --- | ---: | ---: | ---: | ---: |
| F0 hello | 2.091× | 1.098× | 1.099× | 1.117× |
| F1 JSON5 | 2.318× | **2.090×** | 2.310× | 2.274× |
| F2 Lisp | 1.935× | 1.930× | 2.445× | 2.559× |
| F3 SHA-256 | 1.910× | 1.799× | 2.130× | 2.154× |

复测在冻结 Linux `FuelGuard-S26` 以四个变体串行、交错采样，保留 7,920 个
计时样本、1,320 个预热样本及 264 条编译记录。确认每一档的原版、
`p2-prefix` 和旧 `join-span` Wasm 与 S26 归档逐字节一致，两个 v1.2 布局
的源站点和 span 边界也相同。重建同版本、同源码的 wasmoon worker 后所得
的结果保留于 `rebuilt-workers/`。本表使用 S26 归档内逐字节相同
的两个 engine worker 和 Wasmtime C API 库。`frozen-workers.json` 存有 S26
环境记录，回放校验环境摘要及二进制身份。相同产物的独立 F1 定向复测为
**2.104×**。

本轮最大输入构建耗时 5.759 s、峰值 439,740 KiB，试点 A20 通过。
重建 worker 的两轮构建 RSS 分别为 541,112 和 782,420 KiB，均超限。
A19 体积仍超限，A17 正式门禁为 `NOT_RUN`。最佳候选使用独立布局名。

```bash
export MOON_HOME=/root/s26-frozen-moon
export PATH="$MOON_HOME/bin:/opt/fuelguard-s26/bin:/usr/bin:/bin"
export LC_ALL=C
python3 -B bench/run.py --compare-join-cached --out _build/fuel-opt-pilot-frozen-workers \
  --frozen-workers /root/fuelguard-s26-locked/_build/s26-pilot-final \
  --host-record /mnt/d/moonwasm-fuelguard/_build/s26-tools/host.json \
  --wasmtime-c-api /root/s26-tools/wasmtime-v50.0.0-x86_64-linux-c-api
python3 -B bench/summarize.py _build/fuel-opt-pilot-frozen-workers --out _build/fuel-opt-frozen-workers-report.json
```

## 产物和可复现性

冻结编译器和 `wasm-tools` 校验的 F1 CLI 三次构建均与独立 native builder
的试点产物逐字节一致。交换两个 v1.2 布局的 manifest 并更新摘要后，CLI
仍双向拒绝 marker 错配。报告由原始样本再次生成，字节一致。

Windows 归档目录为 `_build/fuel-opt-evidence/`。定向实验归档包含实跑
各轮的配置、命令、采样、产物和探针代码。旧 `ablation.sh` 首次测量参数
顺序被解析器拒绝，后续实跑将 `join-fuel=...` 放在 `--engines` 前。
首个热模板批次包含七个变体，超出冻结 worker 的五变体上限，随后按
`run-shapes.sh` 分成两轮。

| 文件 | SHA-256 |
| --- | --- |
| `report.json` | `1402a9480d328d33c7fd3ea7972ae7c513e42d0cab06bdea74a7c4102afb1133` |
| `samples.jsonl` | `f1c0d7845542f7b34e2283eb75cb2e5be1020f1f7e9e0aef6c9e28eeb3e9bafc` |
| `environment.json` | `f6f2715053398051646d3977e3576dca1dde50f3b97258a3ba69e1d98591e55d` |
| `frozen-workers.json` | `67c4ff9963813333f8051be130667f56202649990cb5ae9fd7a5bf6ad8a0d427` |
| `raw-pilot.tar.gz` | `f14cd75aee907a981dd034dd65f7e9f0379bcc59829c4ab92f881d59bf73c8cd` |
| `directed-experiments.tar.gz` | `6ee77b55accd01a4d8cd2ab997c043d4373e2add529921c38a3c305710442426` |
| F1 `join-span-cached` Wasm | `f2ebd4b1733fb5a4f788092b870748003ccc6051cf295052a7879efe9825ae36` |
| F1 `join-span-cached` manifest | `78df789ad36ff580601a0e9e1b8a20a5f35df24af91e7d0bba6e45fc70c47d83` |

## 语义与入口复核

`python3 -B integration/fuel_cache/check.py --out _build/fuel-cache-correctness-final`
在 wasmoon 0.18.0 默认 JIT 测试模式和 Wasmtime 50.0.0 上各通过 38 个
WAST 用例。同一组手算预期覆盖两种布局，比较返回、陷阱码、源指令站点和
精确余额。覆盖显式及分支返回、`br_if`／`br_table`、预扣后的原生除零陷阱、
首个不可支付指令、bulk 动态费用、间接调用以及导入回调重入。Stack 用例覆盖
叶与非叶的同时不足优先级、恰好足够、深度不足、31 位边界和 i64 上限回退。
测试 observer 对副本暴露余额，正式候选的私有预算和导出合约按原接口验证。
Linux 原生 `cmd/run` 实际运行 F1 并核对完整输出，还核对了 Fuel `code=1 site=9`
以及 Stack `code=4 site=2` 两条受控陷阱。50,080 组边界及种子数值对照另外
覆盖打包借位、失败优先级、恢复和正常预留。

Windows 通过 `moon check --target wasm --deny-warn`、`moon test --target wasm`
及 `git diff --check`。冻结 Linux 同样通过 104 项 Wasm 单测，并保留了
S26 已记录的 CLI `cancellable_defer` 基线警告。S27 独立预言机和正式发布
门禁仍按原验收口径执行。

| 边界证据 | SHA-256 |
| --- | --- |
| `correctness-final.log` | `8d36be64ef67bdf69a0a99c936e498681fd32638afcc28a5f4fd271e47a8bc71` |
| `correctness-artifacts.tar.gz` | `a62e970ac02b7dde5bb49c83576a249bbfead9d31ffb7f5fa729ea6d3a65a8db` |
