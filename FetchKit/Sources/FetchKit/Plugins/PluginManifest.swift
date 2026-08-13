import Foundation
import FetchPluginAPI

public enum PluginError: Error, LocalizedError, Equatable {
    case malformed(String)
    case unsupportedAPIVersion(found: Int, supported: Int)
    case unknownKind(String)
    case missingField(String)
    case idMismatch(declared: String, folder: String)
    case duplicateID(String)
    /// A field that is present and well-typed but cannot be acted on (§3 rule
    /// 5 for Tier 1: nothing executes, so misbehaving means a bad value).
    case badValue(String, String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let detail):
            "The manifest could not be read: \(detail)"
        case .unsupportedAPIVersion(let found, let supported):
            "Built for plugin API \(found); this version of Fetch supports \(supported)."
        case .unknownKind(let kind):
            "Unknown extension kind \"\(kind)\"."
        case .missingField(let field):
            "Missing required field \"\(field)\"."
        case .idMismatch(let declared, let folder):
            "The manifest declares id \"\(declared)\" but sits in a folder named \"\(folder)\"."
        case .duplicateID(let id):
            "Another plugin already claims the id \"\(id)\"."
        case .badValue(let field, let why):
            "The field \"\(field)\" \(why)."
        }
    }
}

/// A Tier-1 plugin: a directory of JSON, no code (§3).
///
/// Declarative by design — this covers naming templates, routing rules,
/// quality profiles, parser token tables and indexer definitions, none of
/// which need to execute anything.
public struct PluginManifest: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let apiVersion: Int
    public let kind: ExtensionKind

    /// Hosts this plugin may reach. **Absent means none**, not unrestricted:
    /// a default-open permission model would make declaring hosts pointless
    /// (§3 rule 4).
    public let allowedHosts: [String]?

    // Kind-specific payload. Which fields are required is validated per kind,
    // so a manifest cannot declare a kind and then supply nothing to act on.
    public let match: RoutingRule.Match?
    public let template: String?
    public let subfolder: String?
    public let baseURL: URL?

    /// Decodes and validates. Every failure is a `PluginError` carrying
    /// something the user can act on, because these are files they wrote.
    public static func decode(_ data: Data) throws -> PluginManifest {
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch let error as DecodingError {
            // An unrecognized `kind` surfaces as a decoding failure on the
            // enum; report it as the specific problem it is.
            if case .dataCorrupted(let context) = error,
               context.codingPath.contains(where: { $0.stringValue == "kind" }) {
                throw PluginError.unknownKind(rawKind(in: data) ?? "?")
            }
            throw PluginError.malformed(error.localizedDescription)
        } catch {
            throw PluginError.malformed(error.localizedDescription)
        }

        guard manifest.apiVersion == currentAPIVersion else {
            throw PluginError.unsupportedAPIVersion(
                found: manifest.apiVersion, supported: currentAPIVersion)
        }
        guard !manifest.id.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PluginError.missingField("id")
        }
        guard !manifest.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PluginError.missingField("name")
        }

        switch manifest.kind {
        case .namingStrategy:
            guard let template = manifest.template, !template.isEmpty else {
                throw PluginError.missingField("template")
            }
            // A template with no tokens renders one constant path for every
            // release, so a whole season would overwrite itself into a single
            // file. That is a bad value, not a preference.
            guard template.contains("{") else {
                throw PluginError.badValue(
                    "template", "contains no {Token}, so every file would be named the same")
            }
        case .routingRule:
            guard let subfolder = manifest.subfolder, !subfolder.isEmpty else {
                throw PluginError.missingField("subfolder")
            }
            // The one place a declarative plugin can still reach outside its
            // box: a subfolder of `../..` files downloads somewhere the user
            // never chose. Caught at load, not while a download is finishing.
            guard !subfolder.hasPrefix("/"),
                  !subfolder.split(separator: "/").contains("..")
            else {
                throw PluginError.badValue(
                    "subfolder", "must stay inside the download directory")
            }
        case .searchProvider:
            // Declared in the manifest schema and validated, but nothing
            // consumes it yet: a Torznab endpoint needs an API key the user
            // supplies, so an indexer plugin is a *preset* for the Add
            // Indexer sheet rather than a working source on its own.
            //
            // Refused rather than accepted-and-ignored. Loading one would put
            // a row in Settings § Plugins saying it may reach a host, next to
            // rows that genuinely do something — which reads as working.
            throw PluginError.badValue(
                "kind", "is not supported yet — indexer plugins are still to come")
        default:
            // Other kinds are Tier 2 (§3) and cannot be expressed
            // declaratively; loading one is a manifest error, not silence.
            throw PluginError.unknownKind(manifest.kind.rawValue)
        }
        return manifest
    }

    private static func rawKind(in data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["kind"] as? String
    }

    /// Whether this plugin may reach `host`.
    ///
    /// Exact match only — a declared `example.com` must not silently authorise
    /// `evil.example.com`, which is the standard way an allowlist becomes
    /// decorative.
    public func permits(host: String) -> Bool {
        (allowedHosts ?? []).contains {
            $0.caseInsensitiveCompare(host) == .orderedSame
        }
    }
}

/// Loads a directory of Tier-1 plugins.
public enum PluginLoader {
    public struct Failure: Sendable, Equatable, Identifiable {
        public let pluginID: String
        public let reason: String
        public var id: String { pluginID }
    }

    public struct Outcome: Sendable {
        public let loaded: [PluginManifest]
        public let failures: [Failure]
    }

    public static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fetch/Plugins", isDirectory: true)
    }

    /// Reads every `<id>/manifest.json` under `root`.
    ///
    /// **Failures are per plugin.** §15's acceptance criterion is that a
    /// malformed manifest disables that plugin alone — one bad file must not
    /// cost the user their working ones, so nothing here throws.
    public static func load(from root: URL) -> Outcome {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        var loaded: [PluginManifest] = []
        var failures: [Failure] = []
        var claimed: Set<String> = []

        for directory in directories.sorted(by: { $0.path < $1.path }) {
            let folder = directory.lastPathComponent
            let manifestURL = directory.appendingPathComponent("manifest.json")

            // An empty folder is not a broken plugin. Reporting it would train
            // the user to ignore the banner that matters.
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }

            do {
                let manifest = try PluginManifest.decode(try Data(contentsOf: manifestURL))

                // The folder name is how a user identifies a plugin to remove
                // it; a manifest that disagrees would be unremovable by name.
                guard manifest.id == folder else {
                    throw PluginError.idMismatch(declared: manifest.id, folder: folder)
                }
                guard claimed.insert(manifest.id).inserted else {
                    throw PluginError.duplicateID(manifest.id)
                }
                loaded.append(manifest)
            } catch {
                failures.append(Failure(
                    pluginID: folder,
                    reason: (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription))
            }
        }
        return Outcome(loaded: loaded, failures: failures)
    }
}
