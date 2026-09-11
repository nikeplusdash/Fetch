# Privacy

Two separate things carry this name: **the app**, which runs on your Mac, and
**the website**, which is a page about the app. They share no data, and the
answers are different. The app is the one holding your API keys.

---

## The app

**Fetch has no backend.** There is no Fetch account, no Fetch server, and no
analytics, telemetry or crash reporting of any kind compiled into it. Nothing
about your searches, your downloads or your library is sent to me, ever. There
is nothing to opt out of because there is nothing collecting.

### Where your API keys are kept

In files under `~/Library/Application Support/Fetch/`, one per credential, named
`<layer>_<provider>.secret`. The directory is `0700` and each file is `0600` —
readable by your user account and nothing else.

**Not the Keychain, and it is worth knowing why.** Fetch is signed ad-hoc, and
an ad-hoc signature changes on every build, so macOS treats each build as a
different app and re-prompts for Keychain access every launch. The Keychain
implementation was removed rather than left as a broken second option.

**The tradeoff, stated plainly:** this is weaker than the Keychain. The file is
readable by anything running as your user, and it is not encrypted at rest
beyond whatever FileVault gives you. For a local-first app holding a debrid API
key that is a reasonable trade; it is not the right store for a secret that
matters more than that.

### Where your API keys go

Only to the service the key belongs to, over HTTPS, and nowhere else:

| Key | Goes to | How |
|---|---|---|
| Debrid (TorBox, Real-Debrid, Premiumize) | `api.torbox.app`, `api.real-debrid.com`, `www.premiumize.me` | `Authorization: Bearer` header. TorBox's `requestdl` endpoint is the exception — it authenticates with a `token` query parameter, because that is what the API requires. |
| Torznab (Jackett, Prowlarr) | Whatever host you configured — your own machine or your own server | `apikey` query parameter, which is the Torznab protocol. |

Internet Archive, Project Gutenberg and Gutendex need no key and are given
none. No key is ever sent to a host it does not belong to, and no key is sent
anywhere as part of a download — downloads go to the link your debrid handed
back, over plain HTTPS, to one host at a time. Fetch never joins a swarm.

### Keys in memory, and in logs

Secrets are wrapped in a `Redacted` type whose description, debug description
and mirror all render `<redacted>`, so interpolating one into a string, logging
it or `dump()`-ing a struct containing it cannot print it. Reading the real
value requires naming `.exposedValue`, which is greppable in review.

Fetch's own log lines are redacted before they are written, on the assumption
that a log is something you will be asked to paste into an issue:

- Anything keyword-adjacent to a credential (`apikey`, `token`,
  `authorization`, `password`, `secret`) is scrubbed to `«redacted»`.
- URLs are reduced to their host. A debrid download link carries your account's
  token in its path or query, so the rest of it never reaches the log.
- Filenames become a short stable one-way hash — the same file reads as the
  same token across lines, and the name cannot be recovered from it.
- Paths become their depth and extension, not your folder names.

### Removing them

Delete a provider's credential in Settings, or delete the matching `.secret`
file. Deleting a key removes it from this machine; revoking it is done at the
service that issued it, and if a key has been exposed that is the step that
matters.

---

## The website

<https://fetch.madebynikesh.com> is a single static page. It runs **Microsoft
Clarity** (project `y2fggrs1g6`) so I can see which parts of the page people
actually read.

**Everything on the page is masked at the source.** The page sets
`data-clarity-mask="true"` on its root, and masked content is never uploaded —
so a session recording of this site is a wireframe of clicks and scrolls with
no text or images in it. Clarity offers no way to keep the metrics and skip the
recording; the heatmaps are derived from the recording, so masking is the whole
of the mitigation. The page has no forms, no login and no input of any kind, so
there is nothing on it that could be typed and captured.

Clarity receives your IP address (used for coarse location and then not stored
by me), your browser and device type, referring URL, and which elements you
clicked or scrolled past. It sets first-party cookies (`_clck`, `_clsk`) and
third-party Microsoft cookies (`MUID`, `CLID`, `SM`, `MR`, `ANONCHK`), some of
which Microsoft uses for advertising across its own domains. What it does with
that is governed by the [Microsoft Privacy
Statement](https://privacy.microsoft.com/privacystatement), not by me.

Blocking `clarity.ms` in an extension, or turning off cookies, removes all of
this and costs the page nothing — the tag loads async and is the only request
that leaves the page. Everything else, fonts and images included, is inlined in
the one file.

**None of this touches the app.** The website does not know you use Fetch, and
Fetch does not load the website.

---

*Questions, or something here that does not match what you observe:
[open an issue](https://github.com/nikeplusdash/Fetch/issues).*
