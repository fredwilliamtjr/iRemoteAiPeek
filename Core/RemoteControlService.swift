import AppKit
import Darwin
import Foundation

/// Roda e acompanha o `claude remote-control` (o `claude rc`) na pasta
/// configurada — o equivalente a abrir o Terminal, entrar na pasta e digitar
/// `claude rc`.
///
/// - O processo roda dentro de um pseudo-terminal (`PseudoTerminal`), pelo
///   shell de login do usuário, para herdar o mesmo `PATH` do Terminal.
/// - A saída é lida para descobrir o link da sessão (status **ativo**) e para
///   perceber quando o `claude rc` pede confirmação.
/// - Se o processo cair sem o usuário ter mandado parar, ele é reiniciado com
///   espera crescente (5s, 15s, 30s, 60s).
@MainActor
final class RemoteControlService: ObservableObject {
    static let shared = RemoteControlService()

    enum Status: Equatable {
        case noFolder
        case stopped
        case starting
        case active
        case needsConfirmation
        /// Já existe um `claude rc` na pasta configurada, aberto fora do app
        /// (ex.: no Terminal). O app não sobe outro; assume quando ele sair.
        case external(pid: pid_t)
        case waitingRestart(seconds: Int)
        case failed(String)

        var label: String {
            switch self {
            case .noFolder: return "Escolha uma pasta para iniciar"
            case .stopped: return "Parado"
            case .starting: return "Iniciando…"
            case .active: return "Ativo"
            case .needsConfirmation: return "Aguardando confirmação"
            case .external(let pid): return "Ativo fora do app (PID \(pid))"
            case .waitingRestart(let s): return "Caiu — reiniciando em \(s)s"
            case .failed(let msg): return "Erro: \(msg)"
            }
        }

        /// SF Symbol do ícone da barra de menus.
        var symbol: String {
            switch self {
            case .active, .external: return "dot.radiowaves.left.and.right"
            case .starting, .waitingRestart: return "arrow.triangle.2.circlepath"
            case .stopped, .noFolder: return "antenna.radiowaves.left.and.right.slash"
            case .needsConfirmation, .failed: return "exclamationmark.triangle"
            }
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var isRunning = false
    /// Link da sessão mostrado pelo `claude rc` (abre no claude.ai/code).
    @Published private(set) var sessionURL: URL?
    /// Última linha útil da saída — ajuda a entender um erro sem abrir o log.
    @Published private(set) var lastLine: String?
    /// Todas as instâncias do `claude rc` neste Mac, inclusive a do app.
    @Published private(set) var instances: [RCInstance] = []
    /// Parâmetros com que o `claude rc` do app está rodando — se forem
    /// diferentes das opções atuais, falta reiniciar para valerem.
    @Published private(set) var runningArguments: [String]?

    private let settings = AppSettings.shared
    private let log = RCLog.shared

    private var process: Process?
    private var pty: PseudoTerminal?
    private var readSource: DispatchSourceRead?
    private var tail = ""
    private var userStopped = false
    private var startedAt = Date()
    private var restartAttempt = 0
    private var restartTask: Task<Void, Never>?
    private var stopWaiters: [() -> Void] = []
    private var scanTimer: Timer?

    private static let restartDelays = [5, 15, 30, 60]
    /// Rodou pelo menos isso? Então a queda não conta como falha em sequência.
    private static let stableRun: TimeInterval = 120

    private init() {
        status = settings.folder == nil ? .noFolder : .stopped
        startScanning()
    }

    /// PID do `claude rc` iniciado pelo app (o shell faz `exec`, então é o do claude).
    var ownPID: pid_t? { process?.processIdentifier }

    /// Sessões conectadas na instância do app.
    var ownSessions: Int {
        guard let pid = ownPID else { return 0 }
        return instances.first { $0.pid == pid }?.sessions ?? 0
    }

    /// Instâncias abertas fora do app.
    var externalInstances: [RCInstance] {
        instances.filter { $0.pid != ownPID }
    }

    // MARK: - Comandos

    func start() {
        restartTask?.cancel()
        restartTask = nil
        guard process == nil else { return }

        guard let folder = settings.folder else {
            status = .noFolder
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            status = .failed("pasta não encontrada (\(settings.folderDisplay))")
            log.event("pasta não encontrada: \(folder.path)")
            return
        }

        userStopped = false

        instances = ProcessScanner.findRemoteControlInstances()
        if let other = externalInstances.first(where: { Self.samePath($0.folder, folder) }) {
            if status != .external(pid: other.pid) {
                log.event("já existe um claude rc nesta pasta fora do app (PID \(other.pid)) — não vou abrir outro")
            }
            status = .external(pid: other.pid)
            return
        }

        sessionURL = nil
        lastLine = nil
        tail = ""
        log.resetDedup()

        let rcArgs = settings.rcArguments
        // Os parâmetros vêm de opções fixas (RCOptions), sem texto livre — dá
        // para juntar na linha de comando sem escapar.
        let command = (["exec", "claude", "remote-control"] + rcArgs).joined(separator: " ")

        do {
            let pty = try PseudoTerminal(columns: 200, rows: 50)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: Self.loginShell)
            // `exec`: o shell vira o próprio claude, então o PID que o app
            // acompanha (e para) é o do claude rc.
            proc.arguments = ["-l", "-c", command]
            proc.currentDirectoryURL = folder
            proc.environment = Self.environment()
            let tty = pty.slaveHandle
            proc.standardInput = tty
            proc.standardOutput = tty
            proc.standardError = tty
            proc.terminationHandler = { [weak self] p in
                let code = p.terminationStatus
                Task { @MainActor in self?.processDidExit(p, code: code) }
            }

            try proc.run()
            pty.closeSlave()

            self.pty = pty
            self.process = proc
            startedAt = Date()
            isRunning = true
            runningArguments = rcArgs
            status = .starting
            attachReader(to: pty.master)
            refreshInstances()
            log.event("iniciando \(command.dropFirst("exec ".count)) em \(folder.path) (pid \(proc.processIdentifier))")
        } catch {
            status = .failed(error.localizedDescription)
            log.event("falha ao iniciar: \(error.localizedDescription)")
        }
    }

    /// Para o `claude rc` como um Ctrl+C no Terminal (as sessões ficam
    /// arquivadas e podem ser retomadas). `completion` roda quando o processo
    /// terminar de fato.
    func stop(completion: (() -> Void)? = nil) {
        restartTask?.cancel()
        restartTask = nil
        userStopped = true

        guard let proc = process, proc.isRunning else {
            if case .external = status { log.event("deixando de acompanhar a instância externa") }
            status = settings.folder == nil ? .noFolder : .stopped
            completion?()
            return
        }
        if let completion { stopWaiters.append(completion) }

        log.event("parando…")
        pty?.write("\u{03}")   // Ctrl+C, como no Terminal
        proc.interrupt()        // SIGINT

        // Se não sair por bem, SIGTERM e depois SIGKILL.
        let pid = proc.processIdentifier
        Task { @MainActor [weak proc] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let proc, proc.isRunning else { return }
            proc.terminate()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if proc.isRunning { kill(pid, SIGKILL) }
        }
    }

    func restart() {
        stop { [weak self] in self?.start() }
    }

    /// Troca a pasta; se o `claude rc` estiver rodando, reinicia nela.
    func changeFolder(to url: URL) {
        settings.setFolder(url)
        log.event("pasta alterada para \(url.path)")
        if isRunning {
            restart()
        } else {
            start()
        }
    }

    /// Responde "sim" à pergunta de confirmação do `claude rc`.
    func confirm() {
        guard let pty, status == .needsConfirmation else { return }
        log.event("confirmação enviada (y)")
        pty.write("y\r")
        tail = ""
        status = .starting
    }

    // MARK: - Outras instâncias

    /// Encerra uma instância externa e passa a rodar o `claude rc` na pasta
    /// dela, pelo app.
    func adopt(_ instance: RCInstance) {
        guard instance.pid != ownPID, let folder = instance.folder else { return }
        log.event("assumindo a instância PID \(instance.pid) em \(folder.path)")
        stop { [weak self] in
            guard let self else { return }
            self.settings.setFolder(folder)
            ProcessScanner.interrupt(instance.pid)
            Task { @MainActor in
                await Self.waitUntilGone(instance.pid)
                self.start()
            }
        }
    }

    /// Encerra (Ctrl+C) uma instância aberta fora do app.
    func terminateExternal(_ instance: RCInstance) {
        guard instance.pid != ownPID else { return }
        log.event("encerrando a instância externa PID \(instance.pid)")
        ProcessScanner.interrupt(instance.pid)
        Task { @MainActor [weak self] in
            await Self.waitUntilGone(instance.pid)
            self?.refreshInstances()
        }
    }

    private func startScanning() {
        refreshInstances()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshInstances() }
        }
        // `.common`: continua atualizando com o menu aberto.
        RunLoop.main.add(timer, forMode: .common)
        scanTimer = timer
    }

    func refreshInstances() {
        let found = ProcessScanner.findRemoteControlInstances()
        if found != instances { instances = found }

        // A instância externa da nossa pasta saiu: o app assume.
        if case .external(let pid) = status, !found.contains(where: { $0.pid == pid }) {
            log.event("a instância externa PID \(pid) encerrou — iniciando pelo app")
            status = .stopped
            start()
        }
    }

    private static func waitUntilGone(_ pid: pid_t) async {
        for _ in 0..<40 {   // até ~10s
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        kill(pid, SIGTERM)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    private static func samePath(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        return a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Processo

    private func processDidExit(_ proc: Process, code: Int32) {
        guard proc === process else { return }
        process = nil
        pty = nil   // o mestre é fechado pelo leitor ao receber o fim
        isRunning = false
        runningArguments = nil
        sessionURL = nil

        let ranFor = Date().timeIntervalSince(startedAt)
        log.event("claude rc encerrou (código \(code)) após \(Int(ranFor))s")

        let waiters = stopWaiters
        stopWaiters.removeAll()
        defer { waiters.forEach { $0() } }

        if userStopped {
            status = settings.folder == nil ? .noFolder : .stopped
            return
        }
        if code == 127 {
            status = .failed("comando claude não encontrado no shell de login")
            return
        }
        if status == .needsConfirmation {
            status = .failed("o claude rc pediu confirmação — use “Confirmar pelo Terminal…”")
            return
        }
        scheduleRestart(after: ranFor)
    }

    private func scheduleRestart(after ranFor: TimeInterval) {
        if ranFor >= Self.stableRun { restartAttempt = 0 }
        let delay = Self.restartDelays[min(restartAttempt, Self.restartDelays.count - 1)]
        restartAttempt += 1
        status = .waitingRestart(seconds: delay)
        log.event("reiniciando em \(delay)s (tentativa \(restartAttempt))")

        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    // MARK: - Saída do terminal

    private func attachReader(to master: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let n = read(master, &buffer, buffer.count)
            guard n > 0 else {
                // EOF/EIO: o processo fechou o terminal.
                source.cancel()
                return
            }
            let data = Data(buffer[0..<n])
            Task { @MainActor in self?.handleOutput(data) }
        }
        source.setCancelHandler { close(master) }
        readSource = source
        source.resume()
    }

    private func handleOutput(_ data: Data) {
        let raw = String(decoding: data, as: UTF8.self)
        answerTerminalQueries(raw)

        let clean = TerminalText.strip(raw)
        log.output(clean)
        if let line = TerminalText.meaningfulLines(clean).last { lastLine = line }

        tail = String((tail + clean).suffix(16_000))
        if let url = TerminalText.lastSessionURL(in: tail), url != sessionURL {
            sessionURL = url
            log.event("sessão disponível: \(url.absoluteString)")
        }
        if sessionURL != nil {
            if status != .active { status = .active }
        } else if status == .starting, TerminalText.asksConfirmation(tail) {
            status = .needsConfirmation
            log.event("o claude rc está pedindo confirmação")
        }
    }

    /// Responde às perguntas que um programa de terminal faz ao terminal
    /// (posição do cursor, tipo de terminal), como o Terminal.app faria.
    private func answerTerminalQueries(_ raw: String) {
        guard let pty else { return }
        if raw.contains("\u{1B}[6n") { pty.write("\u{1B}[1;1R") }
        if raw.contains("\u{1B}[c") || raw.contains("\u{1B}[0c") { pty.write("\u{1B}[?1;2c") }
    }

    // MARK: - Ambiente

    /// Shell de login do usuário (o mesmo do Terminal).
    private static var loginShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    /// Ambiente do processo. Apps abertos pelo Finder/login recebem um `PATH`
    /// mínimo; o shell de login completa, mas os locais comuns do `claude`
    /// entram de antemão por garantia.
    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        env["TERM"] = "xterm-256color"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // Se o app for aberto de dentro de uma sessão do Claude Code, não
        // deixar o claude rc achar que é uma sessão aninhada.
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        return env
    }
}
