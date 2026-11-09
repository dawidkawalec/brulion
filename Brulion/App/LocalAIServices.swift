import Foundation
import os

/// The local AI as the app wires it (docs/local-ai.md, "Integration points"): the Bielik
/// downloads for Modele and the onboarding (`LocalAIModelStore`), the model servers
/// (`LocalAIService`), the local usage counter (`LocalUsageStats`) and this Mac's memory tier.
/// Built once by `AppState` on the data folder, or on a temp folder with no servers at all for
/// the design preview and the test host.
@MainActor
final class LocalAIServices {
    let hardware: HardwareProfile
    let store: LocalAIModelStore
    /// nil when no llama-server may start (the design preview, the test host).
    let service: LocalAIService?
    let usage: LocalUsageStats

    /// The role -> model mapping and options last sent to the service, so a settings change that
    /// moves nothing sends nothing.
    private var applied: (roleModels: [LocalRole: LocalModelSpec], options: LocalAIService.Options)?
    /// Changes reach the service in the order they were made.
    private var applyTask: Task<Void, Never>?

    init(
        root: URL,
        startsServers: Bool,
        pinnedStates: [String: LocalAIModelStore.State]?,
        routing: AIRoleRouting,
        idleTimeout: Duration?,
        hardware: HardwareProfile = .current
    ) {
        self.hardware = hardware
        let modelsDirectory = AppPaths.localModels(in: root)
        store = LocalAIModelStore(modelsDirectory: modelsDirectory, pinnedStates: pinnedStates)
        let usage = LocalUsageStats(fileURL: AppPaths.localAIUsage(in: root))
        self.usage = usage
        if startsServers {
            let options = Self.options(idleTimeout: idleTimeout, hardware: hardware)
            service = LocalAIService(
                roleModels: routing.roleModels,
                modelsDirectory: modelsDirectory,
                runDirectory: AppPaths.localAIRun(in: root),
                options: options,
                onUnexpectedExit: { modelID, status in
                    LocalAILog.logger.error("llama-server for \(modelID, privacy: .public) exited with \(status)")
                    Task { await usage.record(.serverFailure) }
                }
            )
            applied = (routing.roleModels, options)
        } else {
            service = nil
        }
        // A model is deleted only after its server stopped (the file is mapped while it runs).
        let service = self.service
        store.willDelete = { spec in
            await service?.stop(modelID: spec.id)
        }
    }

    /// The service options for the idle time in Ustawienia and this Mac's memory budget.
    static func options(idleTimeout: Duration?, hardware: HardwareProfile) -> LocalAIService.Options {
        LocalAIService.Options(idleTimeout: idleTimeout, memoryBudgetBytes: hardware.memoryBudgetBytes)
    }

    /// Feeds a settings change to the running service: the models per role and the idle time.
    /// Servers no longer needed stop; a new idle time restarts them on next use.
    func apply(routing: AIRoleRouting, idleTimeout: Duration?) {
        guard let service else { return }
        let roleModels = routing.roleModels
        let options = Self.options(idleTimeout: idleTimeout, hardware: hardware)
        if let applied, applied.roleModels == roleModels, applied.options == options { return }
        applied = (roleModels, options)
        let previous = applyTask
        applyTask = Task {
            await previous?.value
            await service.setRoleModels(roleModels)
            await service.setOptions(options)
        }
    }

    /// Records a usage event (no text, no network) without waiting.
    nonisolated func record(_ event: LocalUsageEvent) {
        let usage = self.usage
        Task { await usage.record(event) }
    }

    /// `applicationWillTerminate`: SIGTERM to every model server now.
    func terminateAllNow() {
        service?.terminateAllNow()
    }
}
