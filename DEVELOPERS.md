# Developing Fetch

Everything a new contributor needs that is not obvious from reading the code:
how to build it, what decides what, and the rules that explain why the code
looks the way it does.

Requires **macOS 26** and **Xcode 26**. Swift 6 language mode throughout.

- [`README.md`](README.md) — what Fetch is, for the people using it
- [`BACKLOG.md`](BACKLOG.md) — what is not built, and why
- [`docs/HANDOFF.md`](docs/HANDOFF.md) — the running engineering log. **Read it
  before starting anything.** It is where measurements, dead ends and known gaps
  are recorded, and it is more current than this file by design.
- [`docs/frontend-component-study.md`](docs/frontend-component-study.md) — an
  audit of the design system and a proposal for taking it to a proper atomic
  hierarchy

> The two `docs/` links above resolve in this repository only. `docs/` is
> excluded from the public copy by `scripts/publish-public.sh`; this file and
> `README.md` are at the root so that they are not.

---

## Build and test

```bash
# The app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Fetch.xcodeproj -scheme Fetch -configuration Debug build

# The logic, and its tests — this is where the coverage is
cd FetchKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# Build, test, and relaunch the app in one go
./scripts/preview.sh        # -q skips the tests
```

If `xcodebuild` reports *"tool 'xcodebuild' requires Xcode"*, the active
developer directory is pointing at the Command Line Tools:

```bash
sudo xcode-select -s /Applications/Xcode.app
```

**Live suites are opt-in, and gated individually** rather than all on one flag:

| Suite | Needs |
|---|---|
| `LiveInternetArchiveTests`, `LiveGutenbergTests` | `FETCH_LIVE=1` |
| `LiveProwlarrTests` | `FETCH_PROWLARR_URL` + `FETCH_PROWLARR_KEY` (its indexer-root test also `FETCH_INDEXER_ROOT`) |
| `LiveJackettTests` | `FETCH_JACKETT_URL` + `FETCH_JACKETT_KEY` — the URL is the bare host, e.g. `http://10.0.0.181:9117` |
| `LiveEndToEndTests`, `LiveTorBoxSmokeTests` | `FETCH_TORBOX_API_KEY` |
| `LiveSegmentBenchmarkTests` | `FETCH_TORBOX_API_KEY` **and** `FETCH_BENCHMARK=1` — it moves real gigabytes |
| `DownloadStoreMigrationTests` | `FETCH_MIGRATION_STORE` pointing at a copy of a real store |
| `TorrentFileTests`' large-torrent case | `FETCH_TORRENT_FIXTURE=<path>` |

---

## Layout

| Path | What lives there |
|---|---|
| `Fetch/` | The app target — SwiftUI views, `AppModel`, the design system. **No test bundle.** |
| `Fetch/DesignSystem/` | Tokens (`Palette`, `Dimension`, `Typography`) and 30-odd components |
| `FetchKit/Sources/FetchKit/` | Every decision: search, ranking, routing, transfers, persistence, organisation |
| `FetchKit/Sources/FetchPluginAPI/` | The DTO and protocol boundary plugins compile against. Depends on nothing. |
| `FetchKit/Tests/` | The only place anything is tested |
| `scripts/make-xcodeproj.py` | Generates `Fetch.xcodeproj` — see below |
| `scripts/preview.sh` | Build, test, relaunch |
| `scripts/publish-public.sh` | Rebuilds `github.com/nikeplusdash/Fetch` as a filtered orphan commit |
| `web/` | The site, one self-contained file |

---

## Two rules that explain most of the codebase

### Views delegate, never decide

The app target **has no test bundle**. Anything that decides something inside a
view, or inside `AppModel`, cannot be tested. Decisions belong in `FetchKit`,
where `swift test` reaches them.

When a view looks like it is choosing, ranking, parsing or formatting, that is a
bug in the making — this repo has had to move the same logic down three times.
`Faceting`, `PastedLink`, `LinkAvailability`, `TorrentFile`, `IndexerLabel`,
`ArchiveFileSelection`, `DownloadItem`, `SearchScreenState`, `DownloadFilter`,
`DownloadLibrary`, `DownloadSubline` and `ResultPresentation` all live in
FetchKit for exactly this reason. A view should render a case and call a method.

### No P2P participation, ever

Fetch never joins a swarm. Torrent metadata comes from an HTTPS `.torrent` fetch
with **mandatory SHA-1 infohash verification**; any swarm work belongs to the
debrid service. This rules out BEP 9 and DHT, which would announce the user's IP
to every peer in the swarm.

`.torrent` files chosen or dropped by the user are parsed locally (`TorrentFile`,
built from `Bencode`, `InfoHash` and `TorrentMetadata`). Only the infohash
leaves the machine.

---

## The backend

Everything below is in `FetchKit`, and everything below has tests.

### The plugin boundary

`FetchPluginAPI` is a separate module that depends on nothing. It holds the DTOs
and the two extension points:

```swift
public protocol SearchProvider: Sendable {
    var id: SearchProviderID { get }
    var displayName: String { get }
    func capabilities() async throws -> ProviderCapabilities
    func search(_ query: SearchQuery) async throws -> [SearchResult]
}

public protocol DebridProvider: Sendable {
    var canReportCacheStatus: Bool { get }
    func previewFiles(rawMagnet:infoHashHex:) async throws -> [DebridFile]?
    func checkCached(hashes:listFiles:) async throws -> [String: CacheEntry]
    func submitMagnet(rawMagnet:) async throws -> DebridTorrentID
    func downloadURL(torrent:file:) async throws -> URL
    func supportedHosts() async throws -> [DebridHost]
    // …
}
```

Two members exist because the three services genuinely differ, and assuming
otherwise shipped bugs:

- **`canReportCacheStatus`** — Real-Debrid disabled `instantAvailability`, and
  the only remaining way to learn whether it holds a torrent is to *add* the
  torrent, which a badge check must never do. False means excluded from badge
  checks, **not** "reports every hash as a miss".
- **`previewFiles`** — TorBox answers from `checkCached(listFiles: true)`,
  Premiumize from `/transfer/directdl`, Real-Debrid cannot answer at all (its
  file ids only exist after `addMagnet`). Assuming the TorBox shape produced an
  empty file picker for every Premiumize result.

Adding a fourth debrid service is a conformance, not a fork through the app:
`DebridKind` derives from the provider types and carries the constructor.

### Search

```
SearchQuery
  → SearchAggregator.participants(for:)     which providers will actually be asked
  → SearchAggregator.stream(_:offsets:)     fan-out, one AsyncStream of SearchEvent
  → StreamedResultAccumulator               per-provider buckets, replace or append
  → dedupe → parse → rank → filter
  → [SearchResult]
```

- **Fan-out is concurrent with a per-provider timeout.** One dead indexer must
  not empty the table, so failures are carried in the `Outcome` alongside the
  results rather than thrown.
- **`participants(for:)` filters before the count is published.** A provider
  that cannot answer must not count toward "3 of 7 indexers", because the user
  reads the shortfall as indexers having failed. `CategoryIntersection.resolve`
  turns requested ∩ advertised into send / skip / send-verbatim. A provider
  advertising *no* categories is asked anyway — absence of caps is not evidence
  of absence of coverage.
- **Caps are cached per indexer, six hours** (`TorznabCapsStore`, an actor that
  outlives one search). Caching on the provider *instance* caught nothing,
  because `AppModel.torznabProviders()` builds fresh instances per search.
- **A server is discovered into individual indexers, both kinds.**
  `IndexerSetup.plan` tries `ProwlarrDirectory` (`/api/v1/indexer`, JSON), then
  `JackettDirectory` (`t=indexers` on the Torznab API, XML), then falls back to
  one resolved endpoint. Jackett's roster embeds each indexer's `<caps>`, so
  `SubIndexer.advertisedCategories` is filled without eleven extra round trips.
  Jackett's *other* roster — the `/api/v2.0/indexers` REST route — is behind the
  dashboard login and the API key does not open it; measured, so do not reach
  for it. The aggregate endpoint a pre-discovery Jackett saved is recognised
  (`JackettDirectory.isAggregate`) and retired once its parts arrive.
- **A rejected key arrives as HTTP 200.** Torznab reports it in-band as
  `<error code="100" …/>`, which is well-formed XML that parses into an empty
  caps set, an empty roster and an empty feed. Every parser captures a root
  `<error>` and throws (`TorznabErrorDocument`); without that, endpoint
  resolution saved a broken server and called it connected.
- **Indexers can be reserved for category pills** (`SubIndexer.areas`, nil for
  all). `AppModel.activeIndexers(for:)` narrows the fan-out *before* the
  aggregator is built, for the same reason `participants(for:)` filters: an
  indexer that was never asked must not count toward "3 of 7 indexers".
- **Every asked indexer resolves before a search ends.** `SearchEvent.started`
  carries the provider roster rather than a count, so `.finished` can reconcile
  against it and record anyone missing as `SearchError.neverAnswered`. A count
  cannot be reconciled — a dropped event ended the run at "6 of 7" and cleared
  the progress bar anyway.
- **Paging is per provider.** Providers clamp a requested page to what they will
  serve, so one shared offset skipped everything between what a provider gave
  and what it was asked for. The only honest next offset is how many that
  provider actually delivered. A page that adds nothing new ends the scroll; no
  source reliably reports "last page".

### A result is not a torrent

`SearchResult.id` used to be an `InfoHash`, and anything without one was dropped
in the parser — which discarded every Internet Archive item, every Gutenberg
book and every hoster link before it could render. Now:

```swift
enum ResultOrigin {
    case torrent(infoHash:magnet:targetPath:)
    case hosted(url:host:)
    case direct(url:)
}

struct SearchResult {
    var candidates: [ResultOrigin]   // ordered best-first
    // …
}
```

- A result is dropped only when it has **no** candidates, never for want of an
  infohash.
- `infoHashHex` / `magnetURI` are **optional on purpose**. Returning `""` would
  key the cache dictionary on an empty string and badge every direct result with
  whatever the last one resolved to.
- Format preference reorders candidates **within** a result, not results. One
  Gutenberg book is one row with a link per format. `SearchResult.init` re-sorts
  candidates by `preferenceRank`; format order survives only because that sort
  is stable and every `.direct` shares rank 0. Do not "simplify" it.

### Ranking

**Name-match bucket → per-kind quality → popularity.**

- The bucket is **coarse on purpose** (exact title / all query tokens / some /
  none). A continuous relevance float never ties, so it would silently become
  the only sort key and every ranking under it would do nothing observable.
- **`kindScore` and popularity are both normalised 0…1, and they are coupled.**
  The video term once ranged 0…6 against a 0.35 popularity weight; normalising
  quality alone made popularity ~10× more influential and a 500,000-download
  scanned PDF beat a retail EPUB. Popularity is `min(log10(n+1)/5, 1)`.
  **Change one, re-check the other.**
- An unclassified result is ranked on whatever axes its metadata carries, rather
  than mapped to a zero-scoring generic.

### Metadata, and who wins

`ReleaseNameParser` parses the title; providers also *state* fields. **Stated
beats parsed**, and `ReleaseMetadata.provenance` is what decides — the model
already meant "a source said this". `ReleaseMetadataMerger.mergingStated`
carries `.attribute` fields across; a Torznab result arrives with empty
provenance, which makes the stage exactly a no-op for it.

**A stated field with no value is skipped.** Internet Archive marks
`.title: .attribute` unconditionally while its title is optional, and copying
that nil deleted the title the parse had recovered.

Provenance is also what the UI renders: a stated value draws as a solid chip, an
inferred one dashed and quieter. It is the same signal that gates renaming.

### Routing to a debrid

`DebridRouter` picks the service, in the user's preference order:

- **Torrents** — a service that already has it cached beats a more-preferred one
  that does not, falling back to the first configured service.
- **Hosted links** — `SupportedHostsCache` holds a host list per provider (6h
  TTL) and `provider(forHost:)` picks the first, in preference order, that
  covers the host. **There is no fallback here**, unlike torrents: an uncovered
  host is not a slower download, it is one that cannot happen.
- **Host matching is on label boundaries.** `evil-mediafire.com` contains
  `mediafire.com`; matching by substring would hand an attacker-chosen URL to
  the user's debrid.
- **`unknowable` is not `notCached`.** It has its own case everywhere the
  question is asked — badges, the cached-only filter, the add-link sheet.
  Collapsing them tells a Real-Debrid-only user that nothing is ever cached.

### Downloads

`DownloadEngine` is an **actor** owning the job table, the queue and the run
set, publishing an `AsyncStream<DownloadEvent>` that `AppModel` folds into view
state.

- **`segmentsPerFile == 1` uses `RangeTransfer`** — one open-ended range,
  skipping preallocation, a seek per chunk and the `SegmentWriter` actor.
  Anything higher uses `SegmentedTransfer`. One connection measured fastest on
  the line this was developed on; see `README.md` for the table and
  `LiveSegmentBenchmarkTests` to re-measure.
- **Bad statuses are classified, not lumped.** 403/410 re-resolves the link once
  and keeps the segments that landed; 429/5xx retries with backoff; a 200 falls
  back to a whole-file transfer; anything else reports itself. Throwing one
  error for every non-206 answer is what made a single expired link kill a
  download permanently.
- **The fallback must truncate first.** `preallocate` grows the `.fetchpart` to
  full length before the first request, and `RangeTransfer` reads a partial's
  length as "how much is done" — so falling back without truncating renamed a
  file of zeros into place and reported it Completed.
  `SegmentedRecoveryTests.theFallbackDoesNotRenameThePreallocatedZeroesIntoPlace`
  fails without that one line.
- **`LaunchRecovery` prefers the persisted `SegmentMap`** over the file's length
  for the same reason. The file's length is still the answer for
  single-connection downloads, which never preallocate and have no map.
- **A preparation is not a download.** `beginPreparation` returns after the
  submit and reports the service's own progress as `.preparation*` events, so an
  uncached magnet does not hold a sheet open for hours. Preparations are
  deliberately **not persisted** — restoring a live poll is not restoration.

### Persistence

`DownloadStore` (SwiftData) at
`~/Library/Application Support/Fetch/downloads.store`, beside the credential
store rather than at SwiftData's unnamespaced default.

- **`DownloadGroupKey` is content plus attempt**, minted once per queueing
  action. Keyed on content alone, every file ever queued from a torrent shared
  one row for the life of the app: cancelled corpses summed into the total, the
  progress bar divided by that total, and one cancelled sibling could file a
  working download under Failed. It is persisted; rebuilding it from the
  infohash would re-merge every attempt on the next launch. A key with no
  separator is a pre-attempt row and still groups by content.
- **`DownloadRecord.finalPath` is stored.** "Is the file still there?" was being
  re-derived from the request, which misses a rename *and* the `(2)` suffix
  `PathSanitizer.disambiguate` may have added. It is also what makes *Show in
  Finder* work after a relaunch.
- **`.missing` is its own state**, not `.failed`. Reporting a user-deleted file
  as failed is two lies in one word: nothing about the transfer failed, and
  `.failed` is resumable — so the row offered a Resume that would silently
  re-download a file someone deleted on purpose.
- Schema changes are verified against a copy of a real store
  (`DownloadStoreMigrationTests`).

### Credentials

`FileCredentialStore` is the only credential store — a `0600` file per secret
under `~/Library/Application Support/Fetch/`. **There is no Keychain
implementation, and adding one is a migration question, not a feature.** An
ad-hoc signature changes on every build, so macOS treats each build as a new app
and re-prompts every launch; the previous Keychain store stranded a live API key
with no migration path, which is why it was deleted outright rather than kept as
a second store nothing selected.

### Organisation

`Routing` (first-match-wins rules over `ReleaseMetadata`) picks a subfolder;
`NamingStrategy` renames, **only on a confident parse** — a weak parse keeps the
source's filename rather than producing `Unknown (0000).mkv`. The original name
is stored, so *Revert Rename* is always available.

`ItemFolder` gives a source item's files a folder named after the item. A
torrent's per-file relative path already carries its folder; an Internet Archive
item's paths are relative to the item, so without this eight files from one item
landed loose in `Movies/` and the row read "8 files".

### Logging

`FetchLog` writes `~/Library/Logs/Fetch/fetch.log`, truncated from the front
past 2 MB. **Redaction is applied at the call site**, through `LogRedaction`,
because a redaction applied centrally has to guess what each field means — the
caller knows whether a string is a filename or a status word. The point of a
file rather than `os_log` is "send me your log".

---

## The frontend

### `AppModel`

One `@Observable` `@MainActor` class, injected through the environment. It owns
preferences, the engines, the search stream and the fold from `DownloadEvent`
into view state. It is **2,950 lines**, which is a known problem; the split is
planned in `docs/HANDOFF.md`.

The behaviour that has been split out lives in `AppModel+Library`,
`+Destination`, `+Appearance` and `+ServiceHealth`. **Swift forbids stored
properties in extensions**, so every property those files need is declared once
in `AppModel.swift`. Do not move the properties. The ordering constraint for
finishing the split: the ~20 `didSet` preference properties cannot move to an
extension until they become computed over one stored `AppPreferences`.
Preferences first, then the split — the reverse leaves the largest block behind
and churns it twice.

### Design tokens

Every number and colour in the UI comes from one of these:

| Token set | File | Holds |
|---|---|---|
| `Spacing` | `DesignSystem/Dimension.swift` | `s2 … s24`, four-point grid, two-point half-steps for hairline nudges only |
| `Radius` | " | `r4 … r16` |
| `RowHeight` | " | Row heights and the intra-row gaps |
| `ColumnWidth` | " | Fixed widths for every list column |
| `WindowMetrics` | " | Window chrome: insets, bar heights, traffic-light geometry |
| `IconSize` | " | `xs 10 · sm 12 · md 14 · lg 16 · xl 20` |
| `FetchFont` | `DesignSystem/Typography.swift` | The type scale, plus `.sectionLabel()` |
| `Palette` | `DesignSystem/Palette.swift` | Semantic colour, resolved from the active theme |

Two of these carry rules that are load-bearing rather than stylistic:

- **`contentInset` (20) and `sheetInset` (16) are the only two horizontal
  insets in the app. A third is a bug.** The results header sat outside its own
  columns for a while because two insets existed that nobody had written down.
- **Column widths are fixed and must stay fixed.** An unconstrained `Text`
  reflows the whole row up to ten times a second as a download's numbers change.
  A column that does not fit at the minimum window size (900 × 560) should be
  **dropped at a breakpoint**, never made flexible.

### Theming

`Palette` resolves every token from `ActiveTheme.shared.theme`. **No token was
renamed, added or removed when it started doing so** — which is the entire
reason three themes could be added last, after two screens had been rewritten in
other worktrees, without a single screen changing.

- A theme may change surfaces, the four ink levels, material and selection fill.
- It may **not** change layout, which glyph a state uses, any copy, or the
  meaning of a colour. Green is "landed" in all three, and `ThemeTests` asserts
  it.
- The palettes themselves live in **FetchKit**, purely so the contrast floor can
  be measured by a test. Every ink level on every surface in every theme clears
  its floor, measured *composited* — a 10%-opacity hairline measured as if it
  were solid reports a ratio nobody will ever see.
- `ActiveTheme` is `@Observable`, which is what makes a *static* read
  (`Palette.textSecondary`, from 79 call sites with no model and no binding)
  still invalidate exactly the views painted with it.
- Colours are built as dynamic `NSColor`s per read, not cached — a cached
  dynamic colour keeps resolving from the theme it was built for, which is a
  window half in one theme and half in another.

**If a screen looks wrong in one theme, it is hard-coding a colour.** The fix is
in that screen, not in `Palette`.

### Errors leave the window

`errorMessage` was written in five places and shown in none, then shown in a
banner that was *part of the layout* and moved every screen it appeared on. It
is now handed to `ErrorPanel` — an overlay outside the layout, at the app level
so a download failing while the user is on Search still reaches them — and
cleared immediately, because an alert is an event, not a state.

There are two seams into it, and they are one object: `\.errorPresenter` in the
environment for views, and `ErrorPresenting.current` for the model, which raises
sentences from inside file-dialog callbacks where there is no environment.

### Window chrome

The title bar is hidden and the two columns own the window from its top edge.
Three things about that are not obvious:

- **It is an `HStack`, not a `NavigationSplitView`.** The split view draws its
  content as a rounded glass surface inset inside the window frame with a
  specular edge, so the window read as a panel floating on a frame and no
  background could merge the two. The cost is column resizing and `List`
  selection in the sidebar, which three fixed items never needed.
- **Hiding the title bar does not hand its space back** — the window still
  insets content by the height of the bar it no longer draws. `.ignoresSafeArea`
  closes it, and each column then pads itself by the one shared number.
- **A view that declares a toolbar item makes AppKit build a toolbar for the
  whole window**, which moves the traffic lights. Downloads' Add button is a
  plain button in the bar for exactly this reason.
- The window's material is painted **once**, in `containerBackground`. Painting
  it per view stacks material on material: two 40%-opaque layers are 64% and a
  third is 78%, which is a grey box with extra steps.

### Frontend coding principles

The rules the existing code follows. Each one is here because breaking it
shipped a bug.

1. **A view renders a case and calls a method.** If it is choosing, ranking,
   parsing or formatting, that belongs in FetchKit.
2. **No view declares `Font.system(size:)` for text.** Type comes from
   `FetchFont`; a size written into a view is a size no other view can agree
   with. (Icons currently do declare `.system(size: IconSize.x)` — see the
   study.)
3. **No view declares a colour.** No `Color.red`, no `.foregroundStyle(.secondary)`.
   Semantic tokens only, or the theme cannot reach it.
4. **No raw numbers in layout.** Spacing, radii, row heights and column widths
   are tokens.
5. **Fixed widths for anything numeric that changes.** Reserve the width of the
   longest realistic string; let the digits change inside it.
6. **State the geometry rather than deriving it from padding.** The search field
   is `RowHeight.searchField`, not "whatever 12 points around a line of text
   comes to" — because while a search runs it also holds a progress bar, and a
   padded field grew the moment you pressed Return.
7. **A control that appears mid-typing must not be focusable.** A focusable
   control appearing inside the field's row moves first responder, and an
   `NSTextField` that becomes first responder selects all its text — so the next
   keystroke replaces the query. This is what "I cannot type any more" was.
8. **Never index a collection from a row's position.** Bind by `id` and look up.
   Deleting a debrid provider by index crashed the app; the routing rules had
   the same bug.
9. **Make the row the target, not the glyph.** A 14-point checkbox in a dense
   list is under a third of what a pointing device wants.
10. **Say the state that is "not asked yet".** Four states, not three: drawing
    "unknown" as a failure makes every launch look broken for as long as the
    network takes, and drawing it as success is a claim with no evidence.
11. **An empty state still keeps the screen's structure.** Removing the filter
    bar from an empty list means the screen changes shape when the first row
    lands.
12. **Copy carries no em-dash**, and `MicrocopyTests` asserts it over an
    enumerable list of every user-facing sentence the package can produce. The
    rule is not punctuation for its own sake: splitting the clause is usually
    what shortens it.

---

## Conventions and traps

### The Xcode project is generated *and* committed

`scripts/make-xcodeproj.py` writes `Fetch.xcodeproj/project.pbxproj`, **which is
tracked**. An edit made in Xcode's UI looks like it worked, commits cleanly, and
is destroyed the next time anyone runs the script.

- Build settings, entitlements, capabilities → edit the script.
- `Fetch/Info.plist` is a real tracked file and is safe to edit directly.
- **New `.swift` files need no project edit.** The target uses a
  `PBXFileSystemSynchronizedRootGroup`, so everything under `Fetch/` compiles
  automatically. The flip side: a file you forget to `git add` still builds on
  your machine and breaks a fresh clone, with no project diff to explain why.

### The app is ad-hoc signed and not sandboxed

`CODE_SIGN_IDENTITY = "-"`, hardened runtime on, no entitlements file. This is
why the Keychain was abandoned, why notifications are refused, and why a
downloaded build needs the Privacy & Security route to open. **A real signing
certificate is the fix for all three; no code change helps.**

`startAccessingSecurityScopedResource()` in `AppModel.magnet(fromTorrentFileAt:)`
is defensive — a no-op unsandboxed. Keep it.

### Swift does not number error enum cases in declaration order

**Read this before decoding any error number in this project.** The `NSError`
bridge numbers every case *with* a payload first, then every case without.
Counting down the declarations of `DownloadError` to decode "error 6" gives you
`.debrid` and sends you into the debrid layer, where nothing is wrong; the
answer was `.rangeNotSupported`. Both error enums are `LocalizedError` now, so
nobody should have to do this again.

### Ask the file system the question you actually have

`FileManager.attributesOfItem` returns the whole attribute dictionary, and
building it reads the file's **extended attributes** — so "how big is this file"
issues a `getxattr`, which can block in the kernel indefinitely. That wedged the
main thread for 60 seconds before the first window. `FileSize` calls `stat`.

**Not `URL.resourceValues(forKeys:)`** either, which is the obvious Foundation
answer and wrong for its own reason: a `URL` caches resource values it has
fetched, so a transfer re-reading its partial's size would resume from a stale
offset.

**No file system on the launch path**, whatever the stats cost.

### Recurring failure modes in this repo

Check for these before adding anything. Every one has bitten more than once.

1. **Infrastructure built and never connected.** `DownloadEvent.removed` was
   declared *and handled* with no producer anywhere, which is why a cancelled
   row could never be cleared. `errorMessage` had five writers and no readers.
   `download_present` was decoded and dropped on the floor, so a finished TorBox
   torrent was polled forever.
2. **`guard … else { return }` swallowing conditions the user needed to see.**
   Five bugs traced to it.
3. **Substring checks on paths.** Three times. `!name.contains("/")` discarded
   8,890 of 8,891 Internet Archive files. **Assert where the result lands, never
   what the string contains.**
4. **Asserting the wrong property.** The test for #3 passed while the code was
   wrong, because it checked the string rather than the resulting URL.

### Process

- **Run the app and look at it.** Several bugs in this repo's history were only
  ever visible in the UI, and the FetchKit suite passing says nothing about
  whether a screen renders.
- **Do not synthesize keystrokes or blind clicks.** Launch the app, bring it
  frontmost, and hand over. Capture only Fetch's window:
  `screencapture -R x,y,w,h`.
- The app icon is drawn in code (`AppIconArtwork` in FetchKit) and rendered into
  the asset catalogue:
  ```bash
  swift run --package-path FetchKit IconRenderer Fetch/Assets.xcassets/AppIcon.appiconset
  swift run --package-path FetchKit IconRenderer --preview design/icon/drift-preview.png
  swift run --package-path FetchKit IconRenderer --hours design/icon/sky-through-the-day.png
  ```
- `scripts/publish-public.sh` rebuilds the public repo as a **filtered orphan
  commit** — `docs/`, `design/`, `.claude/` and `.superpowers/` are excluded, and
  both branches are rebuilt from scratch every run. Anything you want public
  must live outside those directories.
