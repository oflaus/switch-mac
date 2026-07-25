import MTPKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: storageSelection) {
            Section {
                deviceHeader
                    .padding(.vertical, 4)
            }

            if !model.storages.isEmpty {
                Section("Armazenamento") {
                    ForEach(model.storages) { storage in
                        StorageRow(storage: storage)
                            .tag(storage.id)
                    }
                }
            }

            if model.activeTransferCount > 0 {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(model.activeTransferCount) transferência\(model.activeTransferCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var storageSelection: Binding<UInt32?> {
        Binding(get: { model.selectedStorage },
                set: { if let value = $0 { model.selectStorage(value) } })
    }

    @ViewBuilder
    private var deviceHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 21))
                .foregroundStyle(statusColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
    }

    private var statusIcon: String {
        switch model.state {
        case .connected: return "iphone.gen3"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .chargingOnly: return "bolt.circle"
        case .failed: return "exclamationmark.triangle"
        case .searching: return "cable.connector"
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .connected: return .green
        case .connecting: return .accentColor
        case .chargingOnly: return .orange
        case .failed: return .red
        case .searching: return .secondary
        }
    }

    private var statusTitle: String {
        switch model.state {
        case .connected(let name): return name
        case .connecting(let name): return name
        case .chargingOnly(let name): return name
        case .failed: return "Falha na conexão"
        case .searching: return "Nenhum aparelho"
        }
    }

    private var statusDetail: String {
        switch model.state {
        case .connected: return model.deviceSummary.isEmpty ? "Conectado" : model.deviceSummary
        case .connecting: return "Abrindo sessão MTP…"
        case .chargingOnly: return "Conectado só para carregar"
        case .failed(let message): return message
        case .searching: return "Conecte o cabo USB"
        }
    }
}

private struct StorageRow: View {
    let storage: MTPStorage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(storage.displayName).lineLimit(1)
            } icon: {
                Image(systemName: storage.isRemovable ? "sdcard" : "internaldrive")
            }

            if storage.capacity > 0 {
                ProgressView(value: Double(storage.usedSpace), total: Double(storage.capacity))
                    .progressViewStyle(.linear)
                    .tint(fillColor)
                Text("\(Format.bytes(storage.freeSpace)) livres de \(Format.bytes(storage.capacity))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var fillColor: Color {
        guard storage.capacity > 0 else { return .accentColor }
        let used = Double(storage.usedSpace) / Double(storage.capacity)
        if used > 0.92 { return .red }
        if used > 0.8 { return .orange }
        return .accentColor
    }
}
