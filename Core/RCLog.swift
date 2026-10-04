import Foundation

/// Log em arquivo da saída do `claude remote-control` e dos eventos do app.
///
/// A interface do `claude rc` redesenha a tela o tempo todo; para o log não
/// virar uma repetição infinita, cada linha só é gravada se não apareceu nas
/// últimas centenas, e o QR code é descartado.
@MainActor
final class RCLog {
    static let shared = RCLog()

    let fileURL: URL
    private var recent: [String] = []
    private var recentSet: Set<String> = []
    private let recentLimit = 400
    private let maxBytes = 5 * 1024 * 1024
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/iRemoteAiPeek", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("claude-rc.log")
    }

    /// Evento do próprio app (iniciar, parar, queda…). Sempre gravado.
    func event(_ message: String) {
        write("[\(timeFormatter.string(from: Date()))] ── \(message)")
        Log.rc.notice("\(message, privacy: .public)")
    }

    /// Trecho já limpo (sem escapes) da saída do processo.
    func output(_ clean: String) {
        let stamp = timeFormatter.string(from: Date())
        for line in TerminalText.meaningfulLines(clean) where !recentSet.contains(line) {
            remember(line)
            write("[\(stamp)] \(line)")
        }
    }

    /// Esquece as linhas recentes — numa nova execução tudo volta a ser gravado.
    func resetDedup() {
        recent.removeAll()
        recentSet.removeAll()
    }

    private func remember(_ line: String) {
        recent.append(line)
        recentSet.insert(line)
        if recent.count > recentLimit {
            recentSet.remove(recent.removeFirst())
        }
    }

    private func write(_ line: String) {
        rotateIfNeeded()
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }

    private func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        guard size > maxBytes else { return }
        let old = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
    }
}
