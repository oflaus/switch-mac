import SwiftUI

struct TransfersPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transferências").font(.headline)
                Spacer()
                if model.transfers.contains(where: { !$0.isActive }) {
                    Button("Limpar concluídas") { model.clearFinishedTransfers() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(12)

            Divider()

            if model.transfers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 28, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text("Nenhuma transferência ainda")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.transfers.reversed()) { transfer in
                            TransferRow(transfer: transfer) { model.cancelTransfer(transfer.id) }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
        }
    }
}

private struct TransferRow: View {
    let transfer: TransferItem
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if transfer.isActive {
                    ProgressView(value: transfer.fraction)
                        .progressViewStyle(.linear)
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if transfer.isActive {
                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancelar")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var icon: String {
        switch transfer.status {
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "slash.circle"
        default: return transfer.direction == .download ? "arrow.down.circle" : "arrow.up.circle"
        }
    }

    private var tint: Color {
        switch transfer.status {
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }

    private var subtitle: String {
        switch transfer.status {
        case .queued:
            return "Na fila"
        case .preparing:
            return "Preparando…"
        case .running:
            var parts: [String] = []
            if transfer.total > 0 {
                parts.append("\(Format.bytes(transfer.completed)) de \(Format.bytes(transfer.total))")
            }
            let speed = Format.speed(transfer.bytesPerSecond)
            if !speed.isEmpty { parts.append(speed) }
            let remaining = Format.remaining(transfer.secondsRemaining)
            if !remaining.isEmpty { parts.append(remaining) }
            if parts.isEmpty { parts.append(transfer.detail) }
            return parts.joined(separator: " · ")
        case .finished:
            return "Concluído · \(Format.bytes(transfer.total)) \(transfer.detail)"
        case .cancelled:
            return "Cancelado"
        case .failed(let message):
            return message
        }
    }
}
