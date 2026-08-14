import Foundation
@testable import FetchKit

/// An in-memory `CredentialStore` so credential-handling logic can be tested
/// without touching the filesystem or the user's real secrets.
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    /// Every account written, in order — lets a test assert that a migration
    /// wrote once rather than N times.
    private(set) var writes: [String] = []

    init(_ initial: [CredentialAccount: String] = [:]) {
        for (account, secret) in initial { storage[account.key] = secret }
    }

    func store(_ secret: String, for account: CredentialAccount) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account.key] = secret
        writes.append(account.key)
    }

    func read(for account: CredentialAccount) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account.key]
    }

    func delete(for account: CredentialAccount) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account.key] = nil
    }

    var accountKeys: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(storage.keys)
    }
}
