# FuelGuard v4 项目现状

更新于 2026-11-28。实现与验收以 [FuelGuard v4](14_FuelGuard生产规格_v4.md) 为准。

S62 已在 Docker Ubuntu 24.04 使用固定 MoonBit 1.0 RC 完成 Linux 复跑。依赖准备、根模块严格检查、127 项 Wasm 测试、Wasm CLI 构建、
wasmoon 安装、runner 严格检查、130 项 native 测试、真实 demo E2E、完整 correctness/generated/rejections 语料、双引擎 workloads、
交付检查和特权容器 file-faults 均退出 0。[S62](evidence/S62.md)

确定采用 `feat/v4-fuel-v2` 的 `60100c21` 加本地候选改动作为技术候选。公开 main 为 0.2.1，使用独立 codec 包，且不是该候选的源码线。候选版本提升为 0.2.2，以避开已发布版本号；版本同步后的本地源码包、CLI、runner、干净安装和双引擎样例均已重建通过，最终提交和公开包身份待推送后封存。当前公开仓库没有 workflow 或 run 记录。[S64](evidence/S64.md) · [S70 候选收据](evidence/S70.md) · [S71 独立身份复核](evidence/S71.md) · [S72 0.2.2 重建](evidence/S72.md)

已读取飞书章程正文、核对第 5.1 节的九项验收要求，并确认十一月赛表单的项目字段。赛事补件底稿包含 AI 使用、技术决策和质量验证说明。此前 v4 独立复审范围见 [S67](evidence/S67.md) · [S70 章程逐项判定](evidence/S70.md) · [赛事材料底稿](acceptance-submission-notes.md)。

申报书上一轮复审及复现命令见 [S59](evidence/S59.md) 与[逐项清单](audit-2026-11-27.md)。本轮独立小模块由 441 B 增至 1355 B，另有 574 B 的 sidecar。[S63](evidence/S63.md)

| 项目 | 当前状态 | 证据 |
| --- | --- | --- |
| 正确性与交付检查 | **本轮 PASS**。S62 ext4 报告覆盖 A01–A16、A21、A23；生成语料 10000/10000 双引擎，拒绝语料 23/23，file-faults 在特权容器通过 | [S62](evidence/S62.md) |
| A17 性能、A19 体积 | **本轮 PASS**。18 个计时单元、360 个独立进程、324,000 个非预热样本，封口验证退出 0；四个窗口 CI 上界均低于 2x，12 个 workload 的 median/p95 上界均低于 3x | [S63](evidence/S63.md) |
| A18 布局比较 | **历史记录**。v4 采用 ADR-0002 的冻结比较；本轮未重跑 | [ADR-0002](adr/0002-single-default-layout.md) |
| A20 构建资源 | **PASS**。4 MiB 最大 5.478 秒，峰值 RSS 410,352 KiB | [S63](evidence/S63.md) |
| A22 发布前打包 | **本地 0.2.2 打包与安装 PASS，公开安装 BLOCKED**。0.2.2 ZIP 许可沿用已复核的源码包范围，公开 0.2.2 资产尚未发布 | [S68](evidence/S68.md) · [S72](evidence/S72.md) |
| A24 独立复核 | **BLOCKED**。0.2.2 本地候选、正确性、A17/A19/A20、文档复现和包成员证据已复核。仍缺最终提交绑定、同提交的远程 CI、Mooncakes 公开安装及正式 CLI 的分发许可核对 | [S63](evidence/S63.md) · [S67](evidence/S67.md) · [S72](evidence/S72.md) |

S55 使用 MoonBit `0.1.20261126`、WSL `FuelGuard-S26`、Wasmoon 0.18.0、Wasmtime 50.0.0 和 wasm-tools 1.263.0。构建使用 starshine 0.3.0 的显式 trait 兼容补丁。验收结果绑定已记录的源码、二进制和语料。当前分支为 `feat/v4-fuel-v2`，实现与证据仍有未提交改动。原始归档在本机 `_build/s55-archive` 和 `_build/s56-archive`，归档哈希见对应证据页。 [兼容补丁](evidence/starshine-0.3.0-moonbit-20261126.patch)

## 剩余任务与顺序

1. 按 0.2.2 重跑版本变更影响的门禁，封存正式候选并绑定 Git 提交、模块版本、源码包和 CLI 的 SHA-256，核对正式 CLI 和实际额外分发物的第三方许可与通知。
2. 按项目的单独授权流程取得同一提交的 GitHub Actions job，以及 Mooncakes 公开下载、空缓存安装、插桩、校验和运行证据，再更新 A24。
3. 版本、源码或产物变化时复跑受影响的门禁。若验收方要求完全独占主机，重跑完整 360 进程保留集。现有保留集与宿主打包约有 36 秒重叠。
4. 参赛者核对赛事群的补件入口，按章程亲自撰写申报书，附正式提交和产物的证据链接。
