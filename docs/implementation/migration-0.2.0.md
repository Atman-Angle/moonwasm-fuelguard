# FuelGuard 0.2.0 迁移与本地安装

发布候选包含 `Atman-Angle/moonwasm-fuelguard@0.2.0`、Wasm 插桩 CLI 和 Linux x86_64 原生 runner。复现环境为 MoonBit 1.0 RC（`moon 0.1.20261126 ccd306a`、`moonc v1.0.0-rc1+3c0520448`）及 Linux/glibc。下载和依赖身份见 S57。[MoonBit 1.0 RC 公告](https://www.moonbitlang.com/blog/moonbit-1-0-rc)

## 识别已有产物

| 检查项 | 旧产物 | 0.2.0 默认生产产物 |
| --- | --- | --- |
| Wasm 自定义节 `fuelguard.instrumented` | 旧 profile、费用或布局标识，早期原型可能只有诊断导出 | `production-v1`、`fuel-v2`、`diagnostics-v1`、`growth-v1`、`stack-v2`、`fuel-v2-inline-v1` |
| Sidecar | v1 schema 或仅有旧诊断信息 | `fuelguard-manifest-v2`，工具版本 `0.2.0`，包含输入输出 SHA-256、配置和确定性声明 |
| 扣费 | 依旧工具版本计费 | 加权 span 入口预扣，动态费用保留已检查的 i64 计算 |
| 诊断 | 按该产物自己的 ABI 解释 | code/site 双导出，code 1–5 对应 Fuel、Memory、Table、Stack 和 Depth |

可用 `wasm-tools dump <file.wasm>` 查看自定义节，用旧配对的 Wasm 和 sidecar 执行 `instrument verify <file.wasm> --report <file.json>`。v1 配对按其原格式验证。未知模型、伪造的配对和对已插桩模块的再次插桩会被拒绝。诊断导出和 marker 只提供格式识别。历史布局的验证支持与 0.2.0 默认产物的性能记录分别适用。 [manifest v2](manifest-v2.md) · [v4 规格](../14_FuelGuard生产规格_v4.md)

库调用的 `GuardConfig::new` 保留原有命名参数，并新增可选的
`allowed_import_pairs`，用于直接提供 `(module, name)` 对。省略该参数的旧调用
继续使用原行为。生产增长限制仍由 builtin `Pipeline` 执行，独立 `GuardPass`
对启用的 guard 设置继续返回 `NotImplemented`。

## 从本地 Mooncakes 源码包安装

在 Linux 文件系统中开启一个空目录，准备 MoonBit 1.0 RC、Git、Python 3、C 编译器、wasm-tools 1.263.0 和 Wasmtime 50.0.0。下例中的 `PACKAGE` 为本地 ZIP 的绝对路径。运行前用交付的 `SHA256SUMS` 核对包。官方包管理器从 Mooncakes 解析依赖。对干净工作区先执行 `moon update` 获取索引，或使用 S57 记录的同一官方索引快照。

```bash
python3 -m zipfile -e "$PACKAGE" fuelguard-0.2.0
cd fuelguard-0.2.0
root="$PWD"
mkdir -p "$root/bin" "$root/examples-output"
python3 -B scripts/prepare-dependencies.py . cmd/run
moon build --frozen --target wasm --release cmd/instrument
install -m 644 _build/wasm/release/build/cmd/instrument/instrument.wasm "$root/bin/"
install -m 755 scripts/fuelguard-instrument "$root/bin/"

moon install ./cmd/run --bin "$root/bin"
```

脚本通过 Mooncakes 解析依赖并核对 starshine 0.3.0 下载档案及补丁的 SHA-256。根模块及使用 `x@0.5.1` 的 workspace 按顺序应用 20261126、20261127 补丁；Linux runner 使用 `x@0.5.5`，应用 20261126、20261128 补丁，其中 20261128 把 `ArrayView[String]` 转为可排序的 `Array[String]`。重复执行会识别已应用状态；如果检测到无法恢复的 partial 或冲突状态，脚本会在修改前报告每个补丁的状态，需从已核对的 pinned archive 恢复该依赖后重试。根模块和 Linux runner 依赖可通过 `python3 -B scripts/prepare-dependencies.py . cmd/run` 准备；基准构建器和生成语料 worker 的依赖由 `python3 -B scripts/prepare-dependencies.py bench/native integration/generated/worker` 准备。

维护者可从源码检出目录执行 `python3 -B scripts/package-release.py <新目录> --evidence <原始证据归档>`。命令在临时目录打包，检查必需成员，并为 ZIP 和所有传入的证据生成 `SHA256SUMS`。可重复提供 `--evidence`。

MoonBit 1.0 RC 的 `moon install ./cmd/run --bin <目录>` 从本地源码安装原生可执行文件。Wasm CLI 通过 `moonrun <path>/instrument.wasm -- <args>` 执行。要在发布前用 `moonx` 验证同一 Wasm，可把本地编译的入口放进临时 `MOON_HOME` 的指定版本资产缓存。设置 `MOON_TOOLCHAIN_ROOT` 为实际 MoonBit 安装目录，保留工具链的 `bin` 在 `PATH` 中。

```bash
(
  export MOON_TOOLCHAIN_ROOT=/absolute/path/to/moonbit
  export MOON_HOME="$(mktemp -d)"
  if ! command -v moonx >/dev/null; then
    ln -s "$MOON_TOOLCHAIN_ROOT/bin/moon" "$MOON_HOME/moonx"
    export PATH="$MOON_HOME:$PATH"
  fi
  cache="$MOON_HOME/registry/cache/assets/Atman-Angle/moonwasm-fuelguard/0.2.0/cmd/instrument"
  install -D -m 644 "$root/bin/instrument.wasm" "$cache/instrument.wasm"
  moonx Atman-Angle/moonwasm-fuelguard/cmd/instrument@0.2.0 --version
)
```

以上 `moonx` 示例读取刚放入临时缓存的候选产物。空缓存实测，Mooncakes 公开 0.2.0 缺少预构建 Wasm，公开 0.2.1 可用 `moonx Atman-Angle/moonwasm-fuelguard/cmd/instrument@0.2.1 --version` 运行。两份公开包和本地候选的身份见 [S64](../evidence/S64.md)。

## 从未插桩原件重建

取回原始 Wasm 或从应用源码重建。若持有可信旧 sidecar，先用 `input_sha256` 核对原件。根据真实负载重新选择 Fuel、栈和深度预算，给已定义的 memory/table 配置相应的上限。只有需要的导入才加入精确的允许列表。移除旧的 `--cost-model` 或布局选项，选择默认生产配置，写入新的 Wasm 和 sidecar 路径。

```bash
(cd "$root/fixtures/demo" && moon build --target wasm --release)
src="$root/fixtures/demo/_build/wasm/release/build/demo/demo.wasm"
out="$root/examples-output"
wasm-tools validate --features=-simd "$src"
"$root/bin/fuelguard-instrument" "$src" -o "$out/demo.fuel.wasm" \
  --fuel 100000 --max-stack-units 100000 --max-call-depth 128 \
  --max-memory-pages 64 --max-table-elements 64 --report "$out/demo.fuel.json"
wasm-tools validate "$out/demo.fuel.wasm"
"$root/bin/fuelguard-instrument" verify "$out/demo.fuel.wasm" \
  --report "$out/demo.fuel.json"
ulimit -s 8192
"$root/bin/fuelguard-run" "$out/demo.fuel.wasm" --invoke short_loop --arg 10
wasmtime run --invoke short_loop "$out/demo.fuel.wasm" 10
```

两个引擎的 `short_loop(10)` 均返回 45。MoonBit 1.0 RC 重建带文本输出的
`fixtures/hello` 时会生成 SIMD 指令。v4 会拒绝该输入。验证 WASI 输出时可使用
包内已冻结的无 SIMD 原件 `fixtures/hello/hello.wasm`。

受控 trap 后废弃实例。正常 runner 入口调用 `_start`。带核心启动陷阱且尚未获得实例时，按 `diagnostic-unavailable` 处理。

## Linux/glibc 构建资源

Linux 本地安装后使用 `fuelguard-instrument`。启动脚本在执行同目录的 `instrument.wasm` 前，为 `moonrun` 进程设置 `MALLOC_ARENA_MAX=1`、`MALLOC_TRIM_THRESHOLD_=16384` 和 `MALLOC_MMAP_THRESHOLD_=16384`。把安装目录加入 `PATH` 后可以直接执行 `fuelguard-instrument --version`。

直接使用 `moonrun` 或 `moonx` 时，可以给该次调用显式传入相同参数。例如：

```bash
env MALLOC_ARENA_MAX=1 MALLOC_TRIM_THRESHOLD_=16384 MALLOC_MMAP_THRESHOLD_=16384 \
  moonrun "$root/bin/instrument.wasm" -- <instrument-arguments>
```

S56 测得直接运行 `moonrun` 时，默认 glibc 配置的 4 MiB 档峰值约 1 GiB。启动脚本的三档复测采用 Linux x86_64、glibc 2.39 与 MoonBit 1.0 RC。[S56](../evidence/S56.md) · [S58](../evidence/S58.md)
