import Testing
import Foundation
@testable import FetchKit

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

    @Test func accountsDifferingOnlyByLayerDoNotShareAFile() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.store("debrid-key", for: CredentialAccount(layer: "debrid", providerID: "x"))
        try store.store("search-key", for: CredentialAccount(layer: "search", providerID: "x"))

        #expect(try store.read(for: CredentialAccount(layer: "debrid", providerID: "x")) == "debrid-key")
        #expect(try store.read(for: CredentialAccount(layer: "search", providerID: "x")) == "search-key")
    }

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

@Suite struct UnreferencedCredentialTests {
    private func makeStore() -> (FileCredentialStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fetch-unref-\(UUID().uuidString)", isDirectory: true)
        return (FileCredentialStore(directory: directory), directory)
    }

    private func account(_ provider: String) -> CredentialAccount {
        CredentialAccount(layer: "search", providerID: provider)
    }

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

    @Test func anIDThatSanitizesOntoALiveOneIsKept() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = account("http://box:9696")
        try store.store("k", for: live)

        #expect(store.countSecrets(inLayer: "search", keeping: [account("http_//box_9696")]) == 0)
    }
}
