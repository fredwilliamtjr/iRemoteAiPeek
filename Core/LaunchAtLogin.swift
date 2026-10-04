import Foundation
import ServiceManagement

/// Wrapper sobre `SMAppService.mainApp` pra ligar/desligar o "iniciar com o
/// macOS" e expor o estado atual como `@Published` pra UI. Segue o mesmo
/// padrão dos apps irmãos (iMackPeek, iCloudPeek, iNetPeek).
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            apply(isEnabled)
        }
    }

    private init() {
        self.isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Re-lê o estado real (ex.: usuário mexeu em Ajustes → Itens de Início).
    func refresh() {
        let actual = SMAppService.mainApp.status == .enabled
        if actual != isEnabled { isEnabled = actual }
    }

    private func apply(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            Log.app.error("LaunchAtLogin falhou: \(error.localizedDescription, privacy: .public)")
            // Reverte o toggle pra refletir o estado real.
            let actual = SMAppService.mainApp.status == .enabled
            if actual != isEnabled { isEnabled = actual }
        }
    }
}
