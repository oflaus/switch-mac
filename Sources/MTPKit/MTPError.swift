import Foundation

public enum MTPError: LocalizedError {
    case libusbInit(Int32)
    case noDevice
    case deviceGone
    case openFailed(Int32)
    case claimFailed(Int32)
    case noMTPInterface
    case transfer(String, Int32)
    case protocolError(String)
    case device(MTPResponse)
    case cancelled
    case localIO(String)

    /// Indica que a interface existe mas outro processo a mantém reservada — o caso em que
    /// vale oferecer ao usuário o botão de liberar a interface.
    public var isInterfaceLocked: Bool {
        switch self {
        case .claimFailed(let code), .openFailed(let code):
            return code == -3 || code == -6   // LIBUSB_ERROR_ACCESS / LIBUSB_ERROR_BUSY
        default:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .libusbInit(let c):
            return "Não foi possível inicializar o subsistema USB (libusb \(c))."
        case .noDevice:
            return "Nenhum dispositivo Android conectado."
        case .deviceGone:
            return "O dispositivo foi desconectado."
        case .openFailed(let c):
            return openHint(code: c)
        case .claimFailed(let c):
            return claimHint(code: c)
        case .noMTPInterface:
            return "O aparelho está conectado, mas não expôs uma interface MTP. "
                 + "No celular, toque na notificação de USB e escolha “Transferência de arquivos”."
        case .transfer(let phase, let c):
            return "Falha na comunicação USB (\(phase), libusb \(c)). "
                 + "Desconecte e reconecte o cabo."
        case .protocolError(let m):
            return "Resposta MTP inesperada: \(m)"
        case .device(let r):
            return r.localizedDescription
        case .cancelled:
            return "Operação cancelada."
        case .localIO(let m):
            return m
        }
    }

    private func openHint(code: Int32) -> String {
        switch code {
        case -3: // LIBUSB_ERROR_ACCESS
            return "Sem permissão para acessar o dispositivo USB. Feche o Captura de Imagem, "
                 + "o Fotos e o Android File Transfer e tente de novo."
        case -4: // LIBUSB_ERROR_NO_DEVICE
            return "O dispositivo foi desconectado."
        default:
            return "Não foi possível abrir o dispositivo USB (libusb \(code))."
        }
    }

    private func claimHint(code: Int32) -> String {
        switch code {
        case -3, -6: // LIBUSB_ERROR_ACCESS / LIBUSB_ERROR_BUSY
            return "A interface MTP está reservada pelo próprio macOS. O serviço de câmeras "
                 + "(ptpcamerad, do Captura de Imagem) pega esse tipo de aparelho assim que ele "
                 + "é conectado e não solta. Use “Liberar interface USB” para encerrá-lo — "
                 + "o macOS o reinicia sozinho quando precisar."
        case -4:
            return "O dispositivo foi desconectado."
        default:
            return "Não foi possível reservar a interface MTP (libusb \(code))."
        }
    }
}
