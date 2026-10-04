import AppKit

/// Delegate da aplicação: inicia o claude rc ao abrir e o encerra direito ao
/// sair (como um Ctrl+C no Terminal, para as sessões ficarem arquivadas).
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.notice("iRemoteAiPeek iniciado")
        MainActor.assumeIsolated {
            RCLog.shared.event("iRemoteAiPeek \(AppInfo.versionWithBuild) aberto")
            RemoteControlService.shared.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let rc = RemoteControlService.shared
            guard rc.isRunning else { return .terminateNow }

            var replied = false
            let reply = {
                guard !replied else { return }
                replied = true
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            rc.stop(completion: reply)
            // Rede de segurança: não segura o logout/desligamento para sempre.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: reply)
            return .terminateLater
        }
    }

    /// Mantém o app vivo na barra de menus mesmo sem janelas abertas.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
