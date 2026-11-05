import Combine
import Foundation
import SwiftUI

@MainActor
public final class NotchPluginRegistry: ObservableObject {
    @Published public private(set) var plugins: [any NotchPlugin] = []
    private let coordinator: NotchStateCoordinator

    public init(coordinator: NotchStateCoordinator) {
        self.coordinator = coordinator
    }

    public func register(_ plugin: any NotchPlugin) {
        guard !plugins.contains(where: { $0.id == plugin.id }) else { return }
        plugins.append(plugin)
        if plugin.isEnabled {
            plugin.start(coordinator: coordinator)
        }
        IslandLogger.coordinator.info("Registered plugin \(plugin.id, privacy: .public) (enabled: \(plugin.isEnabled))")
    }

    public func setPluginEnabled(id: String, isEnabled: Bool) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        plugins[index].isEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "island.plugin.\(id).enabled")

        if isEnabled {
            plugins[index].start(coordinator: coordinator)
        } else {
            plugins[index].stop()
            coordinator.clearPersistentActivity(pluginID: id)
        }
        objectWillChange.send()
    }

    public func stopAll() {
        for plugin in plugins {
            plugin.stop()
        }
    }
}
