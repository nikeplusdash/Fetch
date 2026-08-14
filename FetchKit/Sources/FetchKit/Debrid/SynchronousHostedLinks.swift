import Foundation
import FetchPluginAPI

/// A debrid whose unrestrict is one synchronous call: submit and fetch are the
/// same request, made twice.
///
/// `DebridProvider`'s web-download members describe TorBox's queue-then-poll
/// shape, which subsumes this one — so the synchronous services opt **in**
/// here rather than the asynchronous one opting out. TorBox does not conform,
/// keeps its own four implementations, and keeps `hostedLinksNeedPreparing ==
/// true`. Nothing about its model is expressed here.
///
/// Real-Debrid and Premiumize differ in exactly one thing: which call resolves
/// a link (`unrestrict/link` vs `transfer/directdl`). That is the requirement;
/// everything else below was written out twice, identically, before this.
protocol SynchronousHostedLinks: DebridProvider {
    /// Real-Debrid: `unrestrict/link`. Premiumize: `transfer/directdl`.
    func resolveHostedLink(_ link: String) async throws -> URL
}

extension SynchronousHostedLinks {
    /// Resolve once to validate, then discard the result.
    ///
    /// An unsupported host has to fail while the user is still looking at the
    /// sheet. Keeping the resolved URL would mean holding a credentialed,
    /// expiring link in memory for the life of a download that re-resolves at
    /// fetch time anyway — which §6 forbids, and which would go stale first.
    public func submitLink(_ url: URL) async throws -> DebridDownloadID {
        _ = try await resolveHostedLink(url.absoluteString)
        return DebridDownloadID(rawValue: url.absoluteString)
    }

    /// Completed on arrival, and makes no request: there is no queue to poll.
    ///
    /// The filename is in the resolve response, which `submitLink`
    /// deliberately discarded. The URL's last component is what is knowable
    /// without a second call, and the transfer learns the real name from
    /// `Content-Disposition` regardless.
    public func webDownload(id: DebridDownloadID) async throws -> DebridWebDownload {
        DebridWebDownload(
            id: id,
            name: URL(string: id.rawValue)?.lastPathComponent ?? "",
            size: nil,
            progress: 1.0,
            state: .completed,
            files: [])
    }

    public func downloadURL(web id: DebridDownloadID) async throws -> URL {
        try await resolveHostedLink(id.rawValue)
    }

    /// No polling: `submitLink` already proved the link resolves, and
    /// `downloadURL` resolves it again at fetch time. Leaving this at
    /// `DebridProvider`'s default `true` would have the engine wait for a
    /// state change that happened before the first poll.
    public var hostedLinksNeedPreparing: Bool { false }
}
