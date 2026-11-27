# FuelGuard performance report

The reference measurements compare the original module, Fuel-only instrumentation, and full production protection in wasmoon 0.18.0 and Wasmtime 50.0.0. The application workloads are scalar MoonBit JSON5 parsing, Lisp interpretation, and SHA-256. Testing ran on x86-64 Ubuntu under WSL2 with glibc 2.39 and an Intel Core Ultra 9 185H.

## Runtime overhead

The values below are 95% confidence interval upper bounds for the geometric mean of per-application median time ratios. Lifecycle includes instantiation, core start, and the business entry. The hot-call window measures calls on an initialized instance.

| Engine | Lifecycle upper bound | Hot-call upper bound |
| --- | ---: | ---: |
| wasmoon | 1.509× | 1.410× |
| Wasmtime | 1.780× | 1.795× |

The largest per-application median and p95 ratio upper bounds were 2.369× and 2.115×. The targets were at most 2× for each engine and window's geometric mean, and at most 3× for each application's median and p95. Each engine/workload/window cell used 20 paired worker processes with 300 timed cycles per process after warmup. The analysis resampled complete worker series.

The final local candidate replayed five protected reference Wasm files and manifests byte for byte. The timing results reuse measurements collected from frozen binaries. The Lisp reference measurement uses a wasmoon benchmark worker at a depth beyond the Linux product runner's admission limit. A separate bounded Lisp input completes through the product runner.

## Artifact size

| Workload | Original | Full protection | Manifest |
| --- | ---: | ---: | ---: |
| JSON5 | 12,628 B | 34,293 B | 640 B |
| Lisp | 10,268 B | 27,953 B | 641 B |
| SHA-256 | 10,219 B | 24,462 B | 640 B |
| Scalar MoonBit demo | 441 B | 1,355 B | 574 B |

Large modules ranged from 2.394× to 2.722× their original size. The separate small module added 914 B. The targets were at most 3× for inputs of at least 10 KiB and at most 15 KiB of added Wasm for smaller inputs. Manifest sizes are reported separately.

The Linux launcher construction check processed a 4 MiB Wasm input in at most 5.816 seconds with a 410,188 KiB peak RSS over three runs. It sets allocator parameters before starting Moonrun. See the [reproduction guide](reproduce.md).
