# Backlog

What is not built yet, and why it is not.

## More file hosters, and more debrid services

Fetch speaks to Real-Debrid, TorBox and Premiumize. The provider boundary is a
protocol — `DebridProvider` in `FetchKit/Sources/FetchPluginAPI` — so another
service is a conformance rather than a fork through the app, and direct file
hosters (the one-click kind a debrid unrestricts) fit the same shape.

## Notifications when a download lands

Written and wired, and refused by macOS:

    UNErrorDomain Code=1 "Notifications are not allowed for this application"

`codesign` reports `Signature=adhoc` and `TeamIdentifier=not set`, and macOS
will not grant notification authorisation to a bundle with no stable signing
identity — the app never appears in Notification Centre's settings, so there is
nothing to switch on. **A real signing certificate is the fix; no code change
helps.** The code stays wired, logs the refusal once, and is quiet. The same
certificate is what would let a downloaded build open without right-click →
Open.
