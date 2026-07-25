import AppKit
import MTPKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sortOrder: [KeyPathComparator<MTPObject>] = [KeyPathComparator(\.name)]
    @State private var isDropTargeted = false

    private var rows: [MTPObject] {
        let sorted = model.visibleItems.sorted(using: sortOrder)
        // Pastas sempre no topo, como no Finder.
        return sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
    }

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar()
            Divider()
            content
            Divider()
            statusBar
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let storage = model.selectedStorage, model.state.isConnected else { return false }
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.enqueueUpload(files, storage: storage, parent: model.currentParent)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            table
            if model.items.isEmpty && model.isListing {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Lendo a pasta no aparelho…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            } else if rows.isEmpty && !model.isListing {
                emptyState
            }
        }
    }

    private var table: some View {
        Table(rows, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Nome", value: \.name) { object in
                NameCell(object: object)
            }
            .width(min: 240, ideal: 400)

            TableColumn("Tamanho", value: \.size) { object in
                Text(object.isFolder ? "—" : Format.bytes(object.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100, max: 140)

            TableColumn("Tipo") { object in
                Text(object.kindDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 150)

            TableColumn("Modificado", value: \.modifiedSortKey) { object in
                Text(Format.date(object.modified))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 140, ideal: 190)
        }
        .contextMenu(forSelectionType: MTPObject.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            // Duplo clique / Enter
            guard let handle = ids.first, let object = model.object(with: handle) else { return }
            model.open(object)
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<MTPObject.ID>) -> some View {
        let objects = ids.compactMap { model.object(with: $0) }
        if objects.isEmpty {
            Button("Nova pasta") { model.sheet = .newFolder }
            Button("Enviar arquivos para cá…") { model.uploadFromPicker() }
            Divider()
            Button("Atualizar") { model.refresh() }
        } else {
            if objects.count == 1, let object = objects.first {
                Button(object.isFolder ? "Abrir" : "Abrir no Mac") { model.open(object) }
                Divider()
            }
            Button("Baixar para \(model.downloadFolder.lastPathComponent)") {
                model.enqueueDownload(objects, to: model.downloadFolder)
            }
            Button("Baixar em…") { model.enqueueDownloadWithPanel(objects) }
            Divider()
            if objects.count == 1, let object = objects.first {
                Button("Renomear…") { model.sheet = .rename(object) }
            }
            Button("Apagar do aparelho", role: .destructive) {
                model.selection = Set(objects.map(\.handle))
                model.deleteSelected()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.searchText.isEmpty ? "folder" : "magnifyingglass")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)
            Text(model.searchText.isEmpty ? "Pasta vazia" : "Nada encontrado")
                .font(.title3)
                .foregroundStyle(.secondary)
            if model.searchText.isEmpty {
                Text("Arraste arquivos do Finder para cá para enviá-los ao aparelho.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            if model.isListing {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let storage = model.storages.first(where: { $0.id == model.selectedStorage }),
               storage.capacity > 0 {
                Text("\(Format.bytes(storage.freeSpace)) livres")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 26)
    }

    private var statusText: String {
        let total = model.visibleItems.count
        let selected = model.selection.count
        var parts = ["\(total) \(total == 1 ? "item" : "itens")"]
        if selected > 0 { parts.append("\(selected) selecionado\(selected == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Célula do nome (origem do arrastar para o Finder)

private struct NameCell: View {
    @EnvironmentObject private var model: AppModel
    let object: MTPObject

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: FileIcons.icon(for: object))
                .resizable()
                .frame(width: 17, height: 17)
            Text(object.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onDrag { itemProvider() }
    }

    /// O arquivo só é lido do aparelho quando o usuário solta no Finder.
    private func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = object.name
        let identifier: String = {
            if object.isFolder { return UTType.folder.identifier }
            if !object.fileExtension.isEmpty,
               let type = UTType(filenameExtension: object.fileExtension) {
                return type.identifier
            }
            return UTType.data.identifier
        }()

        provider.registerFileRepresentation(forTypeIdentifier: identifier,
                                            fileOptions: [],
                                            visibility: .all) { completion in
            Task { @MainActor in
                model.provideFileForDrag(object) { result in
                    switch result {
                    case .success(let url): completion(url, false, nil)
                    case .failure(let error): completion(nil, false, error)
                    }
                }
            }
            return nil
        }
        return provider
    }
}

// MARK: - Trilha de navegação

private struct BreadcrumbBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                crumb(label: rootLabel, systemImage: rootIcon, index: 0)
                ForEach(Array(model.path.enumerated()), id: \.element.handle) { index, folder in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    crumb(label: folder.name, systemImage: nil, index: index + 1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .frame(height: 30)
    }

    private var rootLabel: String {
        model.storages.first { $0.id == model.selectedStorage }?.displayName ?? "Aparelho"
    }

    private var rootIcon: String {
        let storage = model.storages.first { $0.id == model.selectedStorage }
        return (storage?.isRemovable ?? false) ? "sdcard" : "internaldrive"
    }

    @ViewBuilder
    private func crumb(label: String, systemImage: String?, index: Int) -> some View {
        let isLast = index == model.path.count
        Button {
            model.navigate(toPathIndex: index)
        } label: {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).font(.caption) }
                Text(label).lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(isLast ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(isLast)
    }
}
