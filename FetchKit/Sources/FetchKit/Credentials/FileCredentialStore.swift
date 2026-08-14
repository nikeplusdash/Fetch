import Foundation

/// Stores secrets in a 0600 file under Application Support. The only
/// `CredentialStore` there is.
///
/// **Why this exists.** Fetch is ad-hoc signed, and an ad-hoc signature changes
/// on every rebuild — macOS therefore treats each build as a different app and
/// re-prompts for Keychain access every launch. That is unusable during
/// development, so the Keychain implementation was removed outright rather
/// than kept as a second store nothing selected.
///
/// **The tradeoff, stated plainly.** This is weaker than the Keychain: the file
/// is readable by anything running as this user, and it is not encrypted at
/// rest beyond FileVault. It is protected by POSIX permissions only. For a
/// local-first app holding a debrid API key that is a reasonable trade. A
/// signed release build could justify revisiting it — see the migration
/// warning on `CredentialStore` before adding a second store.
public struct FileCredentialStore: CredentialStore {
    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fetch", isDirectory: true)
    }

    private func url(for account: CredentialAccount) -> URL {
        directory.appendingPathComponent("\(Self.sanitize(account.key)).secret")
    }

    /// Filename-safe form of `CredentialAccount.key`. **Lossy on purpose and
    /// irreversibly so** — the unit separator, `:` and `/` all collapse to
    /// `_` — so never try to recover an account from a filename. Compare
    /// sanitized-to-sanitized instead; see `countSecrets(inLayer:keeping:)`.
    static func sanitize(_ key: String) -> String {
        key.unicodeScalars
            .map { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == ".") ? String($0) : "_" }
            .joined()
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    public func store(_ secret: String, for account: CredentialAccount) throws {
        try ensureDirectory()
        let target = url(for: account)
        try Data(secret.utf8).write(to: target, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    public func read(for account: CredentialAccount) throws -> String? {
        let target = url(for: account)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return String(data: try Data(contentsOf: target), encoding: .utf8)
    }

    public func delete(for account: CredentialAccount) throws {
        let target = url(for: account)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
    }

    /// How many secrets in `layer` belong to no account in `keeping`.
    ///
    /// **Comparison happens on filenames, never on recovered accounts.** An
    /// earlier version reversed the sanitizer to rebuild a `CredentialAccount`
    /// from a filename, but that map is lossy — `:` and `/` both become `_` —
    /// so a server id like `http://10.0.0.181:9117` failed to round-trip, its
    /// live key was classified as orphaned, and Settings offered to delete the
    /// credential that made search work. Sanitizing both sides and comparing
    /// there is exact, and a collision resolves toward *keeping* the file.
    public func countSecrets(inLayer layer: String, keeping: [CredentialAccount]) -> Int {
        unreferencedSecrets(inLayer: layer, keeping: keeping).count
    }

    /// Deletes them, returning how many went. Only `layer` is considered, so
    /// tidying search keys can never touch the debrid key the app runs on.
    @discardableResult
    public func removeSecrets(inLayer layer: String, keeping: [CredentialAccount]) throws -> Int {
        let doomed = unreferencedSecrets(inLayer: layer, keeping: keeping)
        for file in doomed {
            try FileManager.default.removeItem(at: file)
        }
        return doomed.count
    }

    private func unreferencedSecrets(
        inLayer layer: String, keeping: [CredentialAccount]
    ) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        let live = Set(keeping.map { Self.sanitize($0.key) })
        // The sanitized layer prefix, e.g. "search_". Layers are plain
        // lowercase words, so this survives sanitization unchanged.
        let prefix = Self.sanitize(CredentialAccount(layer: layer, providerID: "").key)

        return files.filter { file in
            guard file.pathExtension == "secret" else { return false }
            let stem = file.deletingPathExtension().lastPathComponent
            guard stem.hasPrefix(prefix) else { return false }
            return !live.contains(stem)
        }
    }
}
