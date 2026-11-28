# S29 后续性能实验

执行日期为 2026-11-20（北京时间）。基线采用 S29 合并报告和原始产物。当前
最佳候选为显式选择的 `join-span-compact-v2`。A19 继续阻塞默认冻结和 S21，
S29 的正式裁决仍有效。[S29 合并结果](S29.md)

## 基线与方法

S29 首轮和补采的原始账本重新生成了字节一致的合并报告，SHA-256 为
`4a33192e2576b93355eaae7c5e2ae70d9d343da430075efb9d7484a3cd2733d4`。
其 `join-span-compact` 的 wasmoon 生命周期几何均值是 2.057×，
95% 区间 [2.038×, 2.076×]。短程复测使用两个相同产物估计采样噪声，
各组的相同产物对照区间均包含 1，主对照的该项为 2.005× [1.964×, 2.058×]。

在 `FuelGuard-S26` 上使用 S29 的实际 worker 和 Wasmtime C API，绑定 vCPU 4，
使用 S25 冻结调优集、原窗口、预算和 batch。每个窗口、负载、引擎各跑
3 个独立进程，每进程 5 次预热和 30 次计时。原版、S29 compact、当前最佳
和当轮候选在同一进程交错。同轮比较采用 10,000 次分层配对 bootstrap。
样本验证 stdout、返回值与退出状态。保留集执行数为 0。以各窗口的配对区间
评估收益，应用中位数比的区间下界超过 1.02 视为检测到回退。

S29 的 F1 有 780 个内联 Fuel guard（19,954 B）和 267 个带检查的打包 Stack
调用点（13,501 B，未计归还序列）。S29 的 wasmoon F0 生命周期中位数，
原版实例化阶段约 0.728 ms，compact 约 1.526 ms；显式业务入口分别约
0.033 ms 和 0.039 ms。历史上逐站点共享扣费、共享 Stack 冷失败分支和改写
打包符号判断均已有回退证据，本轮沿用这些结果。

## 实验裁决

| 轮次 | 假设 | 同场结果 | 裁决 |
| --- | --- | --- | --- |
| 1 | 复用已同步的 Fuel 余额 | wasmoon 热调用缩短 2.6%，配对比 0.974 [0.959, 0.992]。四个应用分别少 304、1,350、1,054、1,089 B。106 项 Wasm 单测及双引擎 Fuel 边界通过 | 保留 |
| 2 | 复用支配当前调用的 Stack 检查下界 | 相对第一轮，wasmoon 生命周期缩短 8.2%，配对比 0.918 [0.898, 0.935]。F1 的检查站点数从 267 降至 84。双引擎 Stack 边界与五组定向用例通过 | 与第一轮合并，版本化为 compact v2 |
| 3 | 用接收和返回 i64 缓存余额的共享 helper 压缩 Fuel guard | F0 降至 15,429 B，F1/F2/F3 仍为 32,587/29,735/26,670 B。相对第二轮，wasmoon 和 Wasmtime 热调用几何均值分别慢 85.2% 和 75.1%。106 项 Wasm 单测及定向诊断通过 | 撤回实现，保留数据 |

第二轮相对同场 S29 compact 的几何均值。括号为候选相对原版的
95% 区间上界。

| 引擎与窗口 | S29 compact | 第二轮 | 相对 compact 缩短 |
| --- | ---: | ---: | ---: |
| wasmoon 生命周期 | 2.004× | 1.841× (1.885×) | 8.1% |
| wasmoon 热调用 | 1.681× | 1.558× (1.580×) | 7.3% |
| Wasmtime 生命周期 | 1.906× | 1.851× (1.915×) | 2.9% |
| Wasmtime 热调用 | 1.954× | 1.880× (1.929×) | 3.8% |

## 体积与剩余瓶颈

| 用例 | A19 上限 | S29 compact | compact v2 | 缩小 | 超限 |
| --- | ---: | ---: | ---: | ---: | ---: |
| F0 hello | 15,627 B | 20,639 B | 19,299 B | 6.5% | 3,672 B |
| F1 JSON5 | 25,256 B | 51,376 B | 41,337 B | 19.5% | 16,081 B |
| F2 Lisp | 20,536 B | 46,317 B | 36,847 B | 20.4% | 16,311 B |
| F3 SHA-256 | 20,459 B | 42,080 B | 32,185 B | 23.5% | 11,726 B |

第二轮之后，F1/F2/F3 的内联 Fuel guard 单独已占 19,954/16,317/12,940 B，
各自超过 A19 允许的全部新增字节。仅继续压缩 Stack 或余额发布无法使这三个
负载过门禁。第三轮的共享 helper 显著放慢执行，且 F1–F3 体积仍分别超出
7,331、9,199 和 6,211 B。剩余工作需要一种在每个执行路径保持精确失败诊断、
同时降低站点编码和每次扣费执行成本的布局。

## 版本化候选复测

以正式 CLI、分阶段 native 构建器和 S29 的冻结 worker 实跑
`--compare-join-compact-v2`。66 个进程保留 5,940 条计时样本、
990 条预热样本和 198 条引擎编译记录。以下几何均值均以同场原版为分母。

| 引擎与窗口 | compact v1 | compact v2 [95% 区间] | 缩短 |
| --- | ---: | ---: | ---: |
| wasmoon 生命周期 | 2.032× | 1.873× [1.829, 1.914] | 7.8% |
| wasmoon 热调用 | 1.683× | 1.561× [1.524, 1.591] | 7.3% |
| Wasmtime 生命周期 | 1.948× | 1.851× [1.796, 1.890] | 5.0% |
| Wasmtime 热调用 | 1.932× | 1.838× [1.801, 1.884] | 4.9% |

几何均值的试点上界都低于 2.0×。Wasmtime 的 F1 p95 区间上界在热调用和
生命周期分别为 3.687× 和 3.038×，两项都跨过 3.0×。正式
300 × 3 的 A17 为 `NOT_RUN`。各负载的 sidecar 为
277,022 / 586,529 / 478,789 / 499,905 B，与 Wasm 体积单列。

| 输入 | v2 native 中位数 / 最高 RSS | v2 Wasm CLI 耗时 / RSS |
| --- | ---: | ---: |
| 64 KiB | 0.012 s / 28,316 KiB | 0.672 s / 563,368 KiB |
| 512 KiB | 0.104 s / 28,316 KiB | 1.096 s / 769,884 KiB |
| 4 MiB | 0.840 s / 131,712 KiB | 3.700 s / 509,412 KiB |

4 MiB 的初测通过 10 s / 524,288 KiB 硬限。同场 v1 的最大输入 CLI 为
3.683 s / 512,092 KiB。随后将 S29 原 CLI、当前 CLI 的 v1 和 v2 在三档
各交错构建三次，逐份核对产物哈希。4 MiB 的 v2 最慢 3.795 s，最高
515,132 KiB，全部符合硬限。该档 v2 的时间和 RSS 中位数相对 S29 分别为
−0.8% 和 +0.8%。

512 KiB 的 v2 RSS 中位数为 408,020 KiB，低于 S29 的 426,528 KiB，
但再次出现单次高峰 783,616 KiB。该档 v2 的 CLI 时间中位数为 1.225 s，
比交错 S29 和当前 v1 对照分别高 9.1% 和 8.9%。64 KiB 的 v2 RSS 中位数
相对 S29 为 −0.1%，相对当前 v1 为 +8.8%。中小档的构建波动和回退信号
仍需追踪，初测与复测的各次结果都保留。

F0–F3 上七种旧布局的 28 份 Wasm 和 sidecar 与 S29 逐字节一致。v2 的
九份 Wasm 除版本标记外和第二轮一致。F0 连续三个独立 CLI 进程生成的
v2 Wasm 和 sidecar 也各自逐字节一致，交付校验通过。

第一份正确性账本在运行期间同步了测试接线和生成接口，源码一致性检查按预期
阻塞该账本。随后修复已有 `structural()` 调用入口。版本化性能采集与最终
正确性源码的唯一文件差异是这个预言机测试入口，插桩源码及两种构建产物一致。

固定源码后的 `correctness` 和 `generated/rejections` 两份账本共有
13 项检查通过，覆盖 A01–A16 和 A23。两份账本的源码集合 SHA-256 都为
`0e13ee41e5f03d48908a683eb7fc3d7c6d5684f0242bccdefcc57684bd94bdae`。
10,000 个不同输入全部实际插桩、独立校验并由两个引擎执行，其中 3,333 个
双引擎受控陷阱。Windows 和冻结 Linux 各有 106 项 Wasm 单测通过。
版本化基准报告从原始记录重放后逐字节一致。

## 复现

原型档案包含三轮原始样本、排程、worker 日志、试验改动和精确产物。可用
S29 归档核对并取得相同引擎二进制。原型档案的 SHA-256 为
`bd4158fb110985d54946a68134f96071785f216a80413179e3d93485e95b6cb9`。
[原型档案](../../_build/autoresearch/prototype-runs.tar.gz)

| 版本化候选证据 | SHA-256 |
| --- | --- |
| [源码快照](../../_build/autoresearch/compact-v2-verified-source.tar.gz) | `6ed2a878cb0220f26aed79dd0786b114fa136ffcf058fe231d9c2d4292f4b8c2` |
| [原始基准与构建复测](../../_build/autoresearch/compact-v2-benchmark-records.tar.gz) | `fcce36e81a09b66de65484604928e22808c19a227bf081a921422afe648e92fa` |
| [基准报告](../../_build/autoresearch/v2-bench-report.json) | `d2819160e2d5ad13a4271bd68812c1787a759b3ddce695b8d991ed072fe640f9` |
| [正确性测试报告](../../_build/autoresearch/v2-correctness-verified.json) | `f424af9978647f76e67f807349cd44da9197db8439593ac9e231a2f25edc05f5` |
| [生成及拒绝测试报告](../../_build/autoresearch/v2-generated-verified.json) | `8bfcd24f7649d58e13a91320040eabb8046979aaf56573af7b4b42fe2ea5f5af` |
| [生成测试逐例账本](../../_build/autoresearch/v2-generated-cases.jsonl) | `4a618cb61ba9e98f67c7aa8e449a22a1e4a749526284795376c6f030b8682848` |

在冻结 Linux 的仓库根目录运行。准备同 S29 的实时 Windows 主机、电源和 CPU
记录，并用 S29 首轮目录的 worker 复跑。

```bash
export MOON_HOME=/root/s26-frozen-moon
export PATH="$MOON_HOME/bin:/opt/fuelguard-s26/bin:/usr/bin:/bin:/root/fuelguard-s26-optimization/_build/wasmoon-0.18.0-test-source/bin"
export LC_ALL=C
python3 -B integration/acceptance/check.py --group correctness \
  --codegen join-span-compact-v2 --out _build/compact-v2-correctness
python3 -B integration/acceptance/check.py --group generated --group rejections \
  --jobs 6 --codegen join-span-compact-v2 --out _build/compact-v2-generated
python3 -B bench/run.py --compare-join-compact-v2 --out _build/compact-v2-pilot \
  --frozen-workers /root/fuelguard-s29/_build/s29/initial \
  --host-record /mnt/d/moonwasm-fuelguard/_build/autoresearch/host.json \
  --wasmtime-c-api /root/s26-tools/wasmtime-v50.0.0-x86_64-linux-c-api
taskset -c 4 python3 -B bench/summarize.py _build/compact-v2-pilot --out _build/compact-v2-report.json
```
