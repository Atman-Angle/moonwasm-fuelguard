# Third-party components

This project uses external packages through MoonBit package dependencies. The
packages are not copied into this repository unless explicitly stated.

## FuelGuard codec 0.1.0

- Package: `Atman-Angle/fuelguard-codec@0.1.0`
- Repository: https://github.com/jtenner/starshine-mb
- Used for WebAssembly decoding, validation, encoding, and structured AST types.
- Declared package license: Apache-2.0.
- The upstream distribution separates original code under MIT from the MoonBit
  module and Binaryen-derived portions under Apache-2.0. Follow the upstream
  `LICENSE` and `NOTICE` files rather than relying only on the package manifest.

The codec package contains the pinned MoonBit 1.0 RC compatibility sources and
retains upstream attribution for the modified sources.

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
notices. The package manager obtains the codec and other third-party archives
separately.
