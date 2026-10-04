import Darwin
import Foundation

/// Uma instância do `claude rc` rodando neste Mac (dentro ou fora do app).
struct RCInstance: Identifiable, Equatable {
    let pid: pid_t
    /// Pasta atual do processo — onde o `claude rc` foi iniciado.
    let folder: URL?
    /// Sessões conectadas (processos filhos com `--sdk-url`).
    let sessions: Int

    var id: pid_t { pid }

    var folderDisplay: String {
        guard let folder else { return "pasta desconhecida" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = folder.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Varre os processos do usuário atrás de `claude rc` / `claude remote-control`
/// — inclusive os abertos à mão no Terminal — e descobre a pasta de cada um.
///
/// Usa só APIs do próprio macOS (`proc_listallpids`, `sysctl KERN_PROCARGS2`,
/// `proc_pidinfo`), sem `ps`/`lsof` e sem permissão extra: processos do
/// próprio usuário são legíveis.
enum ProcessScanner {

    private static let rcSubcommands: Set<String> = ["rc", "remote-control"]

    static func findRemoteControlInstances() -> [RCInstance] {
        var rcPIDs: [pid_t] = []
        var sessionParents: [pid_t: Int] = [:]

        for pid in allPIDs() {
            guard let args = arguments(of: pid), let first = args.first else { continue }
            let rest = args.dropFirst()
            if isClaude(first), rest.contains(where: rcSubcommands.contains) {
                rcPIDs.append(pid)
            } else if rest.contains("--sdk-url"), let ppid = parentPID(of: pid) {
                sessionParents[ppid, default: 0] += 1
            }
        }

        return rcPIDs.sorted().map { pid in
            RCInstance(pid: pid, folder: currentDirectory(of: pid), sessions: sessionParents[pid] ?? 0)
        }
    }

    /// Envia SIGINT (o Ctrl+C do Terminal) para uma instância.
    static func interrupt(_ pid: pid_t) {
        kill(pid, SIGINT)
    }

    // MARK: - Processos

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
    }

    /// `argv` do processo, via `KERN_PROCARGS2` (argc + caminho do executável +
    /// argumentos, separados por NUL).
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Pula o caminho do executável e o preenchimento de NULs.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var args: [String] = []
        while index < size, args.count < Int(argc) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    /// `argv[0]` é o `claude`? (ex.: `claude`, `/Users/x/.local/bin/claude`)
    private static func isClaude(_ argv0: String) -> Bool {
        (argv0 as NSString).lastPathComponent == "claude"
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func currentDirectory(of pid: pid_t) -> URL? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }
}
