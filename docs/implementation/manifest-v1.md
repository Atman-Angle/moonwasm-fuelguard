# FuelGuard 静态 manifest v1

此页记录历史 v1 交付格式。从 S34 起新交付采用
[manifest v2](manifest-v2.md)，下文的生成命令和选项对应旧版工具。

`instrument <in.wasm> -o <out.wasm> --fuel <N> --max-stack-units <N> --max-call-depth <N> --report <manifest.json>`
为默认 `production-v1` 配置生成 Wasm 和 UTF-8 JSON。省略 `--report` 时只生成 Wasm。
输入包含 memory 或 table 时，分别要求 `--max-memory-pages` 或 `--max-table-elements`。
导入使用重复的 `--allow-import module.name` 精确授权。

- `schema` 为 `fuelguard-manifest-v1`。`tool_version` 与 `instrument --version` 一致。
- `input_sha256` 与 `output_sha256` 是原始输入和最终编码产物的 SHA-256 十六进制摘要。
- `passes` 按实际执行顺序记录 pass。`instrumentation` 记录 profile、Fuel、Growth、Stack、诊断 ABI 和 codegen 版本。P0 的标识为 `inline-per-instruction-v1`，P1 为 `p1-helper-v1`，P2 为 `p2-hybrid-loop-inline-sites21-v1`。
- `config` 中的 i64 预算使用十进制字符串，未配置的上限用 `null`。允许的导入按集合规范化为 `{ "module": "…", "name": "…" }` 列表。
- `features` 记录源模块的 memory/table 数量、表元素类型及声明大小是否固定、是否具有 start 或多值签名、签名／local／global 中声明的值类型，以及函数体使用的指令键。
- `appended` 记录追加的 type、function、global 及原函数 local 的索引范围，以及生成的导出名和 custom section 名。范围使用 `first_index` 和 `count`，local 索引包含参数位置。
- `sites` 按非零 `id` 排列。`function_index` 是源模块的 Wasm 函数索引，包含导入函数。`instruction` 行的 `first_ordinal` 与 `last_ordinal` 是从零开始的函数体词法前序序号，结构指令先于子体，`then` 先于 `else`，分隔符无序号。当前布局每个指令 site 的起止序号相同。`entry` 行关联原始函数入口，供 export/start 共用，没有指令序号。

运行诊断的 `__moonwasm_trap_site` 非零时，用该 ID 查找 `sites`。先核对运行的 Wasm 与 `output_sha256`，再读取原始函数和指令。core start 在实例化失败且拿不到诊断全局时，由 runner 报告诊断不可用。运行时间、测试状态和运行日志应放在独立报告中，并引用 `output_sha256`。

## 交付与校验

CLI 在各目标目录独占创建随机暂存子目录，文件写完并同步后读回校验。发布使用文件系统的不覆盖重命名，路径已存在或文件系统不支持该操作时，命令退出 2。双文件交付先发布 Wasm，确认最终路径的字节后才发布 manifest。Windows 同目录的双目标使用长名称，以避开可能在发布时生成的 8.3 别名。

```text
instrument verify <out.wasm> --report <manifest.json>
```

校验成功退出 0。文件缺失、路径不是普通文件、manifest 不完整、模型/ABI/布局版本未知、profile 标记不符或摘要不符时退出 2。结果对应本次读取的字节快照。产物来源以及校验至使用之间的文件稳定性由调用方保证。

如果 Wasm 已发布但 manifest 发布失败，目录中可能保留完整 Wasm。用新的目标路径重试可以避开这次失败中已经发布的文件。无 manifest 的单文件模式仍可用于原有的 Wasm 使用流程。

调用方应控制目标目录、祖先目录和最终路径的写权限。POSIX 暂存目录权限为 `0700`。Windows 暂存目录继承宿主 ACL。权限相同的进程仍可修改目录项。进程被强制终止时，目录中可能残留暂存文件。消费者使用最终 manifest 和匹配的 Wasm 摘要识别完整交付。

旧命令仍可使用 `--fuel`、资源上限和 `--allow-import`，并可通过显式 `--profile fuel-growth-v1` 选择兼容模式。`--profile legacy` 使用当前工具的兼容输入策略。两个兼容 profile 的产物都带各自的标记。旧粗粒度原型产物需要从原始 Wasm 重新插桩。当前接受 `--cost-model fuel-v1`，未知版本会被拒绝。

`--codegen p1` 和 `--codegen p2` 仅用于 `production-v1`。这两种产物在既有
marker 后追加 `|codegen=` 和相应的布局版本，manifest 记录同一版本。P0 仍用原
marker，省略布局选项时使用 P0。部署 P1 或 P2 产物时，消费者需使用识别相应
marker 的 runner。模型、预算配置和诊断 ABI 沿用现有版本。校验器检查 sidecar 所声明
的布局与实际 marker 匹配。

调优候选 `--codegen p2-prefix` 也仅用于 `production-v1`，标识为
`p2-prefix-exact-v1`。它在生成时合并一段无副作用的原指令扣费，沿用
原站点编号、临界预算诊断及模型版本。
