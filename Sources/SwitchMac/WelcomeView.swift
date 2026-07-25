import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: icon)
                .font(.system(size: 62, weight: .thin))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 8) {
                Text(headline)
                    .font(.title2.weight(.medium))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(minWidth: 320, maxWidth: 460)
            }

            if showSteps {
                VStack(alignment: .leading, spacing: 10) {
                    Step(number: 1, text: "Conecte o aparelho ao Mac com um cabo USB que transfira dados "
                                        + "(cabo só de carga não funciona).")
                    Step(number: 2, text: "Desbloqueie a tela do celular.")
                    Step(number: 3, text: "Deslize a barra de notificações, toque em "
                                        + "“Carregando este dispositivo via USB” e escolha "
                                        + "“Transferência de arquivos” (ou MTP).")
                }
                .frame(minWidth: 320, maxWidth: 480, alignment: .leading)
                .padding(18)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            }

            HStack(spacing: 12) {
                if model.interfaceLocked {
                    Button("Liberar interface USB") { model.releaseInterfaceAndRetry() }
                        .buttonStyle(.borderedProminent)
                    Button("Procurar de novo") { model.reconnect() }
                } else {
                    Button("Procurar de novo") { model.reconnect() }
                        .buttonStyle(.borderedProminent)
                }
                Button("Diagnóstico…") { model.sheet = .diagnostics }
            }

            if model.interfaceLocked {
                Text("“Liberar interface USB” encerra os serviços de câmera do macOS "
                   + "(ptpcamerad) que estão segurando o aparelho. O sistema os reinicia "
                   + "sozinho depois — nada é desinstalado.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(minWidth: 320, maxWidth: 460)
            }

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var icon: String {
        switch model.state {
        case .failed: return "exclamationmark.triangle"
        case .chargingOnly: return "bolt.horizontal.circle"
        case .connecting: return "arrow.triangle.2.circlepath"
        default: return "cable.connector.horizontal"
        }
    }

    private var headline: String {
        switch model.state {
        case .searching: return "Nenhum aparelho Android conectado"
        case .chargingOnly(let name): return "\(name) está só carregando"
        case .connecting(let name): return "Conectando a \(name)…"
        case .failed: return "Não foi possível abrir o aparelho"
        case .connected: return "Conectado"
        }
    }

    private var message: String {
        switch model.state {
        case .searching:
            return "Conecte o celular ou tablet pelo cabo USB. O Switch Mac detecta sozinho "
                 + "assim que o aparelho entrar em modo de transferência de arquivos."
        case .chargingOnly:
            return "O aparelho foi reconhecido, mas ainda não expôs o modo de transferência de "
                 + "arquivos. Siga os passos abaixo no celular."
        case .connecting:
            return "Negociando a sessão MTP."
        case .failed(let detail):
            return detail
        case .connected:
            return ""
        }
    }

    private var showSteps: Bool {
        switch model.state {
        case .connecting, .connected: return false
        default: return true
        }
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 19, height: 19)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.callout)
        }
    }
}
