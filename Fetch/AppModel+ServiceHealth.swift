import Foundation
import FetchKit
import FetchPluginAPI

/// Asking each debrid service whether its key still works.
///
/// **A question nothing was asking.** The status dot and the rail were both
/// reading `hostCoverage`, which answers "which file hosts can this service
/// unrestrict" — a different question, and one whose answer can be perfectly
/// healthy (an empty list, from a service that offers no web downloads) or
/// perfectly stale (a list fetched before the key was revoked). So an
/// unauthorized service showed green, and a service that had just been given a
/// key stayed amber until Settings was left and re-entered.
extension AppModel {
    /// Ask every enabled service who we are, concurrently.
    ///
    /// Concurrently because they are independent and three round trips in
    /// series is three times as long to look wrong for. Each answer is applied
    /// as it lands rather than all at the end, so a fast service goes green
    /// while a slow one is still spinning.
    func refreshServiceHealth() async {
        let asking = providers
        guard !asking.isEmpty else {
            serviceHealth = [:]
            return
        }

        // Anything no longer configured leaves, or a service removed while its
        // check was in flight would keep its dot for ever.
        serviceHealth = serviceHealth.filter { id, _ in asking.contains { $0.id == id } }
        for provider in asking where serviceHealth[provider.id] == nil {
            serviceHealth[provider.id] = .unknown
        }

        await withTaskGroup(of: (DebridProviderID, ServiceHealth).self) { group in
            for provider in asking {
                serviceHealth[provider.id] = .checking
                group.addTask {
                    do {
                        let account = try await provider.validateCredentials()
                        return (provider.id, .ok(plan: account.plan))
                    } catch {
                        return (provider.id, .failed(reason: Self.reason(for: error)))
                    }
                }
            }
            for await (id, health) in group {
                // Only if it is still one of ours: the user can remove a
                // service while its check is in flight.
                guard providers.contains(where: { $0.id == id }) else { continue }
                serviceHealth[id] = health
            }
        }
    }

    /// How many enabled services have said yes.
    var answeringServiceCount: Int {
        providers.count { serviceHealth[$0.id]?.isOK == true }
    }

    /// Whether every enabled service has answered, either way.
    ///
    /// The rail says "Checking your services" until this is true, because a
    /// count that starts at zero and climbs is indistinguishable from a real
    /// failure for as long as it is on screen.
    var hasAskedServices: Bool {
        !providers.isEmpty && providers.allSatisfy {
            serviceHealth[$0.id]?.hasAnswered == true
        }
    }

    func healthDot(for config: DebridConfig) -> ServiceHealth.Dot {
        (serviceHealth[config.id] ?? .unknown).dot(isEnabled: config.isEnabled)
    }

    /// One line, because it goes under the service's name where there is room
    /// for one. `DebridError` already says these well; anything else is
    /// reported as whatever it says about itself.
    /// `nonisolated`, because it is called from inside the task group where
    /// the failure happens rather than after it comes back — and it touches
    /// nothing but the error it is handed.
    private nonisolated static func reason(for error: Error) -> String {
        if let debrid = error as? DebridError, let described = debrid.errorDescription {
            return described
        }
        if let localized = error as? LocalizedError, let described = localized.errorDescription {
            return described
        }
        return "It did not answer."
    }
}
