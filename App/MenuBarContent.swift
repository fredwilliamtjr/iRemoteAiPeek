import AppKit
import SwiftUI

/// Menu do ícone da barra: estado do claude rc, pasta, controles, link da
/// sessão, log, iniciar com o macOS e sair.
struct MenuBarContent: View {
    @EnvironmentObject private var rc: RemoteControlService
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared

    var body: some View {
        Text("iRemoteAiPeek \(AppInfo.versionWithBuild)")

        Divider()

        Text("Status: \(statusText)")
        Text("Pasta: \(settings.folderDisplay)")
        if showsLastLine, let line = rc.lastLine {
            Text(line.count > 80 ? String(line.prefix(80)) + "…" : line)
        }

        Divider()

        if rc.isRunning {
            Button("Parar") { rc.stop() }
            Button("Reiniciar") { rc.restart() }
        } else if case .external = rc.status {
            Button("Deixar de acompanhar") { rc.stop() }
        } else {
            Button("Iniciar") { rc.start() }
                .disabled(settings.folder == nil)
        }

        if let url = rc.sessionURL {
            Button("Abrir sessão no navegador") { NSWorkspace.shared.open(url) }
            Button("Copiar link da sessão") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }

        if rc.status == .needsConfirmation {
            Button("Confirmar “Enable Remote Control?”") { rc.confirm() }
        }
        if needsTerminalFallback {
            Button("Confirmar pelo Terminal…") { confirmViaTerminal() }
        }

        Divider()

        instancesSection

        Divider()

        optionsMenu
        if optionsPending {
            Button("Reiniciar para aplicar as opções") { rc.restart() }
        }

        Button("Escolher pasta…") { chooseFolder() }
        Button("Abrir pasta no Finder") {
            if let folder = settings.folder { NSWorkspace.shared.open(folder) }
        }
        .disabled(settings.folder == nil)
        Button("Abrir log") { NSWorkspace.shared.open(RCLog.shared.fileURL) }

        Divider()

        Toggle("Iniciar com o macOS", isOn: $launchAtLogin.isEnabled)

        Button("Sair do iRemoteAiPeek") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        guard rc.status == .active else { return rc.status.label }
        return "Ativo · " + sessionsText(rc.ownSessions)
    }

    private func sessionsText(_ n: Int) -> String {
        switch n {
        case 0: return "nenhuma sessão aberta"
        case 1: return "1 sessão aberta"
        default: return "\(n) sessões abertas"
        }
    }

    /// Todas as instâncias do `claude rc` encontradas neste Mac, inclusive as
    /// abertas fora do app (ex.: no Terminal), com a pasta de cada uma.
    @ViewBuilder
    private var instancesSection: some View {
        Text(rc.instances.isEmpty ? "Nenhum claude rc rodando neste Mac" : "claude rc rodando neste Mac:")
        ForEach(rc.instances) { instance in
            let own = instance.pid == rc.ownPID
            Menu("\(instance.folderDisplay) — \(own ? "deste app" : "PID \(instance.pid)") · \(sessionsText(instance.sessions))") {
                Button("Abrir pasta no Finder") {
                    if let folder = instance.folder { NSWorkspace.shared.open(folder) }
                }
                .disabled(instance.folder == nil)
                if !own {
                    Button("Assumir no iRemoteAiPeek") { rc.adopt(instance) }
                        .disabled(instance.folder == nil)
                    Button("Encerrar (Ctrl+C)") { rc.terminateExternal(instance) }
                }
            }
        }
    }

    /// Parâmetros do `claude rc`. Valem a partir do próximo início.
    private var optionsMenu: some View {
        Menu("Opções do claude rc") {
            Toggle("Claude in Chrome (--chrome)", isOn: $settings.chrome)
            Picker("Modo de permissão (--permission-mode)", selection: $settings.permissionMode) {
                ForEach(RCPermissionMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Sessões (--spawn)", selection: $settings.spawnMode) {
                ForEach(RCSpawnMode.allCases) { Text($0.label).tag($0) }
            }
            Divider()
            Text("claude remote-control " + settings.rcArguments.joined(separator: " "))
            Text("Vale ao iniciar ou reiniciar o claude rc")
        }
    }

    /// O `claude rc` do app está rodando com parâmetros diferentes das opções.
    private var optionsPending: Bool {
        guard let running = rc.runningArguments else { return false }
        return running != settings.rcArguments
    }

    private var showsLastLine: Bool {
        switch rc.status {
        case .starting, .failed, .waitingRestart, .needsConfirmation: return true
        default: return false
        }
    }

    private var needsTerminalFallback: Bool {
        guard settings.folder != nil else { return false }
        switch rc.status {
        case .needsConfirmation, .failed: return true
        default: return false
        }
    }

    private func chooseFolder() {
        // Deixa o menu fechar antes de abrir o painel.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.title = "Pasta do claude rc"
            panel.message = "O claude remote-control será iniciado nesta pasta."
            panel.prompt = "Usar esta pasta"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.directoryURL = settings.folder
            if panel.runModal() == .OK, let url = panel.url {
                rc.changeFolder(to: url)
            }
        }
    }

    private func confirmViaTerminal() {
        guard let folder = settings.folder else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Confirmar pelo Terminal"
            alert.informativeText = """
            O iRemoteAiPeek vai parar o serviço e abrir o Terminal rodando “claude rc” em \(settings.folderDisplay).

            Responda “y” à pergunta, feche com Ctrl+C e depois clique em “Iniciar” no menu. A confirmação fica salva e não é pedida de novo nesta pasta.
            """
            alert.addButton(withTitle: "Abrir Terminal")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            rc.stop {
                TerminalLauncher.openClaudeRC(in: folder)
            }
        }
    }
}
