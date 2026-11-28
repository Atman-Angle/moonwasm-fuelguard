# FuelGuard 十一月赛复核材料底稿

2026-11-28。用于参赛者整理补件及准备答辩。章程第五章要求参赛者亲自撰写一页 Markdown 项目申报书，项目技术事实可从本页及申报书中核对。2026-11-10 的项目反馈记录写明可在 11 月 30 日前补充材料并重新提交，具体入口按该反馈和赛事群通知确认。公开十一月表单列出申报字段和修改次数，章程要求按赛事群公布的入口、模板和时限办理。[官方章程](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd) · [十一月表单](https://bxup9uklfcb.feishu.cn/share/base/form/shrcnWUMlgpbwHaXgzV7HmNhNhg) · [项目反馈](08_官方反馈与升级决策.md)

## 表单中的项目信息

- 项目名称为 MoonWasm FuelGuard。十一月表单按参赛方向显示相应的项目名称、GitHub 仓库链接与申报书字段。公开仓库可访问，最终补件需附出正式候选的可访问提交链接。[仓库](https://github.com/Atman-Angle/moonwasm-fuelguard)
- 申报书至少说明项目名称、简介、方向与通用性、三个完整场景、核心功能、原创或参考情况、相应来源和许可证，以及含至少十个有效提交的 GitHub 仓库。既有申报书已有三个场景和现行保护边界，可据正式产物补上验证结果。[申报书 v2](04_项目申报书_v2.md)
- 成果证明应覆盖公开源码与提交历史、README、真实样例、CI 的检查与构建及测试、核心测试、Mooncakes 版本和许可。形成正式补件时填入实际提交、CI run、公开包版本与 Wasm CLI 的 SHA-256。[复核判定](evidence/S70.md)

## 技术决策与初审反馈

| 初审关注 | 可据此说明的实现与验证 |
| --- | --- |
| 粗粒度 Fuel | Fuel v2 在版本化加权 span 入口预扣静态费用，对长度相关操作保留动态计费和 i64 溢出检查。独立预言机和手算轨迹验证扣费语义。 |
| 调用栈保护 | Stack v2 在原调用前预留抽象栈成本，另设调用深度上限。入口包装覆盖导出、启动及受支持的表引用，默认布局审计实际成本 A 与预留成本 C。 |
| 资源边界 | Growth 检查初始和增长的 memory/table 容量。能力不受支持的模块明确拒绝。CLI 输出 Wasm 和配对 sidecar，可追溯模型、哈希及诊断位置。 |
| 独立互操作验证 | 插桩核心用 MoonBit 实现，Linux runner 使用 wasmoon，测试用 Wasmtime 与 wasm-tools 独立执行和验证。两个引擎实际执行同一 `short_loop(10)`，均返回 45。 |

规格和边界见 [生产规格 v4](14_FuelGuard生产规格_v4.md) · [支持矩阵](implementation/support-matrix.md) · [正确性证据](evidence/S62.md) · [最终 ZIP 复测](evidence/S70.md)。

## AI 使用与质量控制

本轮可归档的 Codex 工作包括复核源码包、比对证据哈希、从 Linux 干净目录执行验证和整理赛事材料。章程明确申报书务必由参赛者人工撰写，本文只作事实核对材料，不是可直接提交的代写申报书。答辩由参赛者补充其亲自确定的需求、取舍、审查过程，以及此前实际使用 AI 的范围。可用于说明取舍的材料包括 Fuel v2 计费模型、固定默认布局和 31 位栈配置域的 ADR。[Fuel v2](adr/0001-fuel-v2-minimal-billing-model.md) · [默认布局](adr/0002-single-default-layout.md) · [栈配置域](adr/0003-31bit-only-stack-config.md)

质量验证包含 127 项 Wasm 单测、130 项 native 单测、10,000 个唯一生成样本双引擎执行与 23 个拒绝样本。性能保留集覆盖 360 个独立进程，A17、A19 通过，A20 的 4 MiB 档最大 5.478 秒、峰值 410,352 KiB。性能采样与宿主打包有约 36 秒重叠。同候选的公开 CI 和 Mooncakes 空缓存安装待验证，A24 当前为 `BLOCKED`。 [S62 正确性](evidence/S62.md) · [S63 性能](evidence/S63.md) · [S70 复核](evidence/S70.md)
