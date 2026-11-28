# Third-party components

This project uses external packages through MoonBit package dependencies. The
packages are not copied into this repository unless explicitly stated.

## starshine 0.3.0

- Repository: https://github.com/jtenner/starshine-mb
- Used for WebAssembly decoding, validation, encoding, and structured AST types.
- Declared package license: Apache-2.0.
- The upstream distribution separates original code under MIT from the MoonBit
  module and Binaryen-derived portions under Apache-2.0. Follow the upstream
  `LICENSE` and `NOTICE` files rather than relying only on the package manifest.

FuelGuard applies MoonBit RC compatibility patches to local starshine sources.
The root and `x@0.5.1` workspaces use the 20261126 and 20261127 patches in
sequence. The Linux runner uses the 20261126 and 20261128 patches because its
`x@0.5.5` dependency returns `ArrayView[String]` from `read_dir`. The archived
20261127 diff remains available for review. Retain upstream attribution for the
modified sources.

## MoonBit libraries

- `moonbitlang/core` is provided by the MoonBit toolchain under Apache-2.0.
- `moonbitlang/async@0.22.4` and `moonbitlang/x@0.5.1` are core module
  dependencies declared under Apache-2.0. The Linux runner workspace also
  resolves `moonbitlang/x@0.5.5`, whose package carries a separate bcrypt notice.
- `marianoguerra/uri@0.1.2` is an Apache-2.0 transitive dependency of the
  Linux runner.

## Linux runner dependencies

`Milky2018/wasmoon@0.18.0`, `Milky2018/wasm_core@0.18.0` and the
transitive Milky2018 modules at 0.18.0 declare Apache-2.0 in their package
manifests. The shared upstream license is in the
[wasmoon repository](https://github.com/Milky2018/wasmoon/blob/main/LICENSE).
The wasmoon archive also carries `wasi_http/wit/LICENSE.md`.

The local Mooncakes source ZIP contains FuelGuard sources, its license and
notices, the starshine compatibility diff, and the applicable source-package
notices for the checked-in WebAssembly fixtures. The fixed MoonBit RC core
files are `docs/licenses/moonbit-core-NOTICE.txt` and
`docs/licenses/moonbit-core-LICENSE.txt`. The pinned starshine source-package
files are `docs/licenses/starshine-0.3.0-LICENSE.txt` and
`docs/licenses/starshine-0.3.0-NOTICE.txt`. The package manager obtains the
third-party archives separately, so those copies do not replace the complete
dependency archives.
