import Testing
import Foundation
@testable import FetchKit

/// Ported from the deleted `KeychainStoreTests` when the Keychain
/// implementation was removed. `FileCredentialStore` had no tests of its own
/// despite being the store the app actually runs on — which is part of why a
/// credential it silently failed to carry over went unnoticed.
///
/// Every case uses a temp directory, so nothing here touches the real
/// `~/Library/Application Support/Fetch`.
@Suite struct FileCredentialStoreTests {
    private func makeStore() -> (store: FileCredentialStore, directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fetch-tests-\(UUID().uuidString)", isDirectory: true)
        return (FileCredentialStore(directory: directory), directory)
    }

    @Test func storesAndReadsBack() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = CredentialAccount(layer: "debrid", providerID: "torbox")
        try store.store("secret-value", for: account)
        #expect(try store.read(for: account) == "secret-value")
    }

    @Test func readingMissingAccountReturnsNil() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try store.read(for: CredentialAccount(layer: "debrid", providerID: "absent")) == nil)
    }

    @Test func storingTwiceOverwrites() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = CredentialAccount(layer: "debrid", providerID: "torbox")
        try store.store("first", for: account)
        try store.store("second", for: account)
        #expect(try store.read(for: account) == "second")
    }

    @Test func deleteRemovesItem() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = CredentialAccount(layer: "search", providerID: "jackett")
        try store.store("value", for: account)
        try store.delete(for: account)
        #expect(try store.read(for: account) == nil)
    }

    @Test func deletingMissingItemDoesNotThrow() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.delete(for: CredentialAccount(layer: "debrid", providerID: "ghost"))
    }

    /// `CredentialAccount.key` joins on a unit separator, which is not
    /// filename-safe, so the store sanitizes it. Two accounts that differ
    /// only either side of that separator must not collide on disk.
    @Test func accountsDifferingOnlyByLayerDoNotShareAFile() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.store("debrid-key", for: CredentialAccount(layer: "debrid", providerID: "x"))
        try store.store("search-key", for: CredentialAccount(layer: "search", providerID: "x"))

        #expect(try store.read(for: CredentialAccount(layer: "debrid", providerID: "x")) == "debrid-key")
        #expect(try store.read(for: CredentialAccount(layer: "search", providerID: "x")) == "search-key")
    }

    /// The secret is a bearer token; the file must not be group- or
    /// world-readable.
    @Test func theSecretFileIsOwnerReadableOnly() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = CredentialAccount(layer: "debrid", providerID: "torbox")
        try store.store("secret-value", for: account)

        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        let secret = try #require(files.first { $0.pathExtension == "secret" })
        let permissions = try FileManager.default
            .attributesOfItem(atPath: secret.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.int16Value == 0o600)
    }
}

/// Finding credentials no config refers to any more.
///
/// **The bug these exist for.** The first attempt reversed the filename
/// sanitizer to recover an account, but that sanitizer is lossy — `:` and `/`
/// both become `_` — so a server id like `http://10.0.0.181:9117` never
/// round-tripped, its live key looked orphaned, and Settings offered to delete
/// the credential that made search work. Comparison happens in the sanitized
/// space instead, where it is exact.
@Suite struct UnreferencedCredentialTests {
    private func makeStore() -> (FileCredentialStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fetch-unref-\(UUID().uuidString)", isDirectory: true)
        return (FileCredentialStore(directory: directory), directory)
    }

    private func account(_ provider: String) -> CredentialAccount {
        CredentialAccount(layer: "search", providerID: provider)
    }

    /// The exact shape migration produces: an id that is a URL, not a UUID.
    @Test func aURLShapedProviderIDIsRecognizedAsLive() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = account("http://10.0.0.181:9117")
        try store.store("live-key", for: live)
        try store.store("stale-key", for: account("11111111-2222-3333-4444-555555555555"))

        #expect(store.countSecrets(inLayer: "search", keeping: [live]) == 1)
    }

    @Test func removingUnreferencedKeepsTheLiveOnes() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let liveA = account("http://10.0.0.181:9117")
        let liveB = account("http://10.0.0.181:9696")
        try store.store("a", for: liveA)
        try store.store("b", for: liveB)
        for i in 0..<7 {
            try store.store("stale", for: account("legacy-\(i)"))
        }

        let removed = try store.removeSecrets(inLayer: "search", keeping: [liveA, liveB])

        #expect(removed == 7)
        #expect(try store.read(for: liveA) == "a")
        #expect(try store.read(for: liveB) == "b")
    }

    /// Layers must not bleed: cleaning up search keys cannot touch the debrid
    /// key, which is what the whole app runs on.
    @Test func anotherLayersSecretsAreNeverTouched() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let debrid = CredentialAccount(layer: "debrid", providerID: "torbox")
        try store.store("torbox-key", for: debrid)
        try store.store("stale", for: account("legacy-1"))

        let removed = try store.removeSecrets(inLayer: "search", keeping: [])

        #expect(removed == 1)
        #expect(try store.read(for: debrid) == "torbox-key")
    }

    @Test func nothingUnreferencedRemovesNothing() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = account("http://box:9696")
        try store.store("k", for: live)

        #expect(store.countSecrets(inLayer: "search", keeping: [live]) == 0)
        #expect(try store.removeSecrets(inLayer: "search", keeping: [live]) == 0)
        #expect(try store.read(for: live) == "k")
    }

    /// Two ids that sanitize to the same filename would collide in the store
    /// itself, so treating a collision as "live" is the safe reading — better
    /// to keep a stale key than delete a working one.
    @Test func anIDThatSanitizesOntoALiveOneIsKept() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = account("http://box:9696")
        try store.store("k", for: live)

        #expect(store.countSecrets(inLayer: "search", keeping: [account("http_//box_9696")]) == 0)
    }
}
