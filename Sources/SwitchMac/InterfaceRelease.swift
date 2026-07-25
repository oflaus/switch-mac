import Foundation
import MTPKit

/// O macOS trata qualquer aparelho da classe USB "still image" (que é como o Android e o
/// Nintendo Switch expõem MTP) como se fosse uma câmera, e o `ptpcamerad` reserva a
/// interface para si. Enquanto ele estiver segurando, nenhum outro programa consegue falar
/// com o aparelho.
///
/// Esses processos rodam com o usuário comum e são reiniciados sob demanda pelo `launchd`,
/// então encerrá-los é seguro e reversível — é o mesmo caminho usado por outros clientes
/// MTP no macOS.
enum InterfaceRelease {

    /// Processos que reservam dispositivos de imagem no macOS.
    static let blockingProcesses = [
        "ptpcamerad",       // serviço PTP do sistema
        "mscamerad-xpc",    // serviço de câmeras da ImageCaptureCore
        "PTPCamera"         // versões antigas do macOS
    ]

    struct Running {
        let name: String
        let pid: Int32
    }

    /// Lista quais desses processos estão vivos agora.
    static func running() -> [Running] {
        var found: [Running] = []
        for name in blockingProcesses {
            for pid in pids(matching: name) {
                found.append(Running(name: name, pid: pid))
            }
        }
        return found
    }

    /// Encerra os processos bloqueadores. Devolve quantos foram encerrados.
    @discardableResult
    static func release() -> Int {
        let targets = running()
        guard !targets.isEmpty else {
            MTPLog.shared.info("nenhum processo do sistema está segurando a interface")
            return 0
        }
        var released = 0
        for target in targets {
            // Esses serviços ignoram SIGTERM; mandamos assim mesmo por educação e,
            // se continuarem vivos, usamos SIGKILL — que é o que de fato os derruba.
            _ = kill(target.pid, SIGTERM)
            Thread.sleep(forTimeInterval: 0.25)
            if kill(target.pid, 0) == 0 {
                _ = kill(target.pid, SIGKILL)
                Thread.sleep(forTimeInterval: 0.15)
            }
            if kill(target.pid, 0) != 0 {
                released += 1
                MTPLog.shared.info("encerrado \(target.name) (pid \(target.pid))")
            } else {
                MTPLog.shared.warn("não foi possível encerrar \(target.name) (pid \(target.pid))")
            }
        }
        // O launchd relança o ptpcamerad quase imediatamente, então a janela em que a
        // interface fica livre é curta: esperamos só o suficiente para o kernel liberar
        // o dispositivo e devolvemos o controle para quem vai reivindicá-lo.
        Thread.sleep(forTimeInterval: 0.2)
        return released
    }

    private static func pids(matching name: String) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }
}
