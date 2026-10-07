import Foundation

/// Configurações persistidas do app (por Mac).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let folderKey = "workingDirectory"
    private let chromeKey = "rcChrome"
    private let permissionModeKey = "rcPermissionMode"
    private let spawnModeKey = "rcSpawnMode"

    /// Pasta onde o `claude remote-control` é iniciado.
    @Published private(set) var folder: URL?

    /// Liga o Claude in Chrome nas sessões do `claude rc` (`--chrome`). Sem
    /// ele, as sessões abertas pelo app do Claude começam sem o Chrome.
    @Published var chrome: Bool {
        didSet { UserDefaults.standard.set(chrome, forKey: chromeKey) }
    }

    /// Modo de permissão inicial das sessões (`--permission-mode`).
    @Published var permissionMode: RCPermissionMode {
        didSet { UserDefaults.standard.set(permissionMode.rawValue, forKey: permissionModeKey) }
    }

    /// Como o servidor cria as sessões (`--spawn`).
    @Published var spawnMode: RCSpawnMode {
        didSet { UserDefaults.standard.set(spawnMode.rawValue, forKey: spawnModeKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: folderKey) {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        }
        chrome = defaults.bool(forKey: chromeKey)
        permissionMode = RCPermissionMode(rawValue: defaults.string(forKey: permissionModeKey) ?? "") ?? .standard
        spawnMode = RCSpawnMode(rawValue: defaults.string(forKey: spawnModeKey) ?? "") ?? .standard
    }

    func setFolder(_ url: URL) {
        folder = url
        UserDefaults.standard.set(url.path, forKey: folderKey)
    }

    /// Parâmetros passados depois de `claude remote-control`.
    var rcArguments: [String] {
        var args: [String] = []
        if chrome { args.append("--chrome") }
        if permissionMode != .standard { args += ["--permission-mode", permissionMode.rawValue] }
        if spawnMode != .standard { args += ["--spawn", spawnMode.rawValue] }
        return args
    }

    /// Caminho curto para exibir no menu (`~/…`).
    var folderDisplay: String {
        guard let folder else { return "nenhuma" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = folder.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
