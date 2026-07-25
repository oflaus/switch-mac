import Foundation
import MTPKit

/// Modo `--probe`: conecta, lista a raiz e tenta entrar na primeira pasta, imprimindo
/// tudo que vai e volta. É a ferramenta para investigar um aparelho que se comporta
/// fora do padrão sem precisar de depurador.
enum Probe {

    static func run() async {
        MTPLog.shared.verbose = true
        MTPLog.shared.onEntry = { entry in
            FileHandle.standardError.write(Data("    · \(entry.message)\n".utf8))
        }

        let devices = await MTPBus.shared.scan()
        guard let target = devices.first(where: { $0.hasMTP }) else {
            print("nenhum aparelho em modo MTP")
            return
        }
        print("aparelho: \(target.displayName) [\(target.id)]")

        do {
            let session = try await MTPBus.shared.openSession(with: target)
            print("sessão aberta — \(session.info.manufacturer) / \(session.info.model) / \(session.info.deviceVersion)")
            print("operações suportadas: " + session.info.operationsSupported
                .sorted()
                .map { String(format: "0x%04X", $0) }
                .joined(separator: " "))

            let storages = try await session.storages()
            print("\n=== armazenamentos ===")
            for storage in storages {
                print(String(format: "  id=0x%08X  %@", storage.id, storage.displayName))
            }
            guard let first = storages.first else { return }

            print("\n=== raiz de \(first.displayName) ===")
            let root = try await session.list(storage: first.id, parent: MTPHandle.root)
            for object in root.prefix(60) {
                print(String(format: "  handle=0x%08X fmt=0x%04X parent=0x%08X storage=0x%08X %@ %@",
                             object.handle, object.format, object.parent, object.storageID,
                             object.isFolder ? "[pasta]" : "[arqui]", object.name))
            }

            guard let folder = root.first(where: { $0.isFolder && !$0.name.hasPrefix(".") }) else {
                print("nenhuma pasta na raiz para testar")
                await session.close()
                return
            }

            // Tentativa 1: storage escolhido na barra lateral (é o que o app faz hoje).
            print(String(format: "\n=== entrando em \"%@\" — storage=0x%08X parent=0x%08X ===",
                         folder.name, first.id, folder.handle))
            await attempt(session: session, storage: first.id, parent: folder.handle)

            // Tentativa 2: storage informado pelo próprio objeto.
            if folder.storageID != first.id {
                print(String(format: "\n=== mesma pasta com storage do objeto 0x%08X ===", folder.storageID))
                await attempt(session: session, storage: folder.storageID, parent: folder.handle)
            }

            // Tentativa 3: storage "todos" (0xFFFFFFFF), aceito por alguns responders.
            print("\n=== mesma pasta com storage=0xFFFFFFFF ===")
            await attempt(session: session, storage: 0xFFFF_FFFF, parent: folder.handle)

            await session.close()
        } catch {
            print("ERRO: \(error.localizedDescription)")
        }
    }

    private static func attempt(session: MTPSession, storage: UInt32, parent: UInt32) async {
        do {
            let children = try await session.list(storage: storage, parent: parent)
            print("  → \(children.count) itens")
            for child in children.prefix(25) {
                print("     \(child.isFolder ? "[d]" : "[f]") \(child.name)")
            }
        } catch {
            print("  → FALHOU: \(error.localizedDescription)")
        }
    }
}
