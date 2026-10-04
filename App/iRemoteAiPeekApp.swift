import SwiftUI

@main
struct iRemoteAiPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var rc = RemoteControlService.shared

    var body: some Scene {
        // App de barra de menus puro: sem janela. O ícone muda conforme o
        // estado do claude rc (ativo, iniciando, parado, atenção).
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(rc)
                .environmentObject(AppSettings.shared)
        } label: {
            Image(systemName: rc.status.symbol)
                .accessibilityLabel("iRemoteAiPeek — \(rc.status.label)")
        }
    }
}
