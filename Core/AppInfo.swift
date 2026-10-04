import Foundation

/// Informações da versão do app, lidas do bundle (vêm do `project.yml`:
/// `MARKETING_VERSION` e `CURRENT_PROJECT_VERSION`).
enum AppInfo {
    /// Versão curta, ex.: "0.1.0".
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Número de build, ex.: "1".
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// Ex.: "v0.1.0".
    static var version: String { "v\(shortVersion)" }

    /// Ex.: "v0.1.0 (1)".
    static var versionWithBuild: String { "v\(shortVersion) (\(build))" }
}
