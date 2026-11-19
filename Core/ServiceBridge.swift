import Darwin
import Foundation

/// IPC local: diretório privado do usuário, sem porta de rede e sem credenciais.
/// O daemon executa com o mesmo UID do menu, nunca como root.
enum ServicePaths {
    static let label = "com.smartfull.iremoteaipeek.service.\(getuid())"
    static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["IREMOTEAIPEEK_SERVICE_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/iRemoteAiPeek", isDirectory: true)
    }()
    static var isDaemon: Bool { ProcessInfo.processInfo.arguments.contains("--service") }
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\(label).plist")
    }
    static var commands: URL { root.appendingPathComponent("commands", isDirectory: true) }
    static var state: URL { root.appendingPathComponent("status.json") }
    static var configuration: URL { root.appendingPathComponent("configuration.json") }
    static var enabled: URL { root.appendingPathComponent("enabled.json") }

    static func prepare() throws {
        for dir in [root, commands] {
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            var info = stat()
            guard lstat(dir.path, &info) == 0, info.st_uid == getuid(),
                  (info.st_mode & S_IFMT) == S_IFDIR else {
                throw BridgeError("Diretório de serviço não pertence ao usuário ou é um link")
            }
            guard chmod(dir.path, 0o700) == 0 else { throw BridgeError("Não foi possível proteger o diretório do serviço") }
        }
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try prepare()
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw BridgeError("Não foi possível proteger o arquivo do serviço") }
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFREG, (info.st_mode & 0o077) == 0,
              info.st_size <= 256 * 1024 else { throw BridgeError("Arquivo do serviço ausente ou sem proteção") }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

struct BridgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ServiceConfiguration: Codable {
    var folder: String?
    var chrome: Bool
    var permissionMode: String
    var spawnMode: String
}

struct ServiceEnabled: Codable { var enabled: Bool }

struct ServiceSnapshot: Codable {
    var version = 1
    var updatedAt = Date()
    var daemonPID = getpid()
    var instanceID: String
    var status: RemoteControlService.Status
    var isRunning: Bool
    var ownPID: pid_t?
    var sessionURL: URL?
    var lastLine: String?
    var instances: [RCInstance]
    var runningArguments: [String]?

    var isCurrent: Bool {
        version == 1 && Date().timeIntervalSince(updatedAt) >= -5
            && Date().timeIntervalSince(updatedAt) < 10 && kill(daemonPID, 0) == 0
    }
}

struct ServiceCommand: Codable {
    enum Action: String, Codable { case start, stop, restart, confirm, changeFolder, adopt, terminateExternal }
    var createdAt = Date()
    var instanceID: String
    var action: Action
    var folder: String?
    var pid: pid_t?
}

@MainActor
enum ServiceBridge {
    static func snapshot() throws -> ServiceSnapshot {
        let state = try ServicePaths.read(ServiceSnapshot.self, from: ServicePaths.state)
        guard state.isCurrent else { throw BridgeError("Serviço do sistema sem resposta") }
        return state
    }

    static func send(_ action: ServiceCommand.Action, folder: URL? = nil, pid: pid_t? = nil) throws {
        let state = try snapshot()
        let name = String(format: "%020llu-%@.json", DispatchTime.now().uptimeNanoseconds, UUID().uuidString)
        try ServicePaths.write(ServiceCommand(instanceID: state.instanceID, action: action, folder: folder?.path, pid: pid),
                               to: ServicePaths.commands.appendingPathComponent(name))
    }
}

/// Mantém o supervisor no domínio system do launchd. Não cria NSApplication
/// nem depende de WindowServer; o menu é apenas um cliente deste processo.
@MainActor
final class SystemService {
    private let rc = RemoteControlService.shared
    private let instanceID = UUID().uuidString
    private var timer: Timer?
    private var lockFD: Int32 = -1
    private var signalSources: [DispatchSourceSignal] = []

    func run() throws {
        try ServicePaths.prepare()
        lockFD = open(ServicePaths.root.appendingPathComponent("service.lock").path,
                      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw BridgeError("Já existe um supervisor nesta pasta")
        }
        try AppSettings.shared.reloadServiceConfiguration()
        let enabled = FileManager.default.fileExists(atPath: ServicePaths.enabled.path)
            ? try ServicePaths.read(ServiceEnabled.self, from: ServicePaths.enabled).enabled : true
        if enabled { rc.start() } else { rc.stop() }
        try publish()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.rc.stop { exit(0) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func tick() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: ServicePaths.commands,
                includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                // Remove antes de executar: uma queda nunca repete um comando destrutivo.
                let command = try? ServicePaths.read(ServiceCommand.self, from: file)
                try FileManager.default.removeItem(at: file)
                guard let command, command.instanceID == instanceID, Date().timeIntervalSince(command.createdAt) < 30,
                      Date().timeIntervalSince(command.createdAt) >= -5 else { continue }
                try AppSettings.shared.reloadServiceConfiguration()
                try execute(command)
            }
            try publish()
        } catch {
            RCLog.shared.event("serviço: \(error.localizedDescription)")
        }
    }

    private func execute(_ command: ServiceCommand) throws {
        switch command.action {
        case .start:
            try ServicePaths.write(ServiceEnabled(enabled: true), to: ServicePaths.enabled)
            rc.start()
        case .stop:
            try ServicePaths.write(ServiceEnabled(enabled: false), to: ServicePaths.enabled)
            rc.stop()
        case .restart:
            try ServicePaths.write(ServiceEnabled(enabled: true), to: ServicePaths.enabled)
            rc.restart()
        case .confirm: rc.confirm()
        case .changeFolder:
            guard let path = command.folder, path.hasPrefix("/") else { throw BridgeError("Pasta inválida") }
            try ServicePaths.write(ServiceEnabled(enabled: true), to: ServicePaths.enabled)
            rc.changeFolder(to: URL(fileURLWithPath: path, isDirectory: true))
        case .adopt, .terminateExternal:
            rc.refreshInstances()
            guard let pid = command.pid, let instance = rc.instances.first(where: { $0.pid == pid }),
                  pid != rc.ownPID else { throw BridgeError("Instância não encontrada") }
            if command.action == .adopt { rc.adopt(instance) } else { rc.terminateExternal(instance) }
        }
    }

    private func publish() throws {
        try ServicePaths.write(ServiceSnapshot(instanceID: instanceID, status: rc.status, isRunning: rc.isRunning,
            ownPID: rc.ownPID, sessionURL: rc.sessionURL, lastLine: rc.lastLine,
            instances: rc.instances, runningArguments: rc.runningArguments), to: ServicePaths.state)
    }
}
