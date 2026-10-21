+++
title = "DreamWind"
description = "The Morrowind and OpenMW toolbench on Jess: plugins, saves, NIF models, archives, the VFS, configuration and load orders, every tool a Luau package."
date = 2026-10-21

[taxonomies]
tags = ["Jess", "Luau", "OpenMW"]

[extra]
sections = ["overview", "releases", "credits"]
+++

The Morrowind and OpenMW toolbench on Jess: plugins, saves, NIF models, archives, the VFS, configuration and load orders, every tool a Luau package.

<!-- more -->

A [Jess](https://github.com/DreamWeave-MP/jess) package, `org.dreamweave.dreamwind`. Add it to a `jess.toml` and
`jess workspace sync` pins it from this site:

```toml
[dependencies]
"org.dreamweave.dreamwind" = "0.2"
```

Every release below is the package's own archive, with its content digest beside the archive's
SHA-256; `jess.lock` pins the first and checks both.
