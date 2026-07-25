import AppKit
import MTPKit
import SwiftUI

@main
struct SwitchMacApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Modo de linha de comando para diagnosticar detecção sem abrir a janela:
        //   "Switch Mac.app/Contents/MacOS/SwitchMac" --scan
        if CommandLine.arguments.contains("--scan") {
            let done = DispatchSemaphore(value: 0)
            // `App.init` roda no MainActor; um `Task` comum herdaria esse ator e
            // nunca sairia do lugar com a thread principal parada no semáforo.
            Task.detached {
                print(await MTPBus.shared.report())
                let devices = await MTPBus.shared.scan()
                if devices.isEmpty {
                    print("\nnenhum aparelho Android reconhecido")
                } else {
                    print("\naparelhos Android:")
                    for device in devices {
                        print("  \(device.displayName) [\(device.id)] "
                            + (device.hasMTP ? "— modo transferência de arquivos" : "— sem interface MTP"))
                    }
                }
                done.signal()
            }
            done.wait()
            exit(0)
        }

        // Modo de investigação: entra em uma pasta e mostra tudo que vai e volta.
        if CommandLine.arguments.contains("--probe") {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await Probe.run()
                done.signal()
            }
            done.wait()
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Switch Mac") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 520)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1060, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nova pasta") { model.sheet = .newFolder }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!model.state.isConnected)
            }
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Voltar") { model.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.canGoBack)
                Button("Avançar") { model.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.canGoForward)
                Button("Pasta acima") { model.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!model.canGoUp)
                Divider()
                Button("Atualizar") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.state.isConnected)
            }
            CommandMenu("Dispositivo") {
                Button("Enviar arquivos para o aparelho…") { model.uploadFromPicker() }
                    .keyboardShortcut("u", modifiers: .command)
                Button("Baixar seleção…") { model.downloadSelected() }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Baixar para \(model.downloadFolder.lastPathComponent)") {
                    model.downloadSelectedToDefaultFolder()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("Apagar seleção") { model.deleteSelected() }
                    .keyboardShortcut(.delete, modifiers: .command)
                Divider()
                Button("Reconectar") { model.reconnect() }
                Button("Liberar interface USB") { model.releaseInterfaceAndRetry() }
                Button("Diagnóstico…") { model.sheet = .diagnostics }
            }
        }

        Settings {
            PreferencesView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Duas cópias abertas brigariam pela mesma interface USB e a segunda receberia
    /// "acesso negado". Se já existe uma rodando, traz ela para a frente e sai.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != mine }
        guard let existing = others.first else { return }
        existing.activate()
        NSApp.terminate(nil)
    }
}

struct PreferencesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            LabeledContent("Pasta de download") {
                HStack(spacing: 8) {
                    Text(model.downloadFolder.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Escolher…") { model.chooseDownloadFolder() }
                }
            }
            Toggle("Registrar detalhes do protocolo MTP", isOn: $model.verboseLogging)
            Text("Ative apenas para investigar problemas: deixa o registro de diagnóstico "
               + "bem mais verboso e um pouco mais lento.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }
}
