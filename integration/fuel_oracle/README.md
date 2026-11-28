# 计费预言机版本

`oracle.py::evaluate` 继续独立解释 `fuel-v1` 的逐站点追踪，供既有差分
和 `p2-prefix` 基线使用。

`join.py` 依据 [Fuel v2 边界表](../../docs/implementation/fuel-v2.md) 对
测试提供的结构化源指令编号并构建控制流图。只有前序相邻且边唯一的
指令可以同段，显式控制流边界结束当前 span。测试提供分支选择、目标调用
和观察值。预言机在入口预扣整段静态费用，失败诊断取 span 首站点。
动态附加费用在原指令处扣除。执行轨迹还覆盖调用、资源检查、原生陷阱和可见副作用。

从仓库根目录运行 `python -B -m unittest discover -s integration/fuel_oracle -v`。
在固定 Linux 环境运行 `python3 -B integration/fuel_cache/check.py --out <新目录>`，
用独立计算的函数边界、首站点、长度和权重核对交付 Wasm 的 span 摘要。
两引擎执行实际产物。余额测试另用导出 Fuel global 的观察副本，
在可观察的同步点核对余额。
