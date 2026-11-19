import Foundation

/// Configurações persistidas do app (por Mac).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private static var preferences: UserDefaults? {
        // Testes isolados nunca leem nem alteram as preferências reais do menu.
        guard ProcessInfo.processInfo.environment["IREMOTEAIPEEK_SERVICE_DIR"] == nil else { return nil }
        if Bundle.main.bundleIdentifier == "com.smartfull.iremoteaipeek" { return .standard }
        return UserDefaults(suiteName: "com.smartfull.iremoteaipeek")
    }

    private var loadingServiceConfiguration = false
    private let folderKey = "workingDirectory"
    private let chromeKey = "rcChrome"
    private let permissionModeKey = "rcPermissionMode"
    private let spawnModeKey = "rcSpawnMode"

    /// Pasta onde o `claude remote-control` é iniciado.
    @Published private(set) var folder: URL?

    /// Liga o Claude in Chrome nas sessões do `claude rc` (`--chrome`). Sem
    /// ele, as sessões abertas pelo app do Claude começam sem o Chrome.
    @Published var chrome: Bool {
        didSet { persist(chrome, key: chromeKey) }
    }

    /// Modo de permissão inicial das sessões (`--permission-mode`).
    @Published var permissionMode: RCPermissionMode {
        didSet { persist(permissionMode.rawValue, key: permissionModeKey) }
    }

    /// Como o servidor cria as sessões (`--spawn`).
    @Published var spawnMode: RCSpawnMode {
        didSet { persist(spawnMode.rawValue, key: spawnModeKey) }
    }

    private init() {
        let defaults = Self.preferences
        if let path = defaults?.string(forKey: folderKey) {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        }
        chrome = defaults?.bool(forKey: chromeKey) ?? false
        permissionMode = RCPermissionMode(rawValue: defaults?.string(forKey: permissionModeKey) ?? "") ?? .standard
        spawnMode = RCSpawnMode(rawValue: defaults?.string(forKey: spawnModeKey) ?? "") ?? .standard
    }

    func setFolder(_ url: URL) {
        folder = url
        persist(url.path, key: folderKey)
    }

    private func persist(_ value: Any, key: String) {
        guard !loadingServiceConfiguration else { return }
        Self.preferences?.set(value, forKey: key)
        if ServicePaths.isInstalled || ServicePaths.isDaemon {
            do { try saveServiceConfiguration() }
            catch { Log.app.error("Configuração do serviço: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func saveServiceConfiguration() throws {
        try ServicePaths.write(ServiceConfiguration(folder: folder?.path, chrome: chrome,
            permissionMode: permissionMode.rawValue, spawnMode: spawnMode.rawValue), to: ServicePaths.configuration)
    }

    func reloadServiceConfiguration() throws {
        let config = try ServicePaths.read(ServiceConfiguration.self, from: ServicePaths.configuration)
        guard let permission = RCPermissionMode(rawValue: config.permissionMode),
              let spawn = RCSpawnMode(rawValue: config.spawnMode),
              config.folder == nil || config.folder!.hasPrefix("/") else { throw BridgeError("Configuração inválida") }
        loadingServiceConfiguration = true
        defer { loadingServiceConfiguration = false }
        folder = config.folder.map { URL(fileURLWithPath: $0, isDirectory: true) }
        chrome = config.chrome
        permissionMode = permission
        spawnMode = spawn
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
