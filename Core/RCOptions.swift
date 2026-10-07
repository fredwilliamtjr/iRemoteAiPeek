import Foundation

/// Modo de permissão com que as sessões do `claude rc` começam
/// (`--permission-mode`). Pelo app do Claude só dá para trocar uma sessão
/// remota para Manual, Aceitar edições ou Planejar — Auto e Bypass só
/// entram pelo parâmetro de início.
enum RCPermissionMode: String, CaseIterable, Identifiable {
    /// Sem o parâmetro: vale o padrão do Claude Code.
    case standard = ""
    case manual = "default"
    case acceptEdits
    case plan
    case auto
    case dontAsk
    case bypassPermissions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Padrão do Claude Code (sem parâmetro)"
        case .manual: return "Manual — pede aprovação (default)"
        case .acceptEdits: return "Aceitar edições (acceptEdits)"
        case .plan: return "Planejar (plan)"
        case .auto: return "Auto (auto)"
        case .dontAsk: return "Só o pré-aprovado (dontAsk)"
        case .bypassPermissions: return "Sem checagem — só contêiner/VM (bypassPermissions)"
        }
    }
}

/// Como o servidor cria as sessões (`--spawn`).
enum RCSpawnMode: String, CaseIterable, Identifiable {
    /// Sem o parâmetro: `same-dir`, o padrão do Claude Code.
    case standard = ""
    case sameDir = "same-dir"
    case worktree
    case session

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Padrão do Claude Code (sem parâmetro)"
        case .sameDir: return "Todas na mesma pasta (same-dir)"
        case .worktree: return "Um worktree por sessão — pasta precisa ser repo git (worktree)"
        case .session: return "Uma sessão só (session)"
        }
    }
}
