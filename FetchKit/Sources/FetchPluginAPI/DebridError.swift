import Foundation

/**
 What a `DebridProvider` throws.

 Lives beside the protocol rather than in `FetchKit`, for the reason 7a
 moved `InfoHash` and `MagnetLink` down: the DTO boundary needs it. A
 plugin conforming to `DebridProvider` has to be able to throw these, and
 the protocol's own default implementations throw `unsupportedOperation`.
 */
public enum DebridError: Error, Sendable, Equatable {
    case unauthorized
    case providerRejected(detail: String)
    case torrentFailed(state: String)
    case fileNotFound
    case linkExpired
    case network(String)
    case unsupportedOperation
}

extension DebridError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "The debrid service rejected the API key. Check it in Settings."
        case .providerRejected(let detail):
            "The debrid service refused the request: \(detail)."
        case .torrentFailed(let state):
            "The debrid service could not fetch this torrent (\(state))."
        case .fileNotFound:
            "The debrid service no longer has this file."
        case .linkExpired:
            "The debrid link expired."
        case .network(let detail):
            "Could not reach the debrid service: \(detail)."
        case .unsupportedOperation:
            "This debrid service does not support that operation."
        }
    }
}
