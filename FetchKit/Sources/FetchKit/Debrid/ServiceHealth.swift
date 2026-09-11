import Foundation

/**
 Whether a debrid service actually answered when asked who we are.

 **Host coverage was standing in for this and answering a different
 question.** The status dot and the rail both read `hostCoverage`, which is
 the list of file hosts a service can unrestrict — so a service whose key had
 been revoked could still show green off a list fetched before it was, and a
 perfectly healthy service that simply offers no web downloads reports an
 empty list and looked no different from one that had failed. Neither state
 has anything to do with whether the credentials work.

 `validateCredentials()` is the question worth asking, because it is the one
 every other call depends on.
 */
public enum ServiceHealth: Equatable, Sendable {
    case unknown
    case checking
    case ok(plan: String?)
    case failed(reason: String)

    public var isOK: Bool {
        if case .ok = self { return true }
        return false
    }

    public var hasAnswered: Bool {
        switch self {
        case .ok, .failed: true
        case .unknown, .checking: false
        }
    }

    /**
     What the row's dot shows. Three states, not two: "not yet asked" is not
     a failure, and drawing it as one makes every launch look broken for as
     long as the network takes.
     */
    public enum Dot: Equatable, Sendable { case up, down, waiting, off }

    public func dot(isEnabled: Bool) -> Dot {
        guard isEnabled else { return .off }
        switch self {
        case .ok: return .up
        case .failed: return .down
        case .unknown, .checking: return .waiting
        }
    }

    public var failureText: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}
