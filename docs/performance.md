# FuelGuard 0.2.0 performance

The reference runs measured full production instrumentation and a Fuel-only variant against the original in wasmoon 0.18.0 and Wasmtime 50.0.0. The three application workloads were scalar MoonBit JSON5 parsing, Lisp interpretation and SHA-256. Testing ran under x86-64 Ubuntu on WSL2 with glibc 2.39 and an Intel Core Ultra 9 185H.

## Runtime overhead

The table gives the upper bounds of the 95% confidence intervals for the geometric mean of per-application median time ratios. Lifecycle includes instantiation, core start and the business entry. The hot window measures calls on an initialized instance.

| Engine | Lifecycle upper bound | Hot-call upper bound |
| --- | ---: | ---: |
| wasmoon | 1.509× | 1.410× |
| Wasmtime | 1.780× | 1.795× |

The largest per-application median and p95 ratio upper bounds were 2.369× and 2.115×. The timing target was at most 2× for each engine and window's geometric mean, and at most 3× for each application's median and p95. The independent sample used 20 paired worker processes per engine, workload and window, each with 300 timed cycles after warmup. The analysis resamples complete worker series.

The published instrumenter reproduced the five protected reference Wasm files and manifests byte for byte. The runtime results reuse the original measurements. The Lisp reference measurement uses the wasmoon benchmark worker at a depth beyond the Linux product runner's admission limit. A separate bounded Lisp input completes through the product runner. [Reproduction](reproduce.md)

## Size

| Workload | Original | Full protection | Manifest |
| --- | ---: | ---: | ---: |
| JSON5 | 12,628 B | 34,293 B | 640 B |
| Lisp | 10,268 B | 27,953 B | 641 B |
| SHA-256 | 10,219 B | 24,462 B | 640 B |
| Scalar MoonBit demo | 441 B | 1,355 B | 574 B |

The large modules ranged from 2.394× to 2.722×. The separate small module added 914 B. The targets were a maximum 3× ratio for inputs of at least 10 KiB and a maximum 15 KiB increase for smaller inputs.

The separate Linux launcher construction check processed a 4 MiB Wasm input in at most 5.816 seconds with a 410,188 KiB peak RSS over three runs. The launcher sets allocator parameters before starting Moonrun. [Reproduction](reproduce.md)
