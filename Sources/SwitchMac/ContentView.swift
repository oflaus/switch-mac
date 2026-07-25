import MTPKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showTransfers = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            Group {
                if model.state.isConnected {
                    BrowserView()
                } else {
                    WelcomeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filtrar nesta pasta")
            .toolbar { toolbarContent }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TransferBar()
        }
        .animation(.easeInOut(duration: 0.2), value: model.bannerTransferID)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .newFolder:
                NameSheet(title: "Nova pasta", initialName: "Nova pasta", confirmLabel: "Criar") { name in
                    model.createFolder(named: name)
                }
            case .rename(let object):
                NameSheet(title: "Renomear", initialName: object.name, confirmLabel: "Renomear") { name in
                    model.rename(object, to: name)
                }
            case .diagnostics:
                DiagnosticsView()
            }
        }
        .alert("Não deu certo",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var title: String {
        switch model.state {
        case .connected(let name): return name
        default: return "Switch Mac"
        }
    }

    private var subtitle: String {
        guard model.state.isConnected else { return "" }
        if let storage = model.storages.first(where: { $0.id == model.selectedStorage }) {
            let crumbs = model.path.map(\.name)
            return ([storage.displayName] + crumbs).joined(separator: " › ")
        }
        return model.deviceSummary
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .help("Voltar")
                .disabled(!model.canGoBack)
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .help("Avançar")
                .disabled(!model.canGoForward)
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .help("Pasta acima")
                .disabled(!model.canGoUp)
        }

        ToolbarItemGroup {
            Button { model.uploadFromPicker() } label: {
                Label("Enviar", systemImage: "arrow.up.doc")
            }
            .help("Enviar arquivos do Mac para o aparelho")
            .disabled(!model.state.isConnected)

            Button { model.downloadSelected() } label: {
                Label("Baixar", systemImage: "arrow.down.doc")
            }
            .help("Baixar os itens selecionados para o Mac")
            .disabled(model.selection.isEmpty)

            Button { model.sheet = .newFolder } label: {
                Label("Nova pasta", systemImage: "folder.badge.plus")
            }
            .help("Criar uma pasta no aparelho")
            .disabled(!model.state.isConnected)

            Button { model.deleteSelected() } label: {
                Label("Apagar", systemImage: "trash")
            }
            .help("Apagar do aparelho")
            .disabled(model.selection.isEmpty)

            Button { model.refresh() } label: {
                Label("Atualizar", systemImage: "arrow.clockwise")
            }
            .help("Recarregar a pasta")
            .disabled(!model.state.isConnected)

            Button { showTransfers.toggle() } label: {
                Label("Transferências", systemImage: transfersIcon)
            }
            .help("Transferências")
            .popover(isPresented: $showTransfers, arrowEdge: .bottom) {
                TransfersPanel()
                    .environmentObject(model)
                    .frame(width: 380)
            }
        }
    }

    private var transfersIcon: String {
        model.activeTransferCount > 0 ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle"
    }
}
