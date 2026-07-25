import Foundation

/// Uma sessão MTP aberta com um aparelho. Toda a I/O roda na fila serial do `MTPBus`;
/// os métodos públicos são `async` e apenas empacotam o trabalho para lá.
public final class MTPSession: @unchecked Sendable {

    // MARK: Estado

    private let bus: MTPBus
    private let backend: USBBackend
    private var connection: USBConnection?
    public let device: DiscoveredDevice

    public private(set) var info = MTPDeviceInfo()
    public private(set) var friendlyName = ""

    private var transactionID: UInt32 = 0
    private let sessionID: UInt32 = 1
    private var leftover: [UInt8] = []

    private let rxCapacity = 512 * 1024
    private let txCapacity = 512 * 1024
    private let rxBuffer: UnsafeMutablePointer<UInt8>
    private let txBuffer: UnsafeMutablePointer<UInt8>

    private let cmdTimeout: UInt32 = 10_000
    private let dataTimeout: UInt32 = 60_000
    private let responseTimeout: UInt32 = 300_000

    init(bus: MTPBus, backend: USBBackend, connection: USBConnection, device: DiscoveredDevice) {
        self.bus = bus
        self.backend = backend
        self.connection = connection
        self.device = device
        self.rxBuffer = .allocate(capacity: rxCapacity)
        self.txBuffer = .allocate(capacity: txCapacity)
    }

    deinit {
        connection?.close()
        rxBuffer.deallocate()
        txBuffer.deallocate()
    }

    // MARK: - API pública

    func start() async throws {
        try await bus.perform { try self.openSessionOnQueue() }
    }

    public func close() async {
        _ = try? await bus.perform {
            if self.connection != nil {
                _ = try? self.execute(.closeSession, [], timeout: 3_000)
            }
            self.connection?.close()
            self.connection = nil
        }
    }

    public var isConnected: Bool { connection?.isOpen ?? false }

    public func storages() async throws -> [MTPStorage] {
        try await bus.perform { try self.storagesOnQueue() }
    }

    /// Lista o conteúdo de uma pasta. `onBatch` é chamado a cada lote parcial,
    /// para a interface preencher a lista enquanto o resto ainda carrega.
    public func list(storage: UInt32,
                     parent: UInt32,
                     cancel: CancelFlag? = nil,
                     onBatch: (@Sendable ([MTPObject]) -> Void)? = nil) async throws -> [MTPObject] {
        try await bus.perform { try self.listOnQueue(storage: storage, parent: parent, cancel: cancel, onBatch: onBatch) }
    }

    public func download(_ object: MTPObject,
                         to url: URL,
                         cancel: CancelFlag? = nil,
                         progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        try await bus.perform { try self.downloadOnQueue(object, to: url, cancel: cancel, progress: progress) }
    }

    @discardableResult
    public func upload(fileAt url: URL,
                       named name: String,
                       storage: UInt32,
                       parent: UInt32,
                       cancel: CancelFlag? = nil,
                       progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> UInt32 {
        try await bus.perform {
            try self.uploadOnQueue(url: url, name: name, storage: storage, parent: parent,
                                   cancel: cancel, progress: progress)
        }
    }

    @discardableResult
    public func createFolder(named name: String, storage: UInt32, parent: UInt32) async throws -> UInt32 {
        try await bus.perform { try self.createFolderOnQueue(name: name, storage: storage, parent: parent) }
    }

    public func delete(handle: UInt32) async throws {
        try await bus.perform {
            _ = try self.execute(.deleteObject, [handle, 0], timeout: self.responseTimeout)
        }
    }

    public func rename(handle: UInt32, to newName: String) async throws {
        try await bus.perform { try self.renameOnQueue(handle: handle, to: newName) }
    }

    public func objectInfo(handle: UInt32) async throws -> MTPObject {
        try await bus.perform { try self.objectInfoOnQueue(handle: handle) }
    }

    /// Fecha e reabre a conexão USB. Usado depois de um cancelamento no meio de uma
    /// transferência, quando o endpoint fica com dados pendentes e a sessão perde o sincronismo.
    public func recover() async throws {
        try await bus.perform {
            MTPLog.shared.warn("reiniciando conexão USB após interrupção")
            self.connection?.close()
            self.connection = nil
            self.leftover.removeAll()
            self.connection = try self.backend.connect(to: self.device.id)
            try self.openSessionOnQueue()
        }
    }

    // MARK: - Abertura de sessão

    private func openSessionOnQueue() throws {
        dispatchPrecondition(condition: .onQueue(bus.queue))
        transactionID = 0
        leftover.removeAll()

        info = try deviceInfoOnQueue()
        MTPLog.shared.info("aparelho: \(info.manufacturer) \(info.model) (\(info.deviceVersion))")

        do {
            _ = try execute(.openSession, [sessionID], transaction: 0)
            transactionID = 0
        } catch MTPError.device(.sessionAlreadyOpen) {
            MTPLog.shared.info("sessão MTP já estava aberta")
            transactionID = 0
        }

        friendlyName = (try? deviceFriendlyNameOnQueue()) ?? ""
        if friendlyName.isEmpty { friendlyName = info.model }
    }

    private func deviceInfoOnQueue() throws -> MTPDeviceInfo {
        var data = [UInt8]()
        _ = try receive(.getDeviceInfo, [], transaction: 0) { data.append(contentsOf: $0) }
        var reader = ByteReader(data)
        return try MTPDeviceInfo.parse(&reader)
    }

    private func deviceFriendlyNameOnQueue() throws -> String {
        guard info.devicePropertiesSupported.contains(MTPDeviceProp.deviceFriendlyName),
              info.supports(.getDevicePropValue) else { return "" }
        var data = [UInt8]()
        _ = try receive(.getDevicePropValue, [UInt32(MTPDeviceProp.deviceFriendlyName)]) {
            data.append(contentsOf: $0)
        }
        var reader = ByteReader(data)
        return (try? reader.string()) ?? ""
    }

    // MARK: - Operações

    private func storagesOnQueue() throws -> [MTPStorage] {
        var data = [UInt8]()
        _ = try receive(.getStorageIDs, []) { data.append(contentsOf: $0) }
        var reader = ByteReader(data)
        let ids = try reader.u32Array()

        var storages: [MTPStorage] = []
        for id in ids {
            var raw = [UInt8]()
            do {
                _ = try receive(.getStorageInfo, [id]) { raw.append(contentsOf: $0) }
                var r = ByteReader(raw)
                let storage = try MTPStorage.parse(&r, id: id)
                storages.append(storage)
                MTPLog.shared.info("storage 0x\(String(id, radix: 16)): \(storage.displayName) "
                                 + "\(storage.freeSpace)/\(storage.capacity) bytes livres")
            } catch {
                MTPLog.shared.warn("storage 0x\(String(id, radix: 16)) indisponível: \(error.localizedDescription)")
            }
        }
        return storages
    }

    private func objectInfoOnQueue(handle: UInt32) throws -> MTPObject {
        var raw = [UInt8]()
        _ = try receive(.getObjectInfo, [handle]) { raw.append(contentsOf: $0) }
        var r = ByteReader(raw)
        var object = try MTPObject.parse(&r, handle: handle)
        if object.size < 0 {
            object = object.withSize(largeObjectSizeOnQueue(handle: handle) ?? 0)
        }
        return object
    }

    /// ObjectInfo carrega o tamanho em 32 bits. Para arquivos acima de 4 GiB o valor vem
    /// saturado e o tamanho real precisa ser pedido pela propriedade ObjectSize (64 bits).
    private func largeObjectSizeOnQueue(handle: UInt32) -> Int64? {
        guard info.supports(.getObjectPropValue) else { return nil }
        var raw = [UInt8]()
        do {
            _ = try receive(.getObjectPropValue, [handle, UInt32(MTPObjectProp.objectSize)]) { slice in
                raw.append(contentsOf: slice)
            }
        } catch {
            MTPLog.shared.warn("ObjectSize(\(handle)) indisponível: \(error.localizedDescription)")
            return nil
        }
        var r = ByteReader(raw)
        guard let value = try? r.u64() else { return nil }
        return Int64(clamping: value)
    }

    private func listOnQueue(storage: UInt32,
                             parent: UInt32,
                             cancel: CancelFlag?,
                             onBatch: (([MTPObject]) -> Void)?) throws -> [MTPObject] {
        var data = [UInt8]()
        _ = try receive(.getObjectHandles, [storage, 0, parent]) { data.append(contentsOf: $0) }
        var reader = ByteReader(data)
        let handles = try reader.u32Array()
        MTPLog.shared.debug("GetObjectHandles(storage=0x\(String(storage, radix: 16)), parent=\(parent)) → \(handles.count)")

        var all: [MTPObject] = []
        var batch: [MTPObject] = []
        all.reserveCapacity(handles.count)

        for handle in handles {
            if cancel?.isCancelled == true { throw MTPError.cancelled }
            do {
                let object = try objectInfoOnQueue(handle: handle)
                all.append(object)
                batch.append(object)
            } catch MTPError.deviceGone {
                throw MTPError.deviceGone
            } catch {
                MTPLog.shared.warn("GetObjectInfo(\(handle)) falhou: \(error.localizedDescription)")
            }
            if batch.count >= 64 {
                onBatch?(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { onBatch?(batch) }
        return all
    }

    private func downloadOnQueue(_ object: MTPObject,
                                 to url: URL,
                                 cancel: CancelFlag?,
                                 progress: ((Int64, Int64) -> Void)?) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw MTPError.localIO("Não foi possível criar “\(url.lastPathComponent)”.")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: url) }
        catch { throw MTPError.localIO("Não foi possível escrever em “\(url.path)”: \(error.localizedDescription)") }

        var written: Int64 = 0
        let total = max(object.size, 0)
        var lastReport = Date.distantPast

        do {
            _ = try receive(.getObject, [object.handle], cancel: cancel) { slice in
                handle.write(Data(slice))
                written += Int64(slice.count)
                let now = Date()
                if now.timeIntervalSince(lastReport) > 0.08 {
                    lastReport = now
                    progress?(written, total)
                }
            }
        } catch {
            try? handle.close()
            try? fm.removeItem(at: url)
            throw error
        }
        try? handle.close()
        progress?(written, max(total, written))

        // Preserva a data de modificação do aparelho, como o Finder espera.
        if let modified = object.modified {
            try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        MTPLog.shared.info("baixado \(object.name) (\(written) bytes)")
    }

    private func uploadOnQueue(url: URL,
                               name: String,
                               storage: UInt32,
                               parent: UInt32,
                               cancel: CancelFlag?,
                               progress: ((Int64, Int64) -> Void)?) throws -> UInt32 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = Int64((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        let modified = attrs?[.modificationDate] as? Date ?? Date()

        let objectInfo = makeObjectInfo(storage: storage, parent: parent, name: name,
                                        size: size, isFolder: false, modified: modified)
        let reply = try sendData(.sendObjectInfo, [storage, parent], payload: objectInfo)
        guard reply.count >= 3 else {
            throw MTPError.protocolError("SendObjectInfo não devolveu o handle do novo arquivo")
        }
        let newHandle = reply[2]

        guard let input = FileHandle(forReadingAtPath: url.path) else {
            throw MTPError.localIO("Não foi possível ler “\(url.lastPathComponent)”.")
        }
        defer { try? input.close() }

        var sent: Int64 = 0
        var lastReport = Date.distantPast
        _ = try send(.sendObject, [], payloadSize: size, cancel: cancel,
                     source: { buffer, capacity in
            let chunk = input.readData(ofLength: capacity)
            if chunk.isEmpty { return 0 }
            chunk.copyBytes(to: buffer, count: chunk.count)
            sent += Int64(chunk.count)
            let now = Date()
            if now.timeIntervalSince(lastReport) > 0.08 {
                lastReport = now
                progress?(sent, size)
            }
            return chunk.count
        })
        progress?(size, size)
        MTPLog.shared.info("enviado \(name) (\(size) bytes) → handle \(newHandle)")
        return newHandle
    }

    private func createFolderOnQueue(name: String, storage: UInt32, parent: UInt32) throws -> UInt32 {
        let payload = makeObjectInfo(storage: storage, parent: parent, name: name,
                                     size: 0, isFolder: true, modified: Date())
        let reply = try sendData(.sendObjectInfo, [storage, parent], payload: payload)
        guard reply.count >= 3 else {
            throw MTPError.protocolError("SendObjectInfo não devolveu o handle da nova pasta")
        }
        MTPLog.shared.info("pasta criada: \(name) → handle \(reply[2])")
        return reply[2]
    }

    private func renameOnQueue(handle: UInt32, to newName: String) throws {
        guard info.supports(.setObjectPropValue) else {
            throw MTPError.device(.operationNotSupported)
        }
        var writer = ByteWriter()
        writer.string(newName)
        _ = try sendData(.setObjectPropValue,
                         [handle, UInt32(MTPObjectProp.fileName)],
                         payload: writer.bytes)
    }

    private func makeObjectInfo(storage: UInt32, parent: UInt32, name: String,
                                size: Int64, isFolder: Bool, modified: Date) -> [UInt8] {
        var w = ByteWriter()
        w.u32(storage)
        w.u16(isFolder ? MTPFormat.association : MTPFormat.undefined)
        w.u16(0)                                                   // protection status
        w.u32(size > Int64(UInt32.max) ? 0xFFFF_FFFF : UInt32(size))
        w.u16(0)                                                   // thumb format
        w.u32(0); w.u32(0); w.u32(0)                               // thumb size/w/h
        w.u32(0); w.u32(0); w.u32(0)                               // image w/h/bit depth
        w.u32(parent)
        w.u16(isFolder ? 1 : 0)                                    // association type
        w.u32(0)                                                   // association description
        w.u32(0)                                                   // sequence number
        w.string(name)
        w.string(MTPDate.format(modified))                         // date created
        w.string(MTPDate.format(modified))                         // date modified
        w.string("")                                               // keywords
        return w.bytes
    }

    // MARK: - Camada de transação

    private struct ContainerHeader {
        let length: UInt32
        let type: UInt16
        let code: UInt16
        let transaction: UInt32
    }

    private func requireConnection() throws -> USBConnection {
        guard let connection, connection.isOpen else { throw MTPError.deviceGone }
        return connection
    }

    private func nextTransaction() -> UInt32 {
        transactionID &+= 1
        return transactionID
    }

    private func writeCommand(_ op: MTPOp, _ params: [UInt32], transaction: UInt32) throws {
        let connection = try requireConnection()
        var w = ByteWriter()
        w.u32(UInt32(12 + params.count * 4))
        w.u16(ContainerType.command.rawValue)
        w.u16(op.rawValue)
        w.u32(transaction)
        for p in params { w.u32(p) }
        let bytes = w.bytes
        MTPLog.shared.debug("→ \(op) tx=\(transaction) params=\(params)")
        _ = try bytes.withUnsafeBufferPointer {
            try connection.write($0.baseAddress!, count: bytes.count, timeout: cmdTimeout)
        }
    }

    private func readBlock(timeout: UInt32) throws -> [UInt8] {
        if !leftover.isEmpty {
            let block = leftover
            leftover = []
            return block
        }
        let connection = try requireConnection()
        // Um pacote de tamanho zero é apenas o terminador de uma transferência anterior.
        for _ in 0 ..< 4 {
            let n = try connection.read(into: rxBuffer, capacity: rxCapacity, timeout: timeout)
            if n > 0 { return Array(UnsafeBufferPointer(start: rxBuffer, count: n)) }
        }
        return []
    }

    private func parseHeader(_ block: [UInt8]) throws -> ContainerHeader {
        guard block.count >= 12 else {
            throw MTPError.protocolError("container com apenas \(block.count) bytes")
        }
        var r = ByteReader(block)
        return ContainerHeader(length: try r.u32(), type: try r.u16(),
                               code: try r.u16(), transaction: try r.u32())
    }

    private func responseParams(in block: [UInt8]) -> [UInt32] {
        var r = ByteReader(block)
        r.offset = 12
        var out: [UInt32] = []
        while r.remaining >= 4, let v = try? r.u32() { out.append(v) }
        return out
    }

    private func check(_ code: UInt16) throws {
        guard code != MTPResponse.ok.rawValue else { return }
        if let response = MTPResponse(rawValue: code) { throw MTPError.device(response) }
        throw MTPError.protocolError(String(format: "código de resposta 0x%04X", code))
    }

    private func readResponse(timeout: UInt32) throws -> (code: UInt16, params: [UInt32]) {
        for _ in 0 ..< 8 {
            let block = try readBlock(timeout: timeout)
            if block.isEmpty { continue }
            let header = try parseHeader(block)
            guard header.type == ContainerType.response.rawValue else {
                MTPLog.shared.debug("container tipo \(header.type) descartado enquanto aguardava resposta")
                continue
            }
            MTPLog.shared.debug("← resposta 0x\(String(header.code, radix: 16)) tx=\(header.transaction)")
            return (header.code, responseParams(in: block))
        }
        throw MTPError.protocolError("o dispositivo não enviou resposta")
    }

    /// Operação sem fase de dados.
    @discardableResult
    private func execute(_ op: MTPOp, _ params: [UInt32],
                         transaction: UInt32? = nil,
                         timeout: UInt32? = nil) throws -> [UInt32] {
        let tx = transaction ?? nextTransaction()
        try writeCommand(op, params, transaction: tx)
        let reply = try readResponse(timeout: timeout ?? responseTimeout)
        try check(reply.code)
        return reply.params
    }

    /// Operação com fase de dados do aparelho para o Mac.
    @discardableResult
    private func receive(_ op: MTPOp, _ params: [UInt32],
                         transaction: UInt32? = nil,
                         cancel: CancelFlag? = nil,
                         sink: (ArraySlice<UInt8>) throws -> Void) throws -> [UInt32] {
        let tx = transaction ?? nextTransaction()
        try writeCommand(op, params, transaction: tx)

        var block = try readBlock(timeout: dataTimeout)
        guard !block.isEmpty else { throw MTPError.protocolError("sem resposta para \(op)") }
        let header = try parseHeader(block)

        // O aparelho pode recusar a operação sem enviar dado nenhum.
        if header.type == ContainerType.response.rawValue {
            try check(header.code)
            return responseParams(in: block)
        }
        guard header.type == ContainerType.data.rawValue else {
            throw MTPError.protocolError("esperava dados de \(op), veio container tipo \(header.type)")
        }

        // 0xFFFFFFFF = comprimento indefinido (arquivos acima de 4 GiB).
        let undefinedLength = header.length == 0xFFFF_FFFF
        let expected: Int64 = undefinedLength ? Int64.max : Int64(header.length) - 12
        var received: Int64 = 0

        func consume(_ data: ArraySlice<UInt8>) throws {
            var slice = data
            if !undefinedLength {
                let room = Int(expected - received)
                if slice.count > room {
                    // O container de resposta veio grudado no fim dos dados.
                    leftover = Array(slice.dropFirst(room))
                    slice = slice.prefix(room)
                }
            }
            if !slice.isEmpty {
                try sink(slice)
                received += Int64(slice.count)
            }
        }

        try consume(block.dropFirst(12))
        var reachedEnd = undefinedLength ? block.count < rxCapacity : received >= expected

        while !reachedEnd {
            if cancel?.isCancelled == true { throw MTPError.cancelled }
            block = try readBlock(timeout: dataTimeout)
            if block.isEmpty { break }
            let full = block.count >= rxCapacity
            try consume(block[block.startIndex...])
            reachedEnd = undefinedLength ? !full : received >= expected
        }

        if !undefinedLength && received < expected {
            throw MTPError.protocolError("transferência incompleta (\(received)/\(expected) bytes)")
        }

        let reply = try readResponse(timeout: responseTimeout)
        try check(reply.code)
        return reply.params
    }

    /// Operação com fase de dados do Mac para o aparelho, a partir de memória.
    @discardableResult
    private func sendData(_ op: MTPOp, _ params: [UInt32], payload: [UInt8]) throws -> [UInt32] {
        var offset = 0
        return try send(op, params, payloadSize: Int64(payload.count), cancel: nil) { buffer, capacity in
            let n = min(capacity, payload.count - offset)
            if n <= 0 { return 0 }
            payload.withUnsafeBufferPointer { src in
                buffer.update(from: src.baseAddress!.advanced(by: offset), count: n)
            }
            offset += n
            return n
        }
    }

    /// Operação com fase de dados do Mac para o aparelho, em streaming.
    ///
    /// O cabeçalho do container **precisa** viajar no mesmo pacote que o início do
    /// payload: um write isolado de 12 bytes é um pacote curto e encerraria a fase
    /// de dados antes da hora.
    @discardableResult
    private func send(_ op: MTPOp, _ params: [UInt32],
                      payloadSize: Int64,
                      cancel: CancelFlag?,
                      source: (UnsafeMutablePointer<UInt8>, Int) throws -> Int) throws -> [UInt32] {
        let connection = try requireConnection()
        let tx = nextTransaction()
        try writeCommand(op, params, transaction: tx)

        let maxPacket = connection.interface.maxPacketOut
        let undefinedLength = payloadSize > Int64(UInt32.max) - 12
        let declared: UInt32 = undefinedLength ? 0xFFFF_FFFF : UInt32(12 + payloadSize)

        var head = ByteWriter()
        head.u32(declared)
        head.u16(ContainerType.data.rawValue)
        head.u16(op.rawValue)
        head.u32(tx)
        head.bytes.withUnsafeBufferPointer { txBuffer.update(from: $0.baseAddress!, count: 12) }

        var totalWritten = 0
        var payloadWritten: Int64 = 0
        var filled = 12
        var eof = false

        while true {
            if cancel?.isCancelled == true { throw MTPError.cancelled }

            // Completa o buffer até a capacidade para que todo write intermediário
            // seja múltiplo do tamanho de pacote do endpoint.
            while filled < txCapacity && !eof {
                let n = try source(txBuffer.advanced(by: filled), txCapacity - filled)
                if n <= 0 { eof = true; break }
                filled += n
                payloadWritten += Int64(n)
            }

            if filled == 0 { break }
            var offset = 0
            while offset < filled {
                let n = try connection.write(txBuffer.advanced(by: offset),
                                             count: filled - offset,
                                             timeout: dataTimeout)
                if n <= 0 { throw MTPError.transfer("envio", 0) }
                offset += n
            }
            totalWritten += filled
            filled = 0
            if eof { break }
        }

        // Sem pacote curto no fim, o aparelho fica esperando mais dados.
        if totalWritten % maxPacket == 0 {
            var zero: UInt8 = 0
            _ = try connection.write(&zero, count: 0, timeout: cmdTimeout)
        }

        if !undefinedLength && payloadWritten != payloadSize {
            MTPLog.shared.warn("enviados \(payloadWritten) de \(payloadSize) bytes anunciados")
        }

        let reply = try readResponse(timeout: responseTimeout)
        try check(reply.code)
        return reply.params
    }
}
