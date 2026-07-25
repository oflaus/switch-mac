import Foundation
import CLibUSB

// MARK: - Constantes libusb usadas (evita depender da importação dos enums em C)

private let LU_SUCCESS: Int32      = 0
private let LU_ERR_ACCESS: Int32   = -3
private let LU_ERR_NO_DEVICE: Int32 = -4
private let LU_ERR_BUSY: Int32     = -6
private let LU_ERR_TIMEOUT: Int32  = -7
private let LU_ERR_PIPE: Int32     = -9

private let XFER_TYPE_MASK: UInt8  = 0x03
private let XFER_BULK: UInt8       = 0x02
private let XFER_INTERRUPT: UInt8  = 0x03
private let EP_DIR_MASK: UInt8     = 0x80
private let EP_IN: UInt8           = 0x80

// MARK: - Identificação

public struct USBDeviceID: Hashable, Sendable, CustomStringConvertible {
    public let bus: UInt8
    public let address: UInt8
    public let vendorID: UInt16
    public let productID: UInt16

    public var description: String {
        String(format: "%04x:%04x@%d.%d", vendorID, productID, Int(bus), Int(address))
    }
}

/// Um dispositivo encontrado no barramento USB, já classificado.
public struct DiscoveredDevice: Sendable, Identifiable {
    public let id: USBDeviceID
    public let vendorName: String
    public let productName: String
    public let serialNumber: String
    public let looksAndroid: Bool
    public let mtp: MTPInterface?

    public var hasMTP: Bool { mtp != nil }

    public var displayName: String {
        if !productName.isEmpty { return productName }
        if !vendorName.isEmpty { return "\(vendorName) (Android)" }
        return "Dispositivo Android"
    }
}

public struct MTPInterface: Sendable {
    public let configuration: UInt8
    public let number: UInt8
    public let altSetting: UInt8
    public let endpointIn: UInt8
    public let endpointOut: UInt8
    public let endpointEvent: UInt8?
    public let maxPacketIn: Int
    public let maxPacketOut: Int
}

// MARK: - Backend

/// Envelope fino sobre a libusb. **Todas** as chamadas precisam acontecer na mesma
/// fila serial (`MTPDevice.queue`); a classe não é thread-safe por conta própria.
public final class USBBackend {
    private var ctx: OpaquePointer?
    /// Ler as strings USB exige abrir o aparelho; fazemos isso uma vez só por dispositivo,
    /// porque a varredura roda de poucos em poucos segundos.
    private var stringCache: [USBDeviceID: (vendor: String, product: String, serial: String)] = [:]

    public init() throws {
        let r = libusb_init(&ctx)
        guard r == LU_SUCCESS else { throw MTPError.libusbInit(r) }
    }

    deinit { if let ctx { libusb_exit(ctx) } }

    // Fabricantes que aparecem com frequência em aparelhos Android. Serve só para
    // dar nome ao aparelho e para detectar "está plugado mas não está em modo MTP".
    private static let androidVendors: [UInt16: String] = [
        0x18D1: "Google", 0x04E8: "Samsung", 0x2717: "Xiaomi", 0x2A70: "OnePlus",
        0x22D9: "OPPO", 0x2D95: "Vivo", 0x0BB4: "HTC/Google", 0x12D1: "Huawei",
        0x2A45: "Meizu", 0x0FCE: "Sony", 0x1004: "LG", 0x0489: "Foxconn/Sharp",
        0x19D2: "ZTE", 0x1BBB: "Alcatel/TCL", 0x2916: "Android", 0x0E8D: "MediaTek",
        0x05C6: "Qualcomm", 0x1F3A: "Allwinner", 0x2C7C: "Quectel", 0x109B: "Hisense",
        0x2B4C: "Motorola", 0x22B8: "Motorola", 0x17EF: "Lenovo", 0x0B05: "ASUS",
        0x2A96: "Realme", 0x1EBF: "Nothing", 0x0421: "Nokia", 0x2D67: "Infinix/Tecno",
    ]

    /// Varre o barramento e devolve tudo que parece um aparelho Android.
    public func scan() -> [DiscoveredDevice] {
        guard let ctx else { return [] }
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(ctx, &list)
        guard count > 0, let list else { return [] }
        defer { libusb_free_device_list(list, 1) }

        var found: [DiscoveredDevice] = []
        for i in 0 ..< count {
            guard let dev = list[i] else { continue }
            if let d = inspect(dev) { found.append(d) }
        }
        // Aparelhos em modo MTP primeiro.
        return found.sorted { ($0.hasMTP ? 0 : 1, $0.id.description) < ($1.hasMTP ? 0 : 1, $1.id.description) }
    }

    private func inspect(_ dev: OpaquePointer) -> DiscoveredDevice? {
        var desc = libusb_device_descriptor()
        guard libusb_get_device_descriptor(dev, &desc) == LU_SUCCESS else { return nil }

        let id = USBDeviceID(bus: libusb_get_bus_number(dev),
                             address: libusb_get_device_address(dev),
                             vendorID: desc.idVendor,
                             productID: desc.idProduct)

        // Hubs e o controlador raiz nunca interessam.
        if desc.bDeviceClass == 0x09 { return nil }

        var mtp: MTPInterface?
        var hasADB = false

        var cfgPtr: UnsafeMutablePointer<libusb_config_descriptor>?
        if libusb_get_active_config_descriptor(dev, &cfgPtr) == LU_SUCCESS, let cfgPtr {
            defer { libusb_free_config_descriptor(cfgPtr) }
            let cfg = cfgPtr.pointee
            for ifaceIdx in 0 ..< Int(cfg.bNumInterfaces) {
                guard let ifaces = cfg.interface else { break }
                let iface = ifaces[ifaceIdx]
                guard let alts = iface.altsetting else { continue }
                for altIdx in 0 ..< Int(iface.num_altsetting) {
                    let alt = alts[altIdx]
                    if alt.bInterfaceClass == 0xFF, alt.bInterfaceSubClass == 0x42,
                       alt.bInterfaceProtocol == 0x01 {
                        hasADB = true
                    }
                    if mtp == nil, let parsed = parseMTPInterface(alt, configuration: cfg.bConfigurationValue) {
                        mtp = parsed
                    }
                }
            }
        }

        let vendorName = Self.androidVendors[desc.idVendor] ?? ""
        let looksAndroid = mtp != nil || hasADB || !vendorName.isEmpty
        guard looksAndroid else { return nil }

        // Se não der para abrir (ocupado por outro app), seguimos com o que temos —
        // a interface ainda consegue mostrar algo útil.
        var product = "", manufacturer = "", serial = ""
        if let cached = stringCache[id] {
            manufacturer = cached.vendor; product = cached.product; serial = cached.serial
        } else {
            var handle: OpaquePointer?
            if libusb_open(dev, &handle) == LU_SUCCESS, let handle {
                product = stringDescriptor(handle, desc.iProduct)
                manufacturer = stringDescriptor(handle, desc.iManufacturer)
                serial = stringDescriptor(handle, desc.iSerialNumber)
                libusb_close(handle)
                stringCache[id] = (manufacturer, product, serial)
            }
        }

        return DiscoveredDevice(
            id: id,
            vendorName: manufacturer.isEmpty ? vendorName : manufacturer,
            productName: product,
            serialNumber: serial,
            looksAndroid: looksAndroid,
            mtp: mtp
        )
    }

    /// Uma interface serve para MTP quando é "Still Image / PTP" (classe 6, sub 1, proto 1)
    /// — que é exatamente o que o Android expõe no modo "Transferência de arquivos" —
    /// e tem os dois endpoints bulk exigidos pelo protocolo.
    private func parseMTPInterface(_ alt: libusb_interface_descriptor,
                                   configuration: UInt8) -> MTPInterface? {
        let isStillImage = alt.bInterfaceClass == 0x06
            && alt.bInterfaceSubClass == 0x01
            && alt.bInterfaceProtocol == 0x01
        let isVendorMTP = alt.bInterfaceClass == 0xFF && alt.bNumEndpoints == 3
        guard isStillImage || isVendorMTP, let eps = alt.endpoint else { return nil }

        var epIn: UInt8?, epOut: UInt8?, epEvent: UInt8?
        var mpIn = 512, mpOut = 512
        for i in 0 ..< Int(alt.bNumEndpoints) {
            let ep = eps[i]
            let kind = ep.bmAttributes & XFER_TYPE_MASK
            let isIn = (ep.bEndpointAddress & EP_DIR_MASK) == EP_IN
            let maxPacket = Int(ep.wMaxPacketSize & 0x07FF)
            switch (kind, isIn) {
            case (XFER_BULK, true):
                if epIn == nil { epIn = ep.bEndpointAddress; mpIn = max(maxPacket, 1) }
            case (XFER_BULK, false):
                if epOut == nil { epOut = ep.bEndpointAddress; mpOut = max(maxPacket, 1) }
            case (XFER_INTERRUPT, true):
                if epEvent == nil { epEvent = ep.bEndpointAddress }
            default:
                break
            }
        }
        guard let epIn, let epOut else { return nil }
        // Interface vendor-specific sem endpoint de evento quase nunca é MTP.
        if isVendorMTP && epEvent == nil { return nil }

        return MTPInterface(configuration: configuration,
                            number: alt.bInterfaceNumber,
                            altSetting: alt.bAlternateSetting,
                            endpointIn: epIn,
                            endpointOut: epOut,
                            endpointEvent: epEvent,
                            maxPacketIn: mpIn,
                            maxPacketOut: mpOut)
    }

    /// Relatório textual de tudo que está no barramento. Serve para diagnosticar
    /// "meu aparelho não aparece" sem precisar de ferramentas externas.
    public func report() -> String {
        guard let ctx else { return "libusb não inicializada" }
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(ctx, &list)
        guard count > 0, let list else { return "nenhum dispositivo USB encontrado" }
        defer { libusb_free_device_list(list, 1) }

        var lines: [String] = ["\(count) dispositivos USB no barramento:"]
        for i in 0 ..< count {
            guard let dev = list[i] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == LU_SUCCESS else { continue }

            var interfaces: [String] = []
            var cfgPtr: UnsafeMutablePointer<libusb_config_descriptor>?
            if libusb_get_active_config_descriptor(dev, &cfgPtr) == LU_SUCCESS, let cfgPtr {
                defer { libusb_free_config_descriptor(cfgPtr) }
                let cfg = cfgPtr.pointee
                for index in 0 ..< Int(cfg.bNumInterfaces) {
                    guard let ifaces = cfg.interface, let alts = ifaces[index].altsetting else { continue }
                    let alt = alts[0]
                    interfaces.append(String(format: "%02x/%02x/%02x",
                                             alt.bInterfaceClass, alt.bInterfaceSubClass,
                                             alt.bInterfaceProtocol))
                }
            }
            let mtp = inspect(dev)?.mtp != nil ? "  ← interface MTP" : ""
            lines.append(String(format: "  %04x:%04x  bus %d addr %d  interfaces [%@]%@",
                                desc.idVendor, desc.idProduct,
                                Int(libusb_get_bus_number(dev)), Int(libusb_get_device_address(dev)),
                                interfaces.joined(separator: ", "), mtp))
        }
        return lines.joined(separator: "\n")
    }

    /// Apenas os identificadores presentes no barramento, sem abrir nada.
    /// Usado para saber rapidamente se o aparelho conectado continua plugado.
    public func presentIDs() -> Set<USBDeviceID> {
        guard let ctx else { return [] }
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(ctx, &list)
        guard count > 0, let list else { return [] }
        defer { libusb_free_device_list(list, 1) }

        var ids = Set<USBDeviceID>()
        for i in 0 ..< count {
            guard let dev = list[i] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == LU_SUCCESS else { continue }
            ids.insert(USBDeviceID(bus: libusb_get_bus_number(dev),
                                   address: libusb_get_device_address(dev),
                                   vendorID: desc.idVendor,
                                   productID: desc.idProduct))
        }
        return ids
    }

    private func stringDescriptor(_ handle: OpaquePointer, _ index: UInt8) -> String {
        guard index != 0 else { return "" }
        var buf = [UInt8](repeating: 0, count: 256)
        let n = libusb_get_string_descriptor_ascii(handle, index, &buf, 255)
        guard n > 0 else { return "" }
        return String(decoding: buf[0 ..< Int(n)], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Abre e reserva a interface MTP do dispositivo indicado.
    public func connect(to id: USBDeviceID) throws -> USBConnection {
        guard let ctx else { throw MTPError.noDevice }
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(ctx, &list)
        guard count > 0, let list else { throw MTPError.noDevice }
        defer { libusb_free_device_list(list, 1) }

        for i in 0 ..< count {
            guard let dev = list[i] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == LU_SUCCESS else { continue }
            let candidate = USBDeviceID(bus: libusb_get_bus_number(dev),
                                        address: libusb_get_device_address(dev),
                                        vendorID: desc.idVendor,
                                        productID: desc.idProduct)
            guard candidate == id else { continue }
            guard let info = inspect(dev), let mtp = info.mtp else { throw MTPError.noMTPInterface }
            return try USBConnection(device: dev, interface: mtp, id: id)
        }
        throw MTPError.noDevice
    }
}

// MARK: - Conexão aberta

public final class USBConnection {
    private var handle: OpaquePointer?
    private let device: OpaquePointer
    let interface: MTPInterface
    public let id: USBDeviceID

    init(device: OpaquePointer, interface: MTPInterface, id: USBDeviceID) throws {
        self.device = libusb_ref_device(device)!
        self.interface = interface
        self.id = id

        var h: OpaquePointer?
        let openResult = libusb_open(self.device, &h)
        guard openResult == LU_SUCCESS, let h else {
            libusb_unref_device(self.device)
            throw MTPError.openFailed(openResult)
        }
        handle = h

        // Em macOS não existe driver de kernel para destacar, mas a chamada é inócua
        // e deixa o código correto caso rode em outro sistema.
        libusb_set_auto_detach_kernel_driver(h, 1)

        // O ptpcamerad do macOS costuma pegar a interface "still image" assim que o
        // aparelho aparece e só solta depois de sondá-lo. Vale insistir um pouco antes
        // de desistir e pedir ajuda ao usuário.
        var claim = libusb_claim_interface(h, Int32(interface.number))
        var attempt = 1
        while claim != LU_SUCCESS && (claim == LU_ERR_BUSY || claim == LU_ERR_ACCESS) && attempt < 5 {
            MTPLog.shared.warn("interface MTP ocupada (tentativa \(attempt)); aguardando")
            usleep(400_000)
            claim = libusb_claim_interface(h, Int32(interface.number))
            attempt += 1
        }
        guard claim == LU_SUCCESS else {
            libusb_close(h)
            handle = nil
            libusb_unref_device(self.device)
            throw MTPError.claimFailed(claim)
        }

        if interface.altSetting != 0 {
            _ = libusb_set_interface_alt_setting(h, Int32(interface.number), Int32(interface.altSetting))
        }

        // Endpoints podem ter ficado em halt de uma sessão anterior mal encerrada.
        libusb_clear_halt(h, interface.endpointIn)
        libusb_clear_halt(h, interface.endpointOut)
    }

    deinit { close() }

    public func close() {
        guard let h = handle else { return }
        handle = nil
        libusb_release_interface(h, Int32(interface.number))
        libusb_close(h)
        libusb_unref_device(device)
    }

    var isOpen: Bool { handle != nil }

    @discardableResult
    func write(_ bytes: UnsafePointer<UInt8>, count: Int, timeout: UInt32) throws -> Int {
        guard let h = handle else { throw MTPError.deviceGone }
        var transferred: Int32 = 0
        let r = libusb_bulk_transfer(h, interface.endpointOut,
                                     UnsafeMutablePointer(mutating: bytes),
                                     Int32(count), &transferred, timeout)
        if r != LU_SUCCESS {
            if r == LU_ERR_PIPE { libusb_clear_halt(h, interface.endpointOut) }
            if r == LU_ERR_NO_DEVICE { throw MTPError.deviceGone }
            throw MTPError.transfer("envio", r)
        }
        return Int(transferred)
    }

    func read(into buffer: UnsafeMutablePointer<UInt8>, capacity: Int, timeout: UInt32) throws -> Int {
        guard let h = handle else { throw MTPError.deviceGone }
        var transferred: Int32 = 0
        let r = libusb_bulk_transfer(h, interface.endpointIn, buffer,
                                     Int32(capacity), &transferred, timeout)
        if r != LU_SUCCESS {
            if r == LU_ERR_PIPE { libusb_clear_halt(h, interface.endpointIn) }
            if r == LU_ERR_NO_DEVICE { throw MTPError.deviceGone }
            throw MTPError.transfer("recepção", r)
        }
        return Int(transferred)
    }

    /// Descarta eventos pendentes no endpoint de interrupção (não bloqueia).
    func drainEvents() {
        guard let h = handle, let ep = interface.endpointEvent else { return }
        var buf = [UInt8](repeating: 0, count: 64)
        var transferred: Int32 = 0
        _ = libusb_bulk_transfer(h, ep, &buf, 64, &transferred, 1)
    }
}
