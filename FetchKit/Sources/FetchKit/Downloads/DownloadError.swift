import Foundation
import FetchPluginAPI

/// What a transfer can fail with.
///
/// **`LocalizedError`, not for politeness.** A bare Swift error's
/// `localizedDescription` is `"The operation couldn't be completed.
/// (FetchKit.DownloadError error 6.)"`, and that string is what
/// `AppModel.apply(.failed)` put in front of the user for every failed
/// download. It is unactionable, and it is also actively misleading to
/// whoever tries to decode it: **Swift does not number error-enum cases in
/// declaration order.** It numbers every case *with* a payload first, in
/// declaration order, then every case without one. So in the shape this enum
/// had before this file gained `errorDescription`, `error 6` was
/// `.rangeNotSupported` — while counting down the declarations gives
/// `.debrid` and sends the reader into the debrid layer, where nothing was
/// wrong. Verified by bridging each case to `NSError` and reading `.code`.
///
/// Nothing should ever have to do that again: every case says what happened.
public enum DownloadError: Error, Sendable, Equatable {
    /// The server answered a range request with something that is not a
    /// partial response. Carries the status so the reason survives to the
    /// user — a 200 (this link ignores `Range`) and a 403 (this link has
    /// expired) are different conditions and used to be reported as the same
    /// one.
    case rangeNotSupported(status: Int)
    case destinationUnwritable(path: String)
    case diskFull(needed: Int64, available: Int64)
    case sizeMismatch(expected: Int64, actual: Int64)
    case unsafePath(String)
    case linkExpired
    case debrid(DebridError)
    case network(String)
}

extension DownloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .rangeNotSupported(let status):
            "The download server answered HTTP \(status) to a range request "
            + "instead of sending the requested part of the file."
        case .destinationUnwritable(let path):
            "Could not write to \(path). Check the folder still exists and is writable."
        case .diskFull(let needed, let available):
            "Not enough disk space: \(ByteCount.format(needed)) needed, "
            + "\(ByteCount.format(available)) free."
        case .sizeMismatch(let expected, let actual):
            "The downloaded file is \(ByteCount.format(actual)), but "
            + "\(ByteCount.format(expected)) was expected."
        case .unsafePath(let path):
            "“\(path)” is not a safe path to write to, so nothing was downloaded."
        case .linkExpired:
            "The download link expired before the transfer finished. "
            + "Resuming requests a fresh one."
        case .debrid(let error):
            error.errorDescription ?? "The debrid service reported an error."
        case .network(let detail):
            "The transfer failed: \(detail)."
        }
    }
}
