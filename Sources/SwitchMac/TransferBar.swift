import SwiftUI

/// Barra fixa no rodapé da janela enquanto existe uma transferência.
/// É o retorno visual principal: nome do arquivo, barra de progresso, quanto já foi,
/// velocidade, tempo decorrido e tempo restante.
struct TransferBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let transfer = model.bannerTransfer {
            VStack(spacing: 0) {
                Divider()
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: icon(for: transfer))
                        .font(.system(size: 17))
                        .foregroundStyle(tint(for: transfer))
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(headline(for: transfer))
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if model.queuedTransferCount > 0 {
                                Text("· mais \(model.queuedTransferCount) na fila")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Text(percentText(for: transfer))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        ProgressView(value: transfer.fraction)
                            .progressViewStyle(.linear)
                            .tint(tint(for: transfer))

                        Text(detail(for: transfer))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if transfer.isActive {
                        Button {
                            model.cancelTransfer(transfer.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Cancelar transferência")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(height: 66)
                .background(.bar)
            }
            .transition(.move(edge: .bottom))
        }
    }

    private func headline(for transfer: TransferItem) -> String {
        let verb = transfer.direction == .download ? "Baixando" : "Enviando"
        switch transfer.status {
        case .queued: return "Na fila: \(transfer.title)"
        case .preparing: return "Preparando \(transfer.title)"
        case .running: return "\(verb) \(transfer.title)"
        case .finished: return "Concluído: \(transfer.title)"
        case .cancelled: return "Cancelado: \(transfer.title)"
        case .failed: return "Falhou: \(transfer.title)"
        }
    }

    private func percentText(for transfer: TransferItem) -> String {
        guard transfer.total > 0 else { return "" }
        return "\(Int((transfer.fraction * 100).rounded()))%"
    }

    private func detail(for transfer: TransferItem) -> String {
        switch transfer.status {
        case .queued:
            return "Aguardando a transferência anterior terminar"
        case .preparing:
            return "Lendo a lista de arquivos…"
        case .running:
            var parts: [String] = []
            if transfer.total > 0 {
                parts.append("\(Format.bytes(transfer.completed)) de \(Format.bytes(transfer.total))")
            }
            let speed = Format.speed(transfer.bytesPerSecond)
            if !speed.isEmpty { parts.append(speed) }
            parts.append("decorrido \(Format.clock(transfer.duration))")
            let remaining = Format.remaining(transfer.secondsRemaining)
            if !remaining.isEmpty { parts.append(remaining) }
            if !transfer.detail.isEmpty { parts.append(transfer.detail) }
            return parts.joined(separator: " · ")
        case .finished:
            return "\(Format.bytes(transfer.total)) em \(Format.clock(transfer.duration))"
                 + (transfer.detail.isEmpty ? "" : " · \(transfer.detail)")
        case .cancelled:
            return "Interrompido depois de \(Format.bytes(transfer.completed))"
        case .failed(let message):
            return message
        }
    }

    private func icon(for transfer: TransferItem) -> String {
        switch transfer.status {
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "slash.circle"
        default: return transfer.direction == .download ? "arrow.down.circle" : "arrow.up.circle"
        }
    }

    private func tint(for transfer: TransferItem) -> Color {
        switch transfer.status {
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }
}
