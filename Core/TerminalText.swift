import Foundation

/// Utilitários para interpretar a saída de terminal do `claude remote-control`.
enum TerminalText {

    // Sequências de escape: CSI (cores, cursor), OSC (título, hyperlinks) e
    // escapes simples de dois caracteres.
    private static let csi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-?]*[ -/]*[@-~]")
    private static let osc = try! NSRegularExpression(pattern: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)")
    private static let simpleEscape = try! NSRegularExpression(pattern: "\u{1B}[@-Z\\\\-_]")
    private static let sessionURL = try! NSRegularExpression(
        pattern: "https://claude\\.ai/code[A-Za-z0-9\\-._~:/?#@!$&'()*+,;=%]*")

    /// Remove as sequências de escape e normaliza quebras de linha.
    static func strip(_ raw: String) -> String {
        var s = raw
        for regex in [osc, csi, simpleEscape] {
            s = regex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Último link de sessão (`https://claude.ai/code…`) presente no texto.
    static func lastSessionURL(in text: String) -> URL? {
        let matches = sessionURL.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let match = matches.last, let range = Range(match.range, in: text) else { return nil }
        // Pontuação colada no fim do link não faz parte dele.
        let link = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)'"))
        return URL(string: link)
    }

    /// O `claude rc` está pedindo uma confirmação (primeira execução na pasta
    /// ou confiança no diretório)?
    static func asksConfirmation(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("enable remote control?")
            || lower.contains("do you trust the files")
            || lower.contains("trust this folder")
    }

    /// Linhas desenhadas só com blocos (o QR code) — ruído para o log.
    static func isBlockArt(_ line: String) -> Bool {
        let blocks: Set<Character> = ["█", "▀", "▄", "▌", "▐", " "]
        let nonSpace = line.filter { $0 != " " }
        guard nonSpace.count >= 8 else { return false }
        return line.allSatisfy { blocks.contains($0) }
    }

    /// Linhas úteis (sem vazias, bordas de caixa e QR code) de um trecho limpo.
    static func meaningfulLines(_ clean: String) -> [String] {
        clean.split(separator: "\n").compactMap { sub in
            let line = sub.trimmingCharacters(in: CharacterSet(charactersIn: " │|─╭╮╰╯┃━").union(.whitespaces))
            guard !line.isEmpty, !isBlockArt(line) else { return nil }
            return line
        }
    }
}
