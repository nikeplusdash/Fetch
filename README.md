# Fetch

A native macOS download manager for debrid services.

You search your indexers and a couple of open catalogues from one field, Fetch
tells you which results your debrid already has cached, and it pulls the files
down over plain HTTPS. It never joins a swarm — the peer-to-peer half of a
torrent is your debrid service's job, and Fetch only ever talks to one host at a
time over HTTPS.

Developers: see [`DEVELOPERS.md`](DEVELOPERS.md) for building, testing and how
the thing works inside.

---

## What you need

| | |
|---|---|
| **macOS 26 or later** | Required. Fetch does not run on anything older. |
| **A debrid account** | TorBox, Real-Debrid or Premiumize. Needed for torrents and file-host links. See [what each one can do](#debrid-services). |
| **A Torznab indexer** | Jackett or Prowlarr, self-hosted. Needed for torrent *search*. See [indexer servers](#indexer-servers). |

None of the last two are needed to start. Internet Archive and Project Gutenberg
search and download with no account, no key and no debrid — if that is all you
want, install Fetch and start typing.

---

## Installing

### Opening a downloaded build the first time

Fetch is signed ad-hoc, which means it has no Apple Developer certificate behind
it. macOS blocks apps like that on first launch.

**Right-click → Open does not work.** On current macOS that route is gone for
unsigned apps; the app either does nothing or reports itself as damaged, with no
useful explanation either way. Do this instead:

1. Move `Fetch.app` to `/Applications` (or anywhere you like).
2. Double-click it once. macOS refuses it. Dismiss the dialog.
3. Open **System Settings → Privacy & Security**.
4. Scroll down to **Security**. There is a line saying *"Fetch" was blocked to
   protect your Mac*.
5. Click **Open Anyway**, authenticate, and confirm **Open** in the dialog that
   follows.

You only do this once. Fetch opens normally from then on.

If you would rather do it in one line, this removes the quarantine flag macOS
attaches to anything downloaded from a browser:

```bash
xattr -dr com.apple.quarantine /Applications/Fetch.app
```

### Building it yourself

If you have Xcode 26, building from source skips the whole question — a locally
built app is not quarantined. See [`DEVELOPERS.md`](DEVELOPERS.md).

---

## Setting up

Settings is the third item in the sidebar, or ⌘,. There are seven panes across
the top; the two that matter on day one are **Debrid** and **Search**.

### 1. Add a debrid service

**Settings → Debrid → Add…** and pick your service. In the sheet:

- **Get my API key** opens that service's token page directly, because the key
  is buried several clicks into every one of them.
- Paste the key, press **Test Connection**. It reports your plan and expiry if
  the key works, and the reason if it does not.
- **Save**.

You can add all three. The **order of the rows is the preference order** — drag
to reorder. A download goes to whichever configured service already holds it;
ties go to the row nearest the top. The toggle beside each one disables a
service without deleting its key.

The dot before each name is honest about what it knows: green means that service
answered a real request, grey means nothing has asked it yet, red means it
failed. Nothing is drawn green on the strength of a saved key alone.

> **Real-Debrid cannot report cache status.** Its availability endpoint is
> disabled at the service's end. Real-Debrid downloads work normally; you just
> will not see cached/not-cached badges from it, and Fetch says "unknown" rather
> than claiming "not cached".

#### Debrid services

Three are supported. They are not interchangeable — what a service will tell you
*before* you commit to a download differs, and that is most of what Fetch's
result list is made of.

| | TorBox | Premiumize | Real-Debrid |
|---|:---:|:---:|:---:|
| Torrents and magnets | ✅ | ✅ | ✅ |
| File-host (web) links | ✅ | ✅ | ✅ |
| **Cached / not-cached badges** | ✅ | ✅ | ❌ |
| **File picker before downloading** | ✅ | ✅ | ❌ |
| Hosted link resolves | after a queue | immediately | immediately |

**Cache badges** need a side-effect-free "do you already hold this hash?" call.
Real-Debrid disabled `instantAvailability` at their end, and the only remaining
way to ask is to add the torrent to your account — which Fetch will not do to
answer a question. So Real-Debrid rows read **unknown**, never "not cached".

**The file picker** needs the same thing: a file list without adding the
torrent. Real-Debrid file ids only exist after `addMagnet`, so every Real-Debrid
result routes to **Prepare** instead of opening a picker. Nothing is lost except
the choice of which files to take.

You can configure all three. Row order is preference order, and a download goes
to whichever configured service already holds it.

##### Not supported

AllDebrid, Debrid-Link, Offcloud, put.io, Seedr and the rest have no provider in
Fetch. This is not a judgement about them — each service needs its own
implementation of cache checking, file listing, link unrestricting and host
coverage, and only three have been written. A `DebridProvider` is a public
extension point (see [`DEVELOPERS.md`](DEVELOPERS.md)), so adding one is a
contained job rather than a change to how downloading works.

There is also **no direct BitTorrent**. Fetch never joins a swarm — it talks to
one HTTPS host at a time and the peer-to-peer half is the debrid's job. Without
a debrid account, torrent results can be searched and inspected but not
downloaded; Internet Archive and Project Gutenberg still work in full.

### 2. Add an indexer server

**Settings → Search → Add Server…**

- **Display Name** — anything, e.g. `Prowlarr`.
- **Server URL** — whatever is in your browser's address bar, e.g.
  `http://10.0.0.181:9696` or `http://10.0.0.181:9117`. You do not need to find
  the Torznab API path; Fetch probes for the endpoint that actually answers and
  saves that.
- **API Key** — your Jackett or Prowlarr key.
- **Test**, then **Add**.

#### Indexer servers

Both are supported, and both are stored the same way: **one row per server**,
with its indexers inside. Open a server with the pencil and you get the list,
each indexer with its own toggle and its measured response time.

| | Jackett | Prowlarr |
|---|:---:|:---:|
| Discovered as individual indexers | ✅ | ✅ |
| How | `t=indexers` on the Torznab API | `/api/v1/indexer` |
| Needs anything beyond the API key | no | no |
| Per-indexer categories shown (ⓘ) | ✅ | — |
| Reserve an indexer for chosen pills | ✅ | ✅ |
| Per-indexer response times | ✅ | ✅ |

**Jackett used to be one row called "Jackett".** Its aggregate endpoint
(`/indexers/all/…`) answers every query with every tracker's results in one
feed, so the whole server looked like a single indexer — one entry in "3 of 7
indexers", one thing to switch off, one thing to reserve. It now asks
`t=indexers` and lists them individually. Beyond the obvious, this matters
because the aggregate cannot answer before its slowest member does: on a real
install one tracker stalled until Jackett's own 100-second timeout fired, and
every other tracker's results — which had arrived in between 72ms and 27s —
waited behind it. Asked separately, that one fails on its own.

An existing Jackett server upgrades itself: **open it with the pencil** and the
roster refreshes on its own. The old one-row entry is retired rather than
flagged, because it was superseded by its own parts.

Prowlarr has no aggregate — its `/all/api` redirects to a login page and indexer
`0` is a dummy that returns a convincing fake release for every query — so it has
been discovered per indexer from the start.

#### Reserving an indexer for particular areas

Every indexer row has a menu that reads **Every area**. Narrow it and that
indexer stops being asked — and waited for — outside those pills. An anime
tracker has no answer for a Software query, and a public-domain book site has
none for Movies; both still cost you the wait before this existed.

The **ⓘ** beside an indexer's name shows what it says it carries, which is the
information you need to answer the question the menu asks. It comes from the
indexer's own Torznab capabilities, not from a guess about its name.

**All still asks every indexer.** That pill sends no categories, so there is no
area to match against, and a tracker reserved for Books still has the books you
want when searching everything. Switching an indexer off is what removes it from
every search.

**Test All Indexers** times a real query against every one, so a slow indexer is
visible before it holds up a search.

### 3. Check the free sources

**Settings → Sources.** Internet Archive and Project Gutenberg are on by default
and need nothing. Also here:

- **Safe search** (on by default) drops results the indexer files under
  Torznab's XXX categories. It matches on declared categories only — nothing is
  hidden for its title, because a word blocklist hides legitimate releases
  invisibly.
- **Follow this Mac's languages** for Gutenberg, and whether to include its
  cover art and metadata files (neither of which is the book).

### 4. Optional, but worth five minutes

- **Settings → Organization** — where downloads land, the routing rules that
  subdivide that folder, and template renaming. The preview at the bottom shows
  three real cases, including one weak parse that deliberately keeps its
  original filename.
- **Settings → Quality** — per-kind preference: resolution, source and codec for
  video; codec and lossless for audio; format order for books. The live preview
  re-ranks your current search results, so you can see what a change does to
  releases you recognise.
- **Settings → Transfers** — connections per file, files at once, and whether
  closing the window keeps downloads running.
- **Settings → Appearance** — three themes, and the keyboard shortcut that opens
  Fetch from any app.

---

## Using it

### Search

Type. The search runs when you stop typing, and Return runs it immediately.
Pressing Return again while one is running replaces it rather than queueing
behind it.

- Results **stream in per indexer**. The field shows a count and *"3 of 5
  indexers"* while it waits.
- **✕ next to the progress bar stops waiting.** Everything that already arrived
  stays. Useful when one indexer is unreachable and holding up the rest.
- **Category pills** (All, Movies, TV, Anime, Music, Books, …) *re-run the
  search* scoped to that category. They are not a filter drawn over results
  already on screen.
- **Filters** (the button at the right of the pill row) opens a panel over the
  window: the facets for the current results, and **cached only**. Escape or a
  click anywhere else closes it.
- **Scroll to the bottom for more.** A page that adds nothing new ends the
  scroll; no source reliably says "that was the last one".
- If your quality profile rejected anything, a line under the list says how many
  and offers to show them — a profile that is too strict should be discoverable,
  not mystifying.

**Opening a result** (double-click, or Return on the selected row) opens the
right sheet for what it is:

| Result | Sheet |
|---|---|
| Torrent | File picker — the torrent's tree, with sensible files pre-ticked |
| Internet Archive item | The item's files, with generated derivatives shown or hidden per your setting |
| Gutenberg book | The book's formats, in your preferred order |
| A single direct file | No sheet. It queues. |

**Pasting into the search field:**

- A **magnet** stays in the field and offers itself on a row underneath, with its
  name and a short hash so a mis-paste is visible before it costs anything.
  Click **Open** (or press Return) to get the same sheet everything else opens.
- An **http(s) link** goes straight to the Add Link sheet, which works out
  whether one of your debrid services covers that host.

### Downloads

**One list, newest first.** Preparing, downloading, queued, paused, failed,
cancelled, missing and completed all sit in it together, told apart by the glyph
at the head of the row. Hover a glyph for the word.

- **All / Failed / Library** narrow the list. None of them re-sorts it. Library
  is your finished downloads, and it grows a second row of pills for the kinds
  actually present.
- **Click a row to expand it.** You get its files: each with its own state,
  size, pause/resume, and a right-click menu (Show in Finder, Download Again,
  Revert Rename where there is a rename to undo).
- **Files that were skipped** appear greyed at the bottom of the expanded row.
  Tick them and press Download, or right-click for *Download All Skipped Files*.
  A retry is always a new row rather than a mutation of the old one.
- **Right-click the torrent row** for Show in Finder.
- **Clear** appears only under **Failed**. It removes rows. **Files stay on
  disk.**

**A "Preparing" row** means your debrid is still fetching that torrent into its
own cloud — no bytes have reached your Mac yet. The percentage and the status
line are the service's own words (*"Stalled — waiting for seeds"* is worth
reading). Cancelling it stops Fetch watching; the torrent stays on your account.

**Getting things in:**

- **⌘N** or **Add Link** — a magnet, a hoster URL, or **Choose .torrent…**
- **Drag** a `.torrent` file or a magnet link onto the window. Anywhere on the
  window, on any screen.
- Anything not already on one of your services asks before it queues: fetching
  an uncached torrent spends a slot on your account on an open-ended wait, so
  the button says **Queue…** and confirms.

`.torrent` files are read locally. No peer is contacted and no announce is made
— only the infohash goes out, over HTTPS, to the services you configured.

---

## Keyboard and the menu bar

| | |
|---|---|
| ⌘N | Add Link |
| ⌘, | Settings |
| Return | Run the search / open the selected result |
| Escape | Close the filters panel |
| ⌘Q | Quit |
| *your choice* | Open Fetch from any app with the search field focused and empty — set it in Settings → Appearance |

Fetch keeps a menu bar item with a ring that fills as downloads progress, so an
app still working with its window closed is still visible. Click it for the
count, *Open Fetch*, and *Quit*.

Closing the window does not stop downloads if **Settings → Transfers → Keep
downloading** is on. Quit from the menu bar to actually stop.

---

## Where Fetch keeps things

| | |
|---|---|
| Downloads | `~/Downloads/Fetch` by default. Change it in Settings → Organization. |
| Download history | `~/Library/Application Support/Fetch/downloads.store` |
| API keys | `~/Library/Application Support/Fetch/*.secret`, permissions `0600` |
| Log | `~/Library/Logs/Fetch/fetch.log` |
| Preferences | `defaults` domain `dev.fetch.Fetch` |

The log is **safe to send to someone**: filenames, paths and links are replaced
before anything is written. **Settings → Debrid → Diagnostics** has Reveal and
Copy buttons for it.

Keys are in a permission-protected file rather than the Keychain, deliberately.
An ad-hoc signature changes on every build, so macOS treats each build as a
different app and re-prompts for Keychain access every launch — unusable. The
tradeoff: the file is readable by anything running as your user.

---

## Things worth knowing before they surprise you

**Notifications do not work.** They are written and wired, and macOS refuses
them: it will not grant notification authorisation to an app with no stable
signing identity. Fetch never appears in Notification Centre's settings, so
there is nothing to switch on. A real signing certificate is the only fix.

**One connection per file is the default, and it is probably right.** Measured
against a TorBox CDN and archive.org on a ~90 Mbps line:

| Connections per file | TorBox CDN | archive.org |
|---|---|---|
| **1** | **9.2 MB/s** | **9.2 MB/s** |
| 4 | 8.9 MB/s | — |
| 8 | 8.1 MB/s | 7.8 MB/s |
| 16 | 8.7 MB/s | 8.7 MB/s |

Splitting cost up to 37%. One stream already saturates a line that slow — on a
much faster connection raising it should win, which is why the setting exists.
Change it and watch the speed rather than trusting either default.

**Total speed is your line, not Fetch.** Three different debrid links in
parallel could not exceed ~11.7 MB/s combined on the same connection, where one
link alone got 9.2.

**An Internet Archive item offering several formats pre-ticks all of them.** A
plain-text book can be under a megabyte, so there is no size floor on documents
— which means an item offering EPUB, PDF and plain text arrives with three
copies of one book ticked. Untick what you do not want before downloading. This
is a known consequence of a deliberate choice, not a bug.

**Fetch never joins a swarm.** Torrent metadata comes from an HTTPS fetch with
mandatory infohash verification. There is no DHT and no peer connection, ever,
because connecting to peers announces your IP address to everyone in the swarm.

---

## When something goes wrong

**The app will not open.** See [Installing](#opening-a-downloaded-build-the-first-time)
— it is the Privacy & Security route, not right-click → Open.

**"No indexers configured".** Settings → Search → Add Server. Internet Archive
and Gutenberg still search without one.

**"All indexers failed".** The message carries the reason. Check the server is
reachable from this Mac and that the key is right — Settings → Search → the
pencil → **Test Connection**.

**One indexer hangs every search.** Press ✕ in the search field to stop waiting.
Then, in its server's edit sheet — where its measured latency is listed — either
turn it off, or **reserve it for the areas it is actually good for** so it stops
being asked for everything else. **Give up after** on the same pane is how long
any one indexer may take before Fetch stops waiting for it.

**An indexer never reports.** A search now closes anyone who did not answer as
having never answered, so they appear in the failure banner instead of leaving
the progress bar one short.

**No cached/not-cached badges.** Real-Debrid cannot report cache status; that is
the service, not Fetch. TorBox and Premiumize can.

**A row says Missing.** The file was moved or deleted after it finished.
Restoring it from the Trash puts the row back to Completed; otherwise
right-click → **Download Again**.

**Several downloads failed at once.** The row carries the reason now. If it
repeats, lower **Connections per file** and **Files at once** in Settings →
Transfers — a debrid CDN produces rate limits and expired links when a lot of
requests hit it at once. The log has the detail.

**A file landed with the wrong name.** Renaming is off by default and only fires
on a confident parse. Right-click the file → **Revert Rename**.

**Downloads are in the wrong folders.** Settings → Organization. Rules are
first-match-wins; drag to reorder. Anything unmatched goes to the fallback
folder.

---

## Licence

MIT. See [`LICENSE`](LICENSE).

[What is not built yet, and why](BACKLOG.md) ·
[The site](https://nikeplusdash.github.io/Fetch/)
