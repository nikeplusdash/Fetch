import Foundation
@testable import FetchKit

final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

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
