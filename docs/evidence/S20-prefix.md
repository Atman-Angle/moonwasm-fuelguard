# S20 续调 · 精确前缀扣费

本轮候选为 `--codegen p2-prefix`，产物标记为 `p2-prefix-exact-v1`。
沿用 [S20](S20.md) 的调优集、栈预算、价格表、动态费用及诊断 ABI。
调优集清单 SHA-256 为
`de53b10ea85e3d714112fe46873135f563a58fa870b65bc40665b5efff37faa7`。
S21 保留集只核对文件大小与摘要。

同一个指令序列中的连续单价纯前缀和至多一个末尾指令共享一次扣费。
末尾指令之后重新分析，包括结构指令的内部序列。动态费用在原操作处独立
检查，Growth 继续先检查容量。设已有预算为 B，单价纯前缀长度为 N。
不足时，冷路径扣除 `min(B, N)`，报告首站点加这个偏移。前缀中的
读操作、局部量操作和不陷阱算术没有可见副作用，因此提前失败保留原诊断、
预算余量和可见输出。生成的冷 helper 计入统一 C，实例在陷阱后退役。

分析阶段复用函数事实生成站点表，生产构建省去重复的站点对象。
公开分析 API 仍能返回完整站点结构。Wasm 每轮校验和最终栈审计继续执行。

## 调优构建

| 调优应用 | 既有 P2 字节 | 精确前缀字节 | 缩小 |
| --- | ---: | ---: | ---: |
| F0 hello | 58,410 | 23,729 | 59.4% |
| F1 JSON5 | 995,725 | 609,460 | 38.8% |
| F2 Lisp | 1,053,293 | 570,807 | 45.8% |
| F3 SHA-256 | 147,340 | 76,086 | 48.4% |

四个应用的体积仍超 A19。4 MiB 最大输入的 CLI 耗时从 7.007 s 降到
3.734 s，峰值 RSS 从 624,100 KiB 降到 408,136 KiB。本轮构建满足 A20
的 10 s 和 524,288 KiB 两项上限。九个旧 P2 调优产物与 S20 原归档字节一致。
最大档的 native 栈框审计中位数从 0.764 s 降到 0.263 s，Fuel 输出校验从
0.103 s 降到 0.033 s。构建账本保留三个尺度的各阶段时间和 RSS。

## 双引擎计时

在冻结调优集上交错运行原版、旧 P2 和精确前缀候选。每个窗口用三个独立
进程，每进程每变体预热五次、测量 30 次。共保留 5,940 个正式样本和
990 个预热样本。下表为四个应用相对原版的中位数比几何平均。

| 引擎 | 窗口 | 既有 P2 | 精确前缀及 95% 区间 |
| --- | --- | ---: | ---: |
| wasmoon | 生命周期 | 9.18× | 3.42× [3.38, 3.51] |
| wasmoon | 热调用 | 8.79× | 2.70× [2.65, 2.76] |
| Wasmtime | 生命周期 | 7.67× | 2.29× [2.25, 2.37] |
| Wasmtime | 热调用 | 8.17× | 2.37× [2.31, 2.42] |

四个窗口较 P2 缩短约 63%–71%。wasmoon 的 JSON5 和 Lisp 仍是开销最大的
两项，Lisp 生命周期中位数比为 5.31×。这轮短采样用于优化反馈，
报告的正式 A17 为 `NOT_RUN`。A19 仍超标，S20 默认选择保持阻塞，
S21 保留集保持待执行。

## 正确性与独立复核

- Windows、Linux Wasm 单测各 97 项，独立 Fuel 预言机 9 项通过。
- 双引擎配对检查通过。覆盖纯前缀的每个预算分界、末尾的加权写操作、
  分支／间接入口、动态 bulk/grow、WASI 输出前缀、跨布局 marker 拒绝以及
  相同配置三次生成的 Wasm 和 sidecar 字节一致。原函数 C 一致，实际 A ≤ C。
- 种子 `170026` 的 10,000 份生成／变异输入均通过 P2 前缀插桩、独立
  编码验证和两引擎执行。2,727 个受控陷阱核对了诊断和可见状态。
- Linux wasmoon runner 回归和 native release 的两项白盒测试通过。
- 独立 `/check` 复核发现三个问题。间接调用断言应取 16 单位的失败 helper
  与 13 单位间接 wrapper 的较大值。试跑报告需保留 A17 的 `NOT_RUN`。
  构建重放还需核对归档 builder 和 CLI 的 SHA-256。主代理修复，子代理用实际
  账本及两条替换二进制的反例复验。

## 复现命令

```bash
export PATH=/root/.moon/bin:/opt/fuelguard-s02/bin:/usr/bin:/bin
export LC_ALL=C
ulimit -S -s 8192
python3 -B bench/run.py --compare-prefix --out _build/s20-prefix-pilot \
  --host-record _build/host.json \
  --wasmtime-c-api /root/s18-tools/wasmtime-v50.0.0-x86_64-linux-c-api
python3 -B bench/summarize.py _build/s20-prefix-pilot --out _build/s20-prefix-report.json
moon test --target wasm
python3 -B -m unittest discover -s integration/fuel_oracle
python3 -B integration/p1/check.py --out _build/s20-prefix-paired
python3 -B integration/generated/check.py run --codegen p2-prefix --jobs 12 --out _build/s20-prefix-generated
FUELGUARD_CHECK_EVIDENCE=_build/s20-prefix-runner python3 -B integration/runner/check.py --codegen p2-prefix
```

## 证据

Windows 工作区的 `_build/s20-prefix/` 保存报告、原始计时和构建账本。
归档含实测源码快照、工具、命令、原始样本和测试记录。解包到新目录后，
重放报告逐字节一致。

| 文件 | SHA-256 |
| --- | --- |
| `report.json` | `df396e97dc34f09821db92e4be31018f983b059a369a19e6fc165e1f1a2b926a` |
| `samples.jsonl` | `1d1f763938706027ecb1cd2e644491b37c050af330dafef0393a923c9b21efe5` |
| `raw-evidence.tar.gz` | `82bd335527bb29ecef79d9f53e424f09bf9d44cc5cae97b140a6f876a8a43c03` |
