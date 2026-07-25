import Foundation
import MTPKit

// Modo de pré-visualização (`--demo`): popula a interface com dados fictícios para
// conferir o layout sem nenhum aparelho conectado.
extension AppModel {
    func injectDemoData() {
        let storage = MTPStorage(id: 0x10001, label: "Armazenamento interno", volumeIdentifier: "",
                                 capacity: 128_000_000_000, freeSpace: 42_300_000_000,
                                 isReadOnly: false, isRemovable: false)
        let sd = MTPStorage(id: 0x20001, label: "Cartão SD", volumeIdentifier: "",
                            capacity: 64_000_000_000, freeSpace: 3_100_000_000,
                            isReadOnly: false, isRemovable: true)
        let now = Date()
        let objects: [MTPObject] = [
            .init(handle: 1, storageID: storage.id, parent: 0xFFFFFFFF, name: "DCIM",
                  format: 0x3001, size: 0, modified: now, created: now),
            .init(handle: 2, storageID: storage.id, parent: 0xFFFFFFFF, name: "Download",
                  format: 0x3001, size: 0, modified: now, created: now),
            .init(handle: 3, storageID: storage.id, parent: 0xFFFFFFFF, name: "WhatsApp",
                  format: 0x3001, size: 0, modified: now, created: now),
            .init(handle: 4, storageID: storage.id, parent: 0xFFFFFFFF, name: "IMG_20260714_183245.jpg",
                  format: 0x3801, size: 4_812_331, modified: now, created: now),
            .init(handle: 5, storageID: storage.id, parent: 0xFFFFFFFF, name: "viagem-praia.mp4",
                  format: 0x300C, size: 1_932_884_112, modified: now, created: now),
            .init(handle: 6, storageID: storage.id, parent: 0xFFFFFFFF, name: "contrato-assinado.pdf",
                  format: 0x3000, size: 284_112, modified: now, created: now),
            .init(handle: 7, storageID: storage.id, parent: 0xFFFFFFFF, name: "notas.txt",
                  format: 0x3004, size: 1_204, modified: now, created: now)
        ]
        var transfer = TransferItem(direction: .download, title: "viagem-praia.mp4")
        transfer.total = 1_932_884_112
        transfer.completed = 1_204_881_000
        transfer.status = .running
        transfer.startedAt = Date().addingTimeInterval(-47)
        transfer.bytesPerSecond = 25_600_000
        transfer.detail = "3 de 7 · viagem-praia.mp4"

        applyDemo(state: "Galaxy S24 de Olavo", summary: "Samsung SM-S921B",
                  storages: [storage, sd], items: objects, transfer: transfer)
    }
}
