import AppKit
import Combine
import Foundation
import MTPKit

// MARK: - Transferências

struct TransferItem: Identifiable {
    enum Direction { case download, upload }
    enum Status: Equatable {
        case queued, preparing, running, finished, cancelled
        case failed(String)
    }

    let id = UUID()
    let direction: Direction
    var title: String
    var detail: String = ""
    var total: Int64 = 0
    var completed: Int64 = 0
    var status: Status = .queued
    var startedAt: Date?
    var finishedAt: Date?
    var bytesPerSecond: Double = 0
    let cancelFlag = CancelFlag()

    /// Tempo decorrido; congela quando a transferência termina.
    var duration: TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }

    var isActive: Bool {
        switch status {
        case .queued, .preparing, .running: return true
        default: return false
        }
    }

    var secondsRemaining: Double {
        guard bytesPerSecond > 1, total > completed else { return 0 }
        return Double(total - completed) / bytesPerSecond
    }
}

// MARK: - Modelo principal

@MainActor
final class AppModel: ObservableObject {

    enum ConnectionState: Equatable {
        case searching
        case chargingOnly(String)
        case connecting(String)
        case connected(String)
        case failed(String)

        var isConnected: Bool { if case .connected = self { return true }; return false }
    }

    enum SheetKind: Identifiable {
        case newFolder
        case rename(MTPObject)
        case diagnostics

        var id: String {
            switch self {
            case .newFolder: return "newFolder"
            case .rename(let o): return "rename-\(o.handle)"
            case .diagnostics: return "diagnostics"
            }
        }
    }

    // Conexão
    @Published private(set) var state: ConnectionState = .searching
    @Published private(set) var deviceSummary = ""

    // Conteúdo
    @Published private(set) var storages: [MTPStorage] = []
    @Published var selectedStorage: UInt32?
    @Published private(set) var path: [MTPObject] = []
    @Published private(set) var items: [MTPObject] = []
    @Published private(set) var isListing = false
    @Published var selection = Set<UInt32>()
    @Published var searchText = ""

    // Transferências e avisos
    @Published private(set) var transfers: [TransferItem] = []
    /// Transferência exibida na barra de progresso do rodapé.
    @Published private(set) var bannerTransferID: UUID?
    /// Verdadeiro quando a última falha foi outro processo segurando a interface USB.
    @Published private(set) var interfaceLocked = false
    @Published var errorMessage: String?
    @Published var sheet: SheetKind?

    // Preferências
    @Published var downloadFolder: URL {
        didSet { UserDefaults.standard.set(downloadFolder.path, forKey: "downloadFolder") }
    }
    @Published var verboseLogging: Bool {
        didSet {
            MTPLog.shared.verbose = verboseLogging
            UserDefaults.standard.set(verboseLogging, forKey: "verboseLogging")
        }
    }

    private var session: MTPSession?
    private var monitor: Task<Void, Never>?
    private var jobRunner: Task<Void, Never>?
    private var jobs: [Job] = []
    private var listGeneration = 0
    private var listCancel = CancelFlag()
    private var retryAfter: Date?
    private var backStack: [(UInt32, [MTPObject])] = []
    private var forwardStack: [(UInt32, [MTPObject])] = []
    private var bannerClearTask: Task<Void, Never>?

    private enum Job {
        case download(transfer: UUID, objects: [MTPObject], destination: URL,
                      openAfter: Bool, completion: ((Result<[URL], Error>) -> Void)?)
        case upload(transfer: UUID, urls: [URL], storage: UInt32, parent: UInt32)

        var transferID: UUID {
            switch self {
            case .download(let id, _, _, _, _): return id
            case .upload(let id, _, _, _): return id
            }
        }
    }

    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "downloadFolder")
        downloadFolder = saved.map(URL.init(fileURLWithPath:))
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        verboseLogging = defaults.bool(forKey: "verboseLogging")
        MTPLog.shared.verbose = verboseLogging
    }

    /// Usado apenas pelo modo `--demo`, que preenche a interface com dados fictícios.
    func applyDemo(state name: String, summary: String, storages: [MTPStorage],
                   items: [MTPObject], transfer: TransferItem? = nil) {
        if let transfer {
            transfers = [transfer]
            bannerTransferID = transfer.id
        }
        self.state = .connected(name)
        self.deviceSummary = summary
        self.storages = storages
        self.selectedStorage = storages.first?.id
        self.items = items
        self.isListing = false
    }

    // MARK: - Ciclo de vida

    func start() {
        if CommandLine.arguments.contains("--demo") { injectDemoData(); return }
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        let session = self.session
        self.session = nil
        Task { await session?.close() }
    }

    // MARK: - Detecção e conexão

    private func poll() async {
        if let session, session.isConnected {
            if await !MTPBus.shared.isPresent(session.device.id) {
                await handleDisconnect()
            }
            return
        }
        if case .connecting = state { return }
        if let retryAfter, Date() < retryAfter { return }

        let devices = await MTPBus.shared.scan()
        guard let target = devices.first(where: { $0.hasMTP }) else {
            if let charging = devices.first {
                state = .chargingOnly(charging.displayName)
            } else if !state.isConnected {
                state = .searching
            }
            return
        }
        await connect(to: target)
    }

    private func connect(to device: DiscoveredDevice) async {
        state = .connecting(device.displayName)
        do {
            let session = try await MTPBus.shared.openSession(with: device)
            self.session = session
            retryAfter = nil
            interfaceLocked = false
            let name = session.friendlyName.isEmpty ? device.displayName : session.friendlyName
            state = .connected(name)
            deviceSummary = [session.info.manufacturer, session.info.model]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            MTPLog.shared.info("conectado a \(name)")
            await reloadStorages()
        } catch {
            session = nil
            interfaceLocked = (error as? MTPError)?.isInterfaceLocked ?? false
            state = .failed(error.localizedDescription)
            // Evita ficar martelando o aparelho quando outro programa segura a interface.
            retryAfter = Date().addingTimeInterval(5)
            MTPLog.shared.error("falha ao conectar: \(error.localizedDescription)")
        }
    }

    private func handleDisconnect() async {
        MTPLog.shared.warn("dispositivo removido")
        let session = self.session
        self.session = nil
        Task { await session?.close() }
        state = .searching
        storages = []
        items = []
        path = []
        selectedStorage = nil
        selection = []
        backStack = []
        forwardStack = []
        for index in transfers.indices where transfers[index].isActive {
            transfers[index].status = .failed("Dispositivo desconectado")
        }
    }

    func reconnect() {
        retryAfter = nil
        Task {
            let session = self.session
            self.session = nil
            await session?.close()
            state = .searching
            await poll()
        }
    }

    // MARK: - Navegação

    var currentParent: UInt32 { path.last?.handle ?? MTPHandle.root }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { !path.isEmpty }

    func reloadStorages() async {
        guard let session else { return }
        do {
            let list = try await session.storages()
            storages = list
            if selectedStorage == nil || !list.contains(where: { $0.id == selectedStorage }) {
                selectedStorage = list.first?.id
            }
            path = []
            backStack = []
            forwardStack = []
            await loadCurrentFolder()
        } catch {
            report(error)
        }
    }

    func selectStorage(_ id: UInt32) {
        guard id != selectedStorage else { return }
        pushHistory()
        selectedStorage = id
        path = []
        Task { await loadCurrentFolder() }
    }

    func open(_ object: MTPObject) {
        if object.isFolder {
            pushHistory()
            path.append(object)
            selection = []
            Task { await loadCurrentFolder() }
        } else {
            openLocally(object)
        }
    }

    func navigate(toPathIndex index: Int) {
        guard index <= path.count else { return }
        pushHistory()
        path = Array(path.prefix(index))
        selection = []
        Task { await loadCurrentFolder() }
    }

    func goUp() {
        guard !path.isEmpty else { return }
        navigate(toPathIndex: path.count - 1)
    }

    func goBack() {
        guard let previous = backStack.popLast(), let storage = selectedStorage else { return }
        forwardStack.append((storage, path))
        selectedStorage = previous.0
        path = previous.1
        selection = []
        Task { await loadCurrentFolder() }
    }

    func goForward() {
        guard let next = forwardStack.popLast(), let storage = selectedStorage else { return }
        backStack.append((storage, path))
        selectedStorage = next.0
        path = next.1
        selection = []
        Task { await loadCurrentFolder() }
    }

    private func pushHistory() {
        guard let storage = selectedStorage else { return }
        backStack.append((storage, path))
        if backStack.count > 100 { backStack.removeFirst() }
        forwardStack.removeAll()
    }

    // MARK: - Listagem

    func refresh() {
        Task { await loadCurrentFolder() }
    }

    private func loadCurrentFolder() async {
        guard let session, let storage = selectedStorage else {
            items = []
            return
        }
        listCancel.cancel()
        listCancel = CancelFlag()
        listGeneration &+= 1
        let generation = listGeneration
        let cancel = listCancel

        items = []
        isListing = true
        let parent = currentParent

        do {
            let all = try await session.list(storage: storage, parent: parent, cancel: cancel) { [weak self] batch in
                Task { @MainActor in
                    self?.appendBatch(batch, generation: generation)
                }
            }
            guard generation == listGeneration else { return }
            items = all
            isListing = false
        } catch MTPError.cancelled {
            // Outra navegação assumiu o lugar desta.
        } catch {
            guard generation == listGeneration else { return }
            isListing = false
            report(error)
        }
    }

    private func appendBatch(_ batch: [MTPObject], generation: Int) {
        guard generation == listGeneration else { return }
        items.append(contentsOf: batch)
    }

    var visibleItems: [MTPObject] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { $0.name.lowercased().contains(query) }
    }

    func object(with handle: UInt32) -> MTPObject? {
        items.first { $0.handle == handle }
    }

    var selectedObjects: [MTPObject] {
        items.filter { selection.contains($0.handle) }
    }

    // MARK: - Ações sobre arquivos

    func downloadSelected() {
        enqueueDownloadWithPanel(selectedObjects)
    }

    func enqueueDownloadWithPanel(_ objects: [MTPObject]) {
        guard !objects.isEmpty else { return }
        chooseFolder { [weak self] destination in
            self?.enqueueDownload(objects, to: destination)
        }
    }

    func downloadSelectedToDefaultFolder() {
        let objects = selectedObjects
        guard !objects.isEmpty else { return }
        enqueueDownload(objects, to: downloadFolder)
    }

    func enqueueDownload(_ objects: [MTPObject],
                         to destination: URL,
                         openAfter: Bool = false,
                         completion: ((Result<[URL], Error>) -> Void)? = nil) {
        guard !objects.isEmpty else { return }
        let title = objects.count == 1
            ? objects[0].name
            : "\(objects.count) itens"
        var transfer = TransferItem(direction: .download, title: title)
        transfer.detail = "para \(destination.lastPathComponent)"
        transfers.append(transfer)
        jobs.append(.download(transfer: transfer.id, objects: objects, destination: destination,
                              openAfter: openAfter, completion: completion))
        runJobs()
    }

    /// Suporte ao arrastar um item da lista direto para o Finder: o arquivo só é
    /// baixado quando o usuário solta o mouse, e o Finder recebe a URL local pronta.
    func provideFileForDrag(_ object: MTPObject, completion: @escaping (Result<URL, Error>) -> Void) {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitchMac", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        enqueueDownload([object], to: staging) { result in
            switch result {
            case .success(let urls):
                if let first = urls.first { completion(.success(first)) }
                else { completion(.failure(MTPError.localIO("Nada foi baixado."))) }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func uploadFromPicker() {
        guard let storage = selectedStorage else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Enviar"
        panel.message = "Escolha os arquivos ou pastas para enviar ao aparelho"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        enqueueUpload(panel.urls, storage: storage, parent: currentParent)
    }

    func enqueueUpload(_ urls: [URL], storage: UInt32, parent: UInt32) {
        guard !urls.isEmpty else { return }
        let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) itens"
        var transfer = TransferItem(direction: .upload, title: title)
        transfer.detail = "para o aparelho"
        transfers.append(transfer)
        jobs.append(.upload(transfer: transfer.id, urls: urls, storage: storage, parent: parent))
        runJobs()
    }

    func openLocally(_ object: MTPObject) {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitchMac", isDirectory: true)
            .appendingPathComponent("\(object.handle)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        enqueueDownload([object], to: cache, openAfter: true)
    }

    func deleteSelected() {
        let objects = selectedObjects
        guard !objects.isEmpty, let session else { return }

        let alert = NSAlert()
        alert.messageText = objects.count == 1
            ? "Apagar “\(objects[0].name)” do aparelho?"
            : "Apagar \(objects.count) itens do aparelho?"
        alert.informativeText = "Os itens serão removidos do dispositivo Android. "
                              + "Isso não pode ser desfeito."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Apagar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            for object in objects {
                do { try await session.delete(handle: object.handle) }
                catch { report(error, prefix: "Não foi possível apagar “\(object.name)”") }
            }
            selection = []
            await loadCurrentFolder()
            await reloadStorageUsage()
        }
    }

    func createFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session, let storage = selectedStorage else { return }
        Task {
            do {
                _ = try await session.createFolder(named: trimmed, storage: storage, parent: currentParent)
                await loadCurrentFolder()
            } catch {
                report(error, prefix: "Não foi possível criar a pasta")
            }
        }
    }

    func rename(_ object: MTPObject, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != object.name, let session else { return }
        Task {
            do {
                try await session.rename(handle: object.handle, to: trimmed)
                await loadCurrentFolder()
            } catch {
                report(error, prefix: "Não foi possível renomear “\(object.name)”")
            }
        }
    }

    private func reloadStorageUsage() async {
        guard let session else { return }
        if let updated = try? await session.storages() { storages = updated }
    }

    // MARK: - Fila de transferências

    func cancelTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].cancelFlag.cancel()
        if case .queued = transfers[index].status {
            transfers[index].status = .cancelled
            jobs.removeAll { job in
                switch job {
                case .download(let t, _, _, _, _): return t == id
                case .upload(let t, _, _, _): return t == id
                }
            }
        }
    }

    func clearFinishedTransfers() {
        transfers.removeAll { !$0.isActive }
    }

    var activeTransferCount: Int { transfers.filter(\.isActive).count }

    private func runJobs() {
        guard jobRunner == nil else { return }
        jobRunner = Task { @MainActor [weak self] in
            while let model = self, !model.jobs.isEmpty {
                let job = model.jobs.removeFirst()
                await model.perform(job)
            }
            self?.jobRunner = nil
        }
    }

    private func perform(_ job: Job) async {
        showBanner(job.transferID)
        defer {
            update(job.transferID) { if $0.finishedAt == nil { $0.finishedAt = Date() } }
            scheduleBannerClear(job.transferID)
        }
        switch job {
        case .download(let id, let objects, let destination, let openAfter, let completion):
            await runDownload(id: id, objects: objects, destination: destination,
                              openAfter: openAfter, completion: completion)
        case .upload(let id, let urls, let storage, let parent):
            await runUpload(id: id, urls: urls, storage: storage, parent: parent)
        }
    }

    var bannerTransfer: TransferItem? {
        guard let bannerTransferID else { return nil }
        return transfers.first { $0.id == bannerTransferID }
    }

    var queuedTransferCount: Int {
        transfers.filter { if case .queued = $0.status { return true }; return false }.count
    }

    private func showBanner(_ id: UUID) {
        bannerClearTask?.cancel()
        bannerClearTask = nil
        bannerTransferID = id
    }

    private func scheduleBannerClear(_ id: UUID) {
        bannerClearTask?.cancel()
        bannerClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.bannerTransferID == id else { return }
            self.bannerTransferID = nil
        }
    }

    /// Encerra os serviços do macOS que reservam a interface e tenta conectar de novo.
    func releaseInterfaceAndRetry() {
        Task {
            // O macOS relança o serviço na hora, então é uma corrida: encerramos e
            // tentamos reivindicar a interface antes que ele a pegue de novo.
            for round in 1 ... 3 {
                let released = InterfaceRelease.release()
                MTPLog.shared.info("liberação da interface (rodada \(round)): \(released) processo(s) encerrado(s)")
                interfaceLocked = false
                retryAfter = nil
                state = .searching
                await poll()
                if state.isConnected { return }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if !state.isConnected {
                MTPLog.shared.warn("a interface continuou ocupada depois de 3 tentativas")
            }
        }
    }

    private func update(_ id: UUID, _ mutate: (inout TransferItem) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        mutate(&transfers[index])
    }

    private func transfer(_ id: UUID) -> TransferItem? {
        transfers.first { $0.id == id }
    }

    // MARK: Download

    private func runDownload(id: UUID,
                             objects: [MTPObject],
                             destination: URL,
                             openAfter: Bool,
                             completion: ((Result<[URL], Error>) -> Void)?) async {
        guard let session else {
            let error = MTPError.noDevice
            update(id) { $0.status = .failed(error.localizedDescription) }
            completion?(.failure(error))
            return
        }
        guard let cancel = transfer(id)?.cancelFlag, !cancel.isCancelled else {
            update(id) { $0.status = .cancelled }
            completion?(.failure(MTPError.cancelled))
            return
        }

        update(id) { $0.status = .preparing; $0.startedAt = Date() }

        var plan: [(object: MTPObject, url: URL)] = []
        var roots: [URL] = []
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for object in objects {
                let built = try await buildDownloadPlan(for: object, into: destination, session: session)
                roots.append(built.root)
                plan += built.files
            }
        } catch {
            update(id) { $0.status = .failed(error.localizedDescription) }
            completion?(.failure(error))
            return
        }

        let total = plan.reduce(Int64(0)) { $0 + max($1.object.size, 0) }
        update(id) { $0.total = total; $0.status = .running }

        var done: Int64 = 0
        for (index, entry) in plan.enumerated() {
            if cancel.isCancelled { break }
            update(id) {
                $0.detail = plan.count == 1
                    ? "para \(destination.lastPathComponent)"
                    : "\(index + 1) de \(plan.count) · \(entry.object.name)"
            }
            let base = done
            do {
                try await session.download(entry.object, to: entry.url, cancel: cancel) { [weak self] sent, _ in
                    Task { @MainActor in
                        self?.update(id) { item in
                            item.completed = base + sent
                            if let start = item.startedAt {
                                let elapsed = Date().timeIntervalSince(start)
                                if elapsed > 0.5 { item.bytesPerSecond = Double(item.completed) / elapsed }
                            }
                        }
                    }
                }
                done += max(entry.object.size, 0)
                update(id) { $0.completed = done }
            } catch MTPError.cancelled {
                break
            } catch {
                update(id) { $0.status = .failed(error.localizedDescription) }
                MTPLog.shared.error("download de \(entry.object.name) falhou: \(error.localizedDescription)")
                completion?(.failure(error))
                await recoverAfterInterruption()
                return
            }
        }

        if cancel.isCancelled {
            update(id) { $0.status = .cancelled }
            completion?(.failure(MTPError.cancelled))
            await recoverAfterInterruption()
            return
        }

        update(id) { $0.status = .finished; $0.completed = max($0.total, $0.completed) }
        completion?(.success(roots))
        if openAfter, let first = plan.first {
            NSWorkspace.shared.open(first.url)
        }
    }

    private func buildDownloadPlan(
        for object: MTPObject,
        into directory: URL,
        session: MTPSession
    ) async throws -> (root: URL, files: [(object: MTPObject, url: URL)]) {
        guard object.isFolder else {
            let url = uniqueDestination(in: directory, name: object.name)
            return (url, [(object, url)])
        }
        let subdirectory = uniqueDestination(in: directory, name: object.name)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let children = try await session.list(storage: object.storageID, parent: object.handle)
        var files: [(object: MTPObject, url: URL)] = []
        for child in children {
            files += try await buildDownloadPlan(for: child, into: subdirectory, session: session).files
        }
        return (subdirectory, files)
    }

    // MARK: Upload

    private func runUpload(id: UUID, urls: [URL], storage: UInt32, parent: UInt32) async {
        guard let session else {
            update(id) { $0.status = .failed("Sem conexão com o aparelho") }
            return
        }
        guard let cancel = transfer(id)?.cancelFlag, !cancel.isCancelled else {
            update(id) { $0.status = .cancelled }
            return
        }

        update(id) { $0.status = .preparing; $0.startedAt = Date() }
        let total = urls.reduce(Int64(0)) { $0 + localSize(of: $1) }
        update(id) { $0.total = total; $0.status = .running }

        var done: Int64 = 0
        do {
            for url in urls {
                if cancel.isCancelled { break }
                try await uploadTree(url: url, storage: storage, parent: parent, session: session,
                                     transfer: id, cancel: cancel, done: &done)
            }
        } catch MTPError.cancelled {
            update(id) { $0.status = .cancelled }
            await recoverAfterInterruption()
            await loadCurrentFolder()
            return
        } catch {
            update(id) { $0.status = .failed(error.localizedDescription) }
            MTPLog.shared.error("envio falhou: \(error.localizedDescription)")
            await recoverAfterInterruption()
            await loadCurrentFolder()
            return
        }

        if cancel.isCancelled {
            update(id) { $0.status = .cancelled }
            await recoverAfterInterruption()
        } else {
            update(id) { $0.status = .finished; $0.completed = max($0.total, $0.completed) }
        }
        await loadCurrentFolder()
        await reloadStorageUsage()
    }

    private func uploadTree(url: URL,
                            storage: UInt32,
                            parent: UInt32,
                            session: MTPSession,
                            transfer id: UUID,
                            cancel: CancelFlag,
                            done: inout Int64) async throws {
        if cancel.isCancelled { throw MTPError.cancelled }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            let handle = try await session.createFolder(named: url.lastPathComponent,
                                                        storage: storage, parent: parent)
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
            for child in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try await uploadTree(url: child, storage: storage, parent: handle, session: session,
                                     transfer: id, cancel: cancel, done: &done)
            }
            return
        }

        let size = localSize(of: url)
        let base = done
        update(id) { $0.detail = url.lastPathComponent }
        try await session.upload(fileAt: url, named: url.lastPathComponent,
                                 storage: storage, parent: parent, cancel: cancel) { [weak self] sent, _ in
            Task { @MainActor in
                self?.update(id) { item in
                    item.completed = base + sent
                    if let start = item.startedAt {
                        let elapsed = Date().timeIntervalSince(start)
                        if elapsed > 0.5 { item.bytesPerSecond = Double(item.completed) / elapsed }
                    }
                }
            }
        }
        done = base + size
        update(id) { $0.completed = done }
    }

    private func localSize(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return contents.reduce(Int64(0)) { $0 + localSize(of: $1) }
    }

    /// Depois de um cancelamento no meio da fase de dados o endpoint fica com bytes
    /// pendentes; reabrir a conexão é mais barato e mais seguro do que drenar tudo.
    private func recoverAfterInterruption() async {
        guard let session else { return }
        do { try await session.recover() }
        catch {
            MTPLog.shared.error("não foi possível reiniciar a sessão: \(error.localizedDescription)")
            await handleDisconnect()
        }
    }

    // MARK: - Utilidades

    private func chooseFolder(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = downloadFolder
        panel.prompt = "Baixar"
        panel.message = "Escolha onde salvar"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        completion(url)
    }

    func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = downloadFolder
        panel.prompt = "Usar esta pasta"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloadFolder = url
    }

    private func report(_ error: Error, prefix: String? = nil) {
        let text = error.localizedDescription
        errorMessage = prefix.map { "\($0): \(text)" } ?? text
        MTPLog.shared.error(errorMessage ?? text)
    }
}
