import Foundation

/// Abre o Terminal.app rodando `claude rc` na pasta — usado quando a primeira
/// execução precisa de uma confirmação que o app não conseguiu responder.
enum TerminalLauncher {

    static func openClaudeRC(in folder: URL) {
        let script = """
        tell application "Terminal"
          activate
          do script "cd " & quoted form of "\(appleScriptEscaped(folder.path))" & " && claude rc"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        do {
            try proc.run()
        } catch {
            Log.app.error("Falha ao abrir o Terminal: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Escapa um texto para dentro de uma string literal do AppleScript.
    private static func appleScriptEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
