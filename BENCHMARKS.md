# Benchmarks

Measured on 2026-10-14 on an Intel Core i7-10870H (2.20 GHz, 8 cores), with a verified release
build of Jess at `b12612f` on l3i 2.0.2.

```sh
jess run --capability filesystem.read --capability filesystem.write --package . \
  --package-path <folder of packages> tools/bench/bench.luau canaries --runs 9
```

DreamWind's own Luau is the dispatcher over its packages, and has no loop worth a change. What it
measures is the stack under it: the five canaries open, search, scan, decode and save plugins
through `@tes3`. This is the A/B of the whole migration onto l3i 2.0 as the canaries see it: the
same binary and the same DreamWind, with every package at its current commit against the same
folder with `@tes3` alone put back at `7518b55`, its commit before any change was made to it.
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
That is in line with `@tes3`'s own A/B (`jpk/tes3/BENCHMARKS.md`): its large gains are in
validating, string fields, subrecords and object keys, which the canaries do not exercise, while
opening and saving moved little there (1.07x for an open, no change for an untouched save). The
results under `tools/bench/results/legacy` are for an
older set of canaries (buffer, land, math, method and the rest), with different scripts, so they
are not a baseline for these.
