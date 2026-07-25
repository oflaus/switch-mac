import AppKit
import MTPKit
import SwiftUI

struct NameSheet: View {
    let title: String
    let initialName: String
    let confirmLabel: String
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)

            TextField("Nome", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .focused($focused)
                .onSubmit(confirm)

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            name = initialName
            focused = true
        }
    }

    private func confirm() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
        dismiss()
    }
}

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var entries: [MTPLogEntry] = []
    @State private var autoRefresh = true

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Diagnóstico").font(.headline)
                Spacer()
                Toggle("Atualizar automaticamente", isOn: $autoRefresh)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Button("Copiar") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MTPLog.shared.plainText(), forType: .string)
                }
                Button("Limpar") {
                    MTPLog.shared.clear()
                    entries = []
                }
                Button("Liberar interface USB") { model.releaseInterfaceAndRetry() }
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(Self.time.string(from: entry.date))
                                .foregroundStyle(.tertiary)
                            Text(entry.message)
                                .foregroundStyle(color(for: entry.level))
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            HStack {
                Toggle("Registro detalhado do protocolo", isOn: $model.verboseLogging)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Text(blockingSummary)
                    .font(.caption)
                    .foregroundStyle(blockers.isEmpty ? .secondary : Color.orange)
                Spacer()
                Button("Fechar") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 460)
        .onAppear { entries = MTPLog.shared.snapshot() }
        .onReceive(timer) { _ in
            if autoRefresh { entries = MTPLog.shared.snapshot() }
        }
    }

    private var blockers: [InterfaceRelease.Running] { InterfaceRelease.running() }

    private var blockingSummary: String {
        let running = blockers
        guard !running.isEmpty else { return "Nenhum serviço do macOS segurando a interface" }
        return "Segurando a interface: " + running.map(\.name).joined(separator: ", ")
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func color(for level: MTPLogEntry.Level) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }
}
