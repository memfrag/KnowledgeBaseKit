# Attributions

KnowledgeBaseKit itself is licensed [0BSD](LICENSE) — use it for anything, no
attribution required. That does not extend to the third-party code it vendors or
depends on, which is listed here.

**When these obligations actually bite.** Distributing the *source* of this
repository redistributes exactly one third-party work: the vendored sqlite-vec
amalgamation. Distributing a *built binary* — shipping the `kb` executable, or an
app linking `KnowledgeBaseKit` — redistributes compiled forms of everything
below, which is when the Apache-2.0 and MIT notice requirements apply to you. If
you ship a binary, include this file (or an equivalent notice) with it.

---

## Vendored in this repository

Source that lives in this repository and is redistributed with it.

| Component | Version | License | Copyright |
| --- | --- | --- | --- |
| [sqlite-vec](https://github.com/asg017/sqlite-vec) | 0.1.9 | Apache-2.0 | Copyright 2024 Alex Garcia |

`Sources/CSQLiteVec/sqlite-vec.c` and `include/sqlite-vec.h` are the unmodified
upstream release amalgamation. Full licence text:
[`Sources/CSQLiteVec/LICENSE-sqlite-vec.txt`](Sources/CSQLiteVec/LICENSE-sqlite-vec.txt).
See [`Sources/CSQLiteVec/README.md`](Sources/CSQLiteVec/README.md) for provenance
and upgrade notes.

---

## Direct dependencies

Declared in `Package.swift`, pinned in `Package.resolved`.

| Component | Version | License | Copyright |
| --- | --- | --- | --- |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | MIT | Copyright (C) 2015–2025 Gwendal Roué |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | 0.8.0 | Apache-2.0 (+ NOTICE) | Copyright (c) 2021 Apple Inc. and the Swift project authors |
| [Yams](https://github.com/jpsim/Yams) | 6.2.2 | MIT | Copyright (c) 2016 JP Simard |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache-2.0 | Apple Inc. and the Swift project authors |
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | 0.12.1 | Apache-2.0, with MIT-licensed portions | The MCP project contributors |

### On the MCP Swift SDK's licence

It is **not** uniformly Apache-2.0, and its repository metadata reports no single
licence for that reason. The project is mid-transition from MIT: new
contributions are Apache-2.0, contributions whose authors have granted
relicensing consent are Apache-2.0, and contributions from authors who have not
consented **remain under the MIT Licence**. Documentation (excluding
specifications) is CC-BY-4.0. Treat the package as Apache-2.0 *plus* MIT
obligations rather than either alone; the authoritative statement is in that
repository's `LICENSE`.

---

## Transitive dependencies

Pulled in by the above and linked into any binary built from this package.

| Component | Version | License | Pulled in by |
| --- | --- | --- | --- |
| [swift-cmark](https://github.com/swiftlang/swift-cmark) | 0.8.0 | BSD-2-Clause, with MIT-licensed portions | swift-markdown |
| [swift-nio](https://github.com/apple/swift-nio) | 2.101.3 | Apache-2.0 (+ NOTICE) | MCP Swift SDK |
| [swift-log](https://github.com/apple/swift-log) | 1.15.0 | Apache-2.0 (+ NOTICE) | MCP Swift SDK |
| [swift-collections](https://github.com/apple/swift-collections) | 1.6.0 | Apache-2.0 | swift-nio |
| [swift-atomics](https://github.com/apple/swift-atomics) | 1.3.1 | Apache-2.0 | swift-nio |
| [swift-system](https://github.com/apple/swift-system) | 1.8.1 | Apache-2.0 | swift-nio |
| [EventSource](https://github.com/loopwork/eventsource) | 1.4.2 | MIT — Copyright 2025 Mattt | MCP Swift SDK |

swift-cmark carries two licences: the cmark core is BSD-2-Clause
(Copyright © 2014 John MacFarlane), and portions derived from houdini and other
sources are MIT (Copyright © 2012 Vicent Martí). Its `COPYING` file has the
authoritative text for both.

---

## NOTICE files (Apache-2.0 §4(d))

Three dependencies ship a `NOTICE` file. Apache-2.0 §4(d) requires that their
contents be carried into derivative distributions, so they are reproduced here.

### The Swift Markdown Project

```
Copyright (c) 2021 Apple Inc. and the Swift project authors

The Swift Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

    https://www.apache.org/licenses/LICENSE-2.0
```

### The SwiftNIO Project

```
Copyright 2017, 2018 The SwiftNIO Project

The SwiftNIO Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

    https://www.apache.org/licenses/LICENSE-2.0
```

### The SwiftLog Project

```
Copyright 2018, 2019 The SwiftLog Project

The SwiftLog Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

    https://www.apache.org/licenses/LICENSE-2.0
```

Each upstream `NOTICE` also carries the standard Apache-2.0 "AS IS" disclaimer;
the full text is in the `LICENSE`/`NOTICE` files of the respective repositories.

---

## System components

Linked against but not redistributed by this project.

| Component | Notes |
| --- | --- |
| SQLite | The macOS system `libsqlite3` (3.51.0 on macOS 26), including FTS5. SQLite is in the public domain. Not bundled — it is provided by the operating system. |
| Foundation, CryptoKit, CoreServices (FSEvents), OSLog, Synchronization | Apple system frameworks, used under the terms of the macOS SDK. Not redistributed. |

---

## Keeping this current

This file is maintained by hand and describes the pins in `Package.resolved`. If
you run `swift package update`, re-check it: versions move, and licences
occasionally do too — the MCP SDK's ongoing MIT-to-Apache-2.0 transition is a
live example.
