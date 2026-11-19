import Foundation

@main
enum EntryPoint {
    @MainActor
    static func main() {
        do {
            if ServicePaths.isDaemon {
                guard getuid() != 0 else { throw BridgeError("O serviço deve executar como usuário, nunca como root") }
                try ServicePaths.prepare()
                let service = SystemService()
                try service.run()
                withExtendedLifetime(service) { RunLoop.main.run() }
            } else if CommandLine.arguments.contains("--service-auth-check") {
                // Consulta o próprio Claude no contexto de segurança do daemon.
                // Nunca emite dados da conta, tokens ou o conteúdo do Keychain.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", "exec claude auth status --json"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                try process.run()
                let timeout = DispatchWorkItem { [weak process] in
                    if let process, process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let loggedIn = result?["loggedIn"] as? Bool ?? false
                let output: [String: Any] = ["loggedIn": loggedIn, "exitCode": process.terminationStatus]
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output))
                if !loggedIn { exit(1) }
            } else if CommandLine.arguments.contains("--write-service-config") {
                try AppSettings.shared.saveServiceConfiguration()
            } else if CommandLine.arguments.contains("--service-status") {
                let value = try ServiceBridge.snapshot()
                FileHandle.standardOutput.write(try JSONEncoder().encode(value))
            } else if let index = CommandLine.arguments.firstIndex(of: "--service-command"),
                      CommandLine.arguments.count > index + 1,
                      let action = ServiceCommand.Action(rawValue: CommandLine.arguments[index + 1]) {
                try ServiceBridge.send(action)
            } else {
                iRemoteAiPeekApp.main()
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
