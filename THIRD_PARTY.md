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

## Planned runtime dependency

wasmoon 0.18.0 is the selected Linux/WSL runtime for `cmd/run`, but it is not yet
added because the adapter is not implemented. Its Apache-2.0 notice must be added
here when the dependency enters `moon.mod`.
