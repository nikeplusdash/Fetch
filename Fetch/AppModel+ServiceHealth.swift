import Foundation
import FetchKit
import FetchPluginAPI

extension AppModel {
    func refreshServiceHealth() async {
        let asking = providers
        guard !asking.isEmpty else {
            serviceHealth = [:]
            return
        }

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
                guard providers.contains(where: { $0.id == id }) else { continue }
                serviceHealth[id] = health
            }
        }
    }

    var answeringServiceCount: Int {
        providers.count { serviceHealth[$0.id]?.isOK == true }
    }

    var hasAskedServices: Bool {
        !providers.isEmpty && providers.allSatisfy {
            serviceHealth[$0.id]?.hasAnswered == true
        }
    }

    func healthDot(for config: DebridConfig) -> ServiceHealth.Dot {
        (serviceHealth[config.id] ?? .unknown).dot(isEnabled: config.isEnabled)
    }

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
