import Foundation

/// Dono da libusb e da única fila serial onde toda a I/O USB acontece.
/// O protocolo MTP é estritamente sequencial (uma transação por vez), então
/// serializar tudo aqui não custa desempenho e elimina uma classe inteira de bugs.
public final class MTPBus: @unchecked Sendable {
    public static let shared = MTPBus()

    let queue = DispatchQueue(label: "com.switchmac.usb", qos: .userInitiated)
    private var backend: USBBackend?
    private var initError: Error?

    private init() {}

    private func backendOnQueue() throws -> USBBackend {
        dispatchPrecondition(condition: .onQueue(queue))
        if let backend { return backend }
        if let initError { throw initError }
        do {
            let b = try USBBackend()
            backend = b
            MTPLog.shared.info("libusb inicializada")
            return b
        } catch {
            initError = error
            MTPLog.shared.error("falha ao inicializar libusb: \(error.localizedDescription)")
            throw error
        }
    }

    func run<T>(_ body: @escaping (USBBackend) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body(self.backendOnQueue()) })
            }
        }
    }

    /// Executa algo já dentro da fila serial, sem precisar do backend.
    func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    /// Lista os aparelhos Android presentes no barramento.
    public func scan() async -> [DiscoveredDevice] {
        (try? await run { $0.scan() }) ?? []
    }

    /// Relatório do barramento USB, usado pelo modo `--scan` e pelo diagnóstico.
    public func report() async -> String {
        do { return try await run { $0.report() } }
        catch { return "falha ao acessar o USB: \(error.localizedDescription)" }
    }

    /// Checagem barata de presença, sem abrir nenhum dispositivo.
    public func isPresent(_ id: USBDeviceID) async -> Bool {
        (try? await run { $0.presentIDs().contains(id) }) ?? false
    }

    /// Abre uma sessão MTP com o aparelho indicado.
    public func openSession(with device: DiscoveredDevice) async throws -> MTPSession {
        let session = try await run { backend -> MTPSession in
            let connection = try backend.connect(to: device.id)
            return MTPSession(bus: self, backend: backend, connection: connection, device: device)
        }
        try await session.start()
        return session
    }
}
