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

## Against the native tools

The whole-program comparison lives here too, in `tools/bench/showcase.jsl`: each load-order tool
run from its package on jess, next to the native program it ports, over the real load order, and
whether both wrote the same files. The workloads are TES3Merge, S3LightFixes (with and without
the interior sun), Merged Lands, and the doctor in three configurations; `jess run
tools/bench/showcase.jsl list` names them. Each side runs in a fresh folder holding a flattened
copy of the config, with a home of its own and every `JESS_*` and `OPENMW_*` variable removed,
timed by GNU time, alternating, and `tools/bench/equivalence.jsl` then gives every output a
verdict: identical, identical except the timestamp, a known difference with its reason, or a
mismatch, which fails the run.

```sh
jess run --capability filesystem.read --capability filesystem.write \
  --capability process.spawn --capability process.environment \
  tools/bench/showcase.jsl run [--packages FOLDER] [--packed] [--no-native] [--runtime TEXT] ...
```

Run it from this checkout on a verified release build of jess (`jess --version` says when a build
isn't one, and the harness refuses it). The packages default to the folder this checkout sits in,
where its siblings are checked out; `--packed` packs each tool's activation plan into
`target/bench/jpk` first and measures the JPKs. The native binaries are `tes3merge` and
`s3lightfixes` on `PATH` or named with `--tes3merge` and `--s3lightfixes`, and Merged Lands built
from source and named with `--merged-lands`; `--no-native` measures the ports alone. The binary
names its runtime but not the runtime's release, so pass `--runtime "l3i 2.1.2"` when the results
should say which. `tools/bench/showcase/flatten.jsl` and `facts.jsl` are the helpers it drives:
the flattened config, and what each tool's module reports about the load order.

Results land in `target/bench/results/<time>-showcase.json`; the ones kept, by l3i release and
machine, are under `tools/bench/results/` (`-packed` for a run over JPKs). `--against RESULTS`
compares a run's outputs with a kept file's by hash.

### The latest results

From `tools/bench/results/l3i-2.1.0-i7-10870h-showcase.json`, measured 2026-10-15 on the
i7-10870H under the `performance` governor, with a verified release build of jess 0.1.0 (`47cca80`,
its tree carrying uncommitted changes) on l3i 2.1.0. The load order is 69 content files, 52 of
them plugins totalling 451 MB, from 118 data folders. Each figure is the median of five runs after
one warm-up; CPU is user plus system time, and memory is peak resident set size.

| Workload | Native | Jess | Faster | CPU, native | CPU, Jess | Memory, native | Memory, Jess | Outputs |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| TES3Merge | 10.89 s | 0.69 s | 15.8x | 30.69 s | 0.68 s | 1,453 MiB | 703 MiB | known differences |
| S3LightFixes | 0.67 s | 0.59 s | 1.14x | 2.52 s | 0.55 s | 1,470 MiB | 549 MiB | identical |
| S3LightFixes, interior sun | 0.77 s | 0.67 s | 1.15x | 2.60 s | 0.65 s | 1,470 MiB | 622 MiB | identical |
| Merged Lands | 11.50 s | 3.14 s | 3.66x | 11.66 s | 3.05 s | 5,680 MiB | 1,130 MiB | mismatch, below |
| doctor, every check | | 11.62 s | | | 11.52 s | | 2,492 MiB | |
| doctor, assets and meshes | | 11.30 s | | | 11.18 s | | 2,493 MiB | |
| doctor, the other four | | 0.95 s | | | 0.93 s | | 665 MiB | |

The packed run (`-packed`) reads the same: TES3Merge 0.74 s, S3LightFixes 0.60 s and 0.70 s,
Merged Lands 3.17 s. The doctor has no native program to race; it is timed so that a change to it
shows.

TES3Merge's differences are the native program's, and the harness names each: it copies the
garbage in AIDT padding into the creatures it merges, so it writes four creature records that
change nothing; it writes MGEF subrecords in TES3Lib's property order rather than the order of the
Construction Set, OpenMW, and every source plugin, so it writes three magic effects that change
nothing; and it keeps a cell's NAM0 while leaving out every reference that NAM0 counts. The port
writes neither the no-op records nor the stale count.

The Merged Lands mismatch moved on the native side. The `merged_lands` measured here
(`5b654e77…`) writes 10,064 LAND records in 202,731,508 bytes; the one measured on 2026-09-30
(`377bd356…`, in `legacy/l3i-1.0.0-i7-10870h-showcase.json`) wrote 2,144 in 64,172,093, and
those normalized to the same digest the port wrote then and writes now. Which native build is
right isn't settled; until it is, the Merged Lands row is a time, not a verified equivalence.
