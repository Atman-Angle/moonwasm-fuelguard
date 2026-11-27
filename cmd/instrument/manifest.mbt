///|
const TOOL_VERSION = "0.2.1"

///|
const MANIFEST_SCHEMA = "fuelguard-manifest-v2"

///|
const LEGACY_MANIFEST_SCHEMA = "fuelguard-manifest-v1"

///|
fn sha256_hex(bytes : Bytes) -> String {
  hex_bytes(@crypto.sha256(bytes).iter())
}

///|
fn hex_bytes(bytes : Iter[Byte]) -> String {
  let digits = b"0123456789abcdef"
  let result = StringBuilder(capacity=64)
  for byte in bytes {
    let index = byte.to_int()
    result.write_char(digits[index / 16].to_int().unsafe_to_char())
    result.write_char(digits[index % 16].to_int().unsafe_to_char())
  }
  result.to_string()
}

///|
fn manifest_bytes(input : Bytes, output : Bytes, details : Json) -> Bytes {
  let manifest : Json = {
    "schema": Json(MANIFEST_SCHEMA),
    "tool_version": Json(TOOL_VERSION),
    "input_sha256": Json(sha256_hex(input)),
    "output_sha256": Json(sha256_hex(output)),
    "deterministic": Json(true),
    "instrumentation": details,
  }
  @utf8.encode(manifest.stringify() + "\n")
}
