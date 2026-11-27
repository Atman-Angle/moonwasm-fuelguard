"""S09 rejection matrix and independent S10 typed/actual layout checks."""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "runtime"))
import check as runtime

OUT = runtime.ROOT / "_build/s09-s10"
HEADER = b"\x00asm\x01\x00\x00\x00"
TOOL = runtime.ROOT / "_build/wasm/debug/build/cmd/instrument/instrument.wasm"


def leb(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    return bytes([*result, value])


def section(tag, body):
    return bytes([tag]) + leb(len(body)) + body


def raw(name, data):
    path = OUT / f"{name}.wasm"
    path.write_bytes(data)
    return path


def wat(name, source):
    path = OUT / f"{name}.wat"
    path.write_text(source, encoding="utf-8")
    wasm = path.with_suffix(".wasm")
    runtime.run(f"parse-{name}", ["wasm-tools", "parse", path, "-o", wasm], runtime.ok)
    return wasm


def instrument(name, source, *options, refusal=None, budget=1000000):
    output = OUT / f"out-{name}.wasm"
    output.unlink(missing_ok=True)
    profile = [] if "--profile" in options else ["--profile", "fuel-growth-v1"]
    args = ["moonrun", TOOL, source, "-o", output, "--fuel", budget, *profile, *options]
    if refusal:
        runtime.run(f"reject-{name}", args,
                    lambda code, out, err: code == 2 and refusal in out + err)
        assert not output.exists(), name
        return None, ""
    summary = runtime.run(f"accept-{name}", args, runtime.ok)
    runtime.run(f"validate-{name}", ["wasm-tools", "validate", output], runtime.ok)
    return runtime.artifact(name, output), summary


def code_body(body):
    return HEADER + section(1, b"\x01\x60\x00\x00") + section(3, b"\x01\x00") + section(
        10, b"\x01" + leb(len(body)) + body)


def bounds():
    for tag, label, count in (
        (1, "types", 1025), (2, "imports", 257), (3, "defined functions", 4097),
        (4, "tables", 2), (5, "memories", 2), (6, "defined globals", 16385),
        (7, "source exports", 1023), (9, "element segments", 257),
        (11, "data segments", 257),
    ):
        name = label.replace(" ", "-")
        source = raw(name, HEADER + section(tag, leb(count)))
        instrument(name, source, refusal=f"{label} {count} exceeds input limit")
    module_count = HEADER + section(2, b"\x01\x01m\x01f\x00\x00") + section(3, leb(4096) + bytes(4096))
    instrument("combined-funcs", raw("combined-funcs", module_count),
               refusal="total functions 4097 exceeds input limit")
    for name, body, message in (
        ("locals", b"\x01" + leb(4097) + b"\x7f\x0b", "locals 4097 exceeds input limit 4096"),
        ("nested", b"\x00" + b"\x02\x40" * 257, "structured nesting 257 exceeds input limit 256"),
        ("instructions", b"\x00" + b"\x01" * 65537, "function instructions 65537 exceeds input limit"),
        ("body-truncated", b"\x00\x02\x40", "truncated field"),
        ("typed-block", b"\x00\x02\x63\x70\x0b\x0b", "production-v1 block type"),
    ):
        instrument(name, raw(name, code_body(body)), refusal=message)
    body = b"\x00" + b"\x01" * 65536 + b"\x0b"
    clause = leb(len(body)) + body
    long_module = (HEADER + section(1, b"\x01\x60\x00\x00")
                   + section(3, b"\x11" + bytes(17))
                   + section(10, b"\x11" + clause * 17))
    instrument("module-instructions", raw("module-instructions", long_module),
               refusal="module instructions 1114112 exceeds input limit 1048576")
    large_elem = HEADER + section(9, b"\x01\x01\x00" + leb(4097))
    instrument("element-entries", raw("element-entries", large_elem),
               refusal="element entries 4097 exceeds input limit 4096")
    instrument("nesting-boundary", raw("nesting-boundary",
               code_body(b"\x00" + b"\x02\x40" * 256 + b"\x0b" * 257)))
    instrument("locals-boundary", raw("locals-boundary",
               code_body(b"\x01" + leb(4096) + b"\x7f\x0b")))
    instrument("input-bytes", raw("input-bytes", HEADER + bytes(4194305 - len(HEADER))),
               refusal="module bytes 4194305 exceeds input limit 4194304")
    for kind, sizes in (("parameters", b"\x41"), ("results", b"\x00\x11")):
        instrument(kind, raw(kind, HEADER + section(1, b"\x01\x60" + sizes)),
                   refusal=f"{kind} ")
    instrument("component", raw("component", b"\x00asm\x0d\x00\x01\x00"),
               refusal="expected core Wasm version 1")
    instrument("overlong-leb", raw("overlong-leb", HEADER + b"\x01\xff\xff\xff\xff\x10"),
               refusal="u32 LEB overflow")
    instrument("name-length", raw("name-length", HEADER + section(0, leb(1025))),
               refusal="name bytes 1025 exceeds input limit")
    instrument("name-utf8", raw("name-utf8", HEADER + section(0, b"\x01\xff")),
               refusal="invalid UTF-8 name")


def policy():
    imports = wat("imports", '(module (import "env" "f" (func)) '
                  '(import "env" "g" (global i32)) (func (export "run") call 0))')
    output, _ = instrument("imports-allowed", imports, "--allow-import", "env.f",
                           "--allow-import", "env.g")
    def import_lines(label, module):
        text = runtime.run(f"print-{label}", ["wasm-tools", "print", module], runtime.ok)
        return re.findall(r"^\s*\(import .*$", text, flags=re.MULTILINE)
    assert import_lines("before", imports) == import_lines("after", output)
    instrument("imports-default", imports, refusal="module=env, name=f")
    instrument("imports-global-missing", imports, "--allow-import", "env.f",
               refusal="module=env, name=g")
    for name, source, why in (
        ("import-memory", '(module (import "env" "x" (memory 1)))', "imported memory"),
        ("import-table", '(module (import "env" "x" (table 1 externref)))', "imported table"),
        ("import-tag", '(module (import "env" "x" (tag)))', "import kind"),
        ("import-ambiguous", '(module (import "env.x" "y" (func)))', "ambiguous allow-import"),
        ("import-collision", '(module (import "env.x" "y" (func)))', "module=env.x, name=y"),
        ("relaxed-simd", "(module (func (param v128 v128) local.get 0 local.get 1 i8x16.relaxed_swizzle drop))", "relaxed SIMD"),
        ("non-allowed-simd", "(module (func v128.const i32x4 0 0 0 0 drop))", "outside production-v1 allowlist"),
        ("funcref-mutation", "(module (table 1 1 funcref) (func ref.null func i32.const 0 table.grow drop))", "ref.null heap type"),
        ("funcref-copies", "(module (table 1 1 funcref) (func i32.const 0 i32.const 0 i32.const 0 table.copy 0 0))", "requires an internal externref table"),
        ("funcref-escaping", '(module (table (export "t") 1 1 funcref))', "exported table"),
        ("funcref-unfixed", "(module (table 1 2 funcref))", "equal minimum and maximum"),
        ("ref-func", "(module (func) (elem declare func 0) (func ref.func 0 drop))", "production-v1 opcode 210"),
        ("table-cap", "(module (table 0 65537 externref))", "table declared maximum 65537"),
        ("missing-memory-limit", "(module (memory 1))", "requires --max-memory-pages"),
        ("memory64", "(module (memory i64 1))", "memory limits flags"),
        ("shared", "(module (memory 1 2 shared))", "memory limits flags"),
        ("tailcall", "(module (func return_call 0))", "production-v1 opcode 18"),
        ("reserved", '(module (func (export "__moonwasm_trap_site")))', "export name already exists"),
    ):
        options = ["--max-table-elements", "2"]
        if name.startswith("import"):
            options += ["--allow-import", {"import-ambiguous": "env.x.y",
                         "import-collision": "env.y"}.get(name, "env.x")]
        instrument(name, wat(name, source), *options, refusal=why)
    instrument("duplicate", output, refusal="already instrumented")
    instrument("old-diagnostic", wat("old-diagnostic",
               '(module (global (export "__moonwasm_trap_code") (mut i32) i32.const 0))'),
               refusal="export name already exists")
    unknown = b"fuelguard.instrumented"
    marked = raw("unknown-marker", HEADER + section(0, leb(len(unknown)) + unknown + b"v999"))
    instrument("unknown-marker", marked, refusal="unknown FuelGuard marker")
    instrument("unknown-model", imports, "--cost-model", "future", refusal="unknown --cost-model")
    instrument("unknown-profile", imports, "--profile", "future", refusal="unknown --profile")
    _, note = instrument("legacy", imports, "--profile", "legacy")
    assert "profile: legacy compatibility" in note


def stack():
    source = wat("typed-stack", """(module
      (memory 1 2)
      (func (export "typed") (param i32) (result i32 i64)
        (local i64 i64)
        local.get 1 local.get 2 i64.and drop
        block (result i32 i64)
          i32.const 7 i64.const 9 local.get 0 br_table 0 0
          drop
        end)
      (func (export "grow") (param i32) (result i32) local.get 0 memory.grow))""")
    output, note = instrument("typed-stack", source, "--max-memory-pages", "2", "--stack-layout")
    expected = (
        "function=0 params=1 results=2 locals=3 operands=5 fixed=8 auxiliary=0 entry=false A=19 C=142",
        "function=1 params=1 results=1 locals=1 operands=3 fixed=8 auxiliary=17 entry=false A=31 C=137",
        "function=2 params=2 results=1 locals=3 operands=3 fixed=8 auxiliary=0 entry=false A=17 C=64",
    )
    assert all(line in note for line in expected), note
    for variant, module in (("source", source), ("instrumented", output)):
        wast = OUT / f"typed-{variant}.wast"
        binary = "".join(f"\\{value:02x}" for value in module.read_bytes())
        checks = '(assert_return (invoke "typed" (i32.const 1)) (i32.const 7) (i64.const 9))'
        wast.write_text(f'(module binary "{binary}")\n{checks}\n', encoding="ascii")
        runtime.run(f"wasmtime-stack-{variant}", ["wasmtime", "wast", wast], runtime.ok)
        runtime.run(f"wasmoon-stack-{variant}", ["wasmoon", "test", "--show-success", wast],
                    lambda code, out, _err: code == 0 and "Passed:  1" in out and "Skipped: 0" in out)


def workloads():
    common = ("--max-memory-pages", "64", "--max-table-elements", "64",
              "--allow-import", "wasi_snapshot_preview1.fd_write")
    for name, (path, expected) in runtime.FIXTURES.items():
        source = runtime.ROOT / path
        assert runtime.sha256(source) == runtime.BASELINE_HASHES[name]
        output, _ = instrument(name, source, *common, "--stack-layout", budget=(1 << 63) - 1)
        for engine in ("wasmoon", "wasmtime"):
            runtime.run(f"{engine}-workload-{name}", runtime.invoke(engine, output),
                        lambda code, out, _err: code == 0 and out == expected)


if __name__ == "__main__":
    runtime.OUT = OUT
    OUT.mkdir(parents=True, exist_ok=True)
    runtime.run("build", ["moon", "build", "--target", "wasm", "--debug", "cmd/instrument"],
                runtime.ok, timeout=180)
    runtime.artifact("instrument-cli", TOOL)
    for tool, version in runtime.VERSIONS.items():
        runtime.run(f"version-{tool}", [tool, "--version"],
                    lambda code, out, err: code == 0 and version in out + err)
    runtime.run("version-moon", ["moon", "version"], runtime.ok)
    bounds()
    policy()
    stack()
    workloads()
    print("S09 policy and S10 stack audit checks passed")
