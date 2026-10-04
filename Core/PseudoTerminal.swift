import Darwin
import Foundation

/// Par mestre/escravo de pseudo-terminal (`openpty`).
///
/// O `claude remote-control` é uma interface de terminal (mostra o link, o QR
/// code e lê teclas). Rodando com stdin/stdout em *pipes* ele não se comporta
/// como no Terminal — então o processo recebe o lado **escravo** como
/// stdin/stdout/stderr e o app lê/escreve pelo lado **mestre**, exatamente
/// como um emulador de terminal faria.
final class PseudoTerminal {

    enum PTYError: Error, LocalizedError {
        case openFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .openFailed(let code):
                return "Não foi possível abrir um pseudo-terminal (errno \(code))."
            }
        }
    }

    let master: Int32
    private(set) var slave: Int32

    /// Abre o par com o tamanho de janela dado. Colunas largas evitam que o
    /// link da sessão seja quebrado em duas linhas.
    init(columns: UInt16, rows: UInt16) throws {
        var m: Int32 = -1
        var s: Int32 = -1
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &s, nil, nil, &size) == 0 else {
            throw PTYError.openFailed(errno)
        }
        master = m
        slave = s
    }

    /// Handle do lado escravo, para entregar ao `Process`.
    var slaveHandle: FileHandle {
        FileHandle(fileDescriptor: slave, closeOnDealloc: false)
    }

    /// Fecha o lado escravo no app. Deve ser chamado logo depois do
    /// `Process.run()`: o filho já tem a sua cópia, e mantendo a nossa aberta o
    /// mestre nunca recebe fim de arquivo quando o processo termina.
    func closeSlave() {
        guard slave >= 0 else { return }
        close(slave)
        slave = -1
    }

    /// Escreve no terminal, como se fosse digitado.
    func write(_ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buf in
            _ = Darwin.write(master, buf.baseAddress, buf.count)
        }
    }
}
