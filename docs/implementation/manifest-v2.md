# FuelGuard manifest v2

`instrument <in.wasm> -o <out.wasm> --fuel <N> --max-stack-units <N> --max-call-depth <N> --report <manifest.json>`
交付 Fuel v2 Wasm 和 UTF-8 JSON。输入包含 memory 或 table 时，仍需提供对应的资源上限。

- `schema` 固定为 `fuelguard-manifest-v2`。 `tool_version` 对应 `instrument --version`。
- `input_sha256` 和 `output_sha256` 分别记录原始输入与最终 Wasm 的小写十六进制 SHA-256。
- `deterministic` 固定为 `true`。同输入、配置和工具版本重复生成的两份文件各自逐字节一致。
- `instrumentation` 记录 `profile`、`fuel_model`、`stack_model`、`growth_model`、`diagnostics_abi`、`codegen` 和 `config`。生产布局标识为 `fuel-v2-inline-v1`。
- `config` 的 `fuel`、`max_stack_units`、`max_call_depth` 用十进制字符串表示。资源上限 `max_memory_pages`、`max_table_elements` 用 JSON 整数表示。未配置的上限为 `null`。`allowed_imports` 按名称排序并去重，元素是 `{"module":"…","name":"…"}`。

运行 `instrument verify <out.wasm> --report <manifest.json>` 核对配对文件。
对 Fuel v2，验证器还会读取实际 Wasm guard 中的首站点与静态费用。
同一函数内，用相邻 guard 的首站点差得到 span 长度。最后一段由该函数的末站点确定。
`fuelguard.fuel-v2-spans-v1` 自定义节包含 32 字节的规划摘要，以及原定义函数顺序下每个函数 4 字节的小端末站点。空函数用 0。
摘要对先序排列的记录做 SHA-256，每条记录依次编码函数索引、首站点、长度（三个小端 i32）和静态费用（小端 i64）。校验器对重建的记录求同样的摘要。自定义节无论是否请求 sidecar 都会写入。

验证针对本次读取的字节。输入摘要供持有原件的调用方核对，文件来源由调用方确认。
Wasm 校验、无覆盖发布和原有诊断导出仍适用。

用 `instrument resolve-site <in.wasm> <out.wasm> --report <manifest.json> <site>`
查询生产 Fuel v2 的失败站点。命令核对可信清单中的原件和产物 SHA-256，
再按生产规划返回原函数索引、从 0 开始的指令先序序号及 opcode。
导出或 core start 包装器的站点返回 `entry=export-or-start`。
库调用方可用 `Pipeline::plan` 查看同一套站点规划，其中入口的指令序号为 `-1`。

历史 v1 配对用其原 manifest 和 Wasm marker 验证。显式 `fuel-growth-v1` 和
`legacy` 兼容 profile 保留原模型，新的 sidecar 也采用 v2 格式。生产 CLI
接受省略模型选项、`--cost-model fuel-v2` 或 `--codegen fuel-v2`。
旧模型和布局选项退出 2 并提示迁移。重建请使用原始未插桩的 Wasm。
