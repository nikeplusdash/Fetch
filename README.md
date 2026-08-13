# Fetch

A native macOS debrid download manager. Search indexers and open catalogues,
check what your debrid already has cached, and pull it down over plain HTTPS.

Requires macOS 26+ and Xcode 26. Swift 6 language mode throughout.

## Build and run

```bash
# The app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Fetch.xcodeproj -scheme Fetch -configuration Debug build

# The logic, and its tests
cd FetchKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

If `xcodebuild` reports *"tool 'xcodebuild' requires Xcode"*, the active
developer directory is pointing at the Command Line Tools:

```bash
sudo xcode-select -s /Applications/Xcode.app
```

## Layout

| Path | What lives there |
|---|---|
| `Fetch/` | The app target — SwiftUI views, `AppModel`, the design system. **No test bundle.** |
| `FetchKit/Sources/FetchKit/` | Every decision: search, ranking, routing, transfers, persistence. |
| `FetchKit/Sources/FetchPluginAPI/` | The DTO and protocol boundary third-party plugins compile against. Depends on nothing. |
| `FetchKit/Tests/` | 1047 tests. The only place anything is tested. |
| `scripts/make-xcodeproj.py` | Generates `Fetch.xcodeproj`. See the warning below. |
| `web/` | The site at [nikeplusdash.github.io/Fetch](https://nikeplusdash.github.io/Fetch/) — one self-contained file. |

## Two rules that explain most of the codebase

**Views delegate, never decide.** The app target has no test bundle, so anything
that decides something inside a view or inside `AppModel` cannot be tested.
Decisions belong in `FetchKit`, where they are reachable from `swift test`. When
a view looks like it is choosing, ranking, parsing or formatting, that is a bug
in the making — the repo has had to move the same logic down three times.

**No P2P participation, ever.** Fetch never joins a swarm. Torrent metadata
comes from an HTTPS `.torrent` fetch with mandatory SHA-1 infohash
verification; any swarm work belongs to the debrid. This rules out BEP 9 and
DHT, which would announce the user's IP to every peer.

## Two things that will surprise you

**The Xcode project is generated *and* committed.** `Fetch.xcodeproj/project.pbxproj`
is written by `scripts/make-xcodeproj.py`, and it is tracked. An edit made in
Xcode's UI will commit cleanly and then be destroyed the next time anyone runs
the script. Change build settings in the script, not in Xcode.

**New source files need no project edit.** The target uses a
`PBXFileSystemSynchronizedRootGroup`, so everything under `Fetch/` is compiled
automatically. The flip side: a new file that you forget to `git add` still
builds on your machine and breaks on a fresh clone, with no project diff to
explain why.

## One measurement worth knowing before you tune anything

**One connection per file is the default, and it is correct.** Measured against
a TorBox CDN link and archive.org on a ~90 Mbps line:

| segments | TorBox CDN | archive.org |
|---|---|---|
| **1** | **9.2 MB/s** | **9.2 MB/s** |
| 4 | 8.9 MB/s | — |
| 8 | 8.1 MB/s | 7.8 MB/s |
| 16 | 8.7 MB/s | 8.7 MB/s |

A single stream won every time; splitting cost up to 37%. Three *different*
links in parallel could not beat ~11.7 MB/s combined, which is the line rather
than the client. On a faster connection splitting should win, which is why the
setting stays — re-measure with `LiveSegmentBenchmarkTests` before changing it.

## What is not built yet

[`BACKLOG.md`](BACKLOG.md) — more hosters and debrid services, and notifications
(written, and refused by macOS until the app has a real signing identity).

## Requirements

macOS 26 or later. Builds are ad-hoc signed, so a downloaded `.app` needs
right-click → Open the first time; macOS refuses it silently otherwise.
