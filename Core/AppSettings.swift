import Foundation

/// Configurações persistidas do app (por Mac).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let folderKey = "workingDirectory"

    /// Pasta onde o `claude remote-control` é iniciado.
    @Published private(set) var folder: URL?

    private init() {
        if let path = UserDefaults.standard.string(forKey: folderKey) {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    func setFolder(_ url: URL) {
        folder = url
        UserDefaults.standard.set(url.path, forKey: folderKey)
    }

    /// Caminho curto para exibir no menu (`~/…`).
    var folderDisplay: String {
        guard let folder else { return "nenhuma" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = folder.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
