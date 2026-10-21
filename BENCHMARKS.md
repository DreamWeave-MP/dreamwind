# Benchmarks

Measured on 2026-10-14 on an Intel Core i7-10870H (2.20 GHz, 8 cores), with a verified release
build of Jess at `b12612f` on l3i 2.0.2.

```sh
jess run --capability filesystem.read --capability filesystem.write --package . \
  --package-path <folder of packages> tools/bench/bench.jsl canaries --runs 9
```

DreamWind's own Luau is the dispatcher over its packages, and has no loop worth a change. What it
measures is the stack under it: the five canaries open, search, scan, decode and save plugins
through `@esm`. This is the A/B of the whole migration onto l3i 2.0 as the canaries see it: the
same binary and the same DreamWind, with every package at its current commit against the same
folder with `@esm` alone put back at `7518b55`, its commit before any change was made to it.
Each side ran six times, base first in odd rounds and head first in even ones, nine runs each;
each figure is the median of the six runs' medians.

| Workload | Base | Head | Ratio |
|---|---:|---:|---:|
| open | 2.565 ms | 2.110 ms | 1.22x |
| find | 20.831 ms | 20.603 ms | no change |
| scan | 23.582 ms | 23.855 ms | no change |
| decode | 6.837 ms | 6.655 ms | no change |
| save | 1.672 ms | 1.755 ms | no change |

Opening a plugin is 22 percent faster; finding, scanning, decoding and saving read no change.
That is in line with `@esm`'s own A/B (`jpk/tes3/BENCHMARKS.md`): its large gains are in
validating, string fields, subrecords and object keys, which the canaries do not exercise, while
opening and saving moved little there (1.07x for an open, no change for an untouched save). The
results under `tools/bench/results/legacy` are for an
older set of canaries (buffer, land, math, method and the rest), with different scripts, so they
are not a baseline for these.

## Which modules are native, and why

None. DreamWind's own Luau is the dispatcher over its packages, as above, and has no bench of its
own to earn a directive: what it runs fast, it runs in the packages it calls, which mark their
own hot paths. Measured 2026-10-15 with `jess 0.1.0`, the verified release build of jess
`07c38cb` on l3i 2.0.3, on the i7-10870H: a fresh `jess run --package jpk/dreamwind --package-path
jpk` of a script that only requires `@dreamwind` cost 0.0545 s with both modules marked and
0.0543 s with neither, the two alternating, the median of five each after one warm-up, the
one-minute load 1.25 at the start.
