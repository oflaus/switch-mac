import Foundation

/// PTP/MTP wire constants. Values come from the PTP (ISO 15740) and
/// MTP (Microsoft Media Transfer Protocol) specifications, which is what
/// Android's MtpServer implements.
public enum MTPOp: UInt16 {
    case getDeviceInfo         = 0x1001
    case openSession           = 0x1002
    case closeSession          = 0x1003
    case getStorageIDs         = 0x1004
    case getStorageInfo        = 0x1005
    case getNumObjects         = 0x1006
    case getObjectHandles      = 0x1007
    case getObjectInfo         = 0x1008
    case getObject             = 0x1009
    case getThumb              = 0x100A
    case deleteObject          = 0x100B
    case sendObjectInfo        = 0x100C
    case sendObject            = 0x100D
    case getDevicePropDesc     = 0x1014
    case getDevicePropValue    = 0x1015
    case getPartialObject      = 0x101B
    case getObjectPropsSupported = 0x9801
    case getObjectPropDesc     = 0x9802
    case getObjectPropValue    = 0x9803
    case setObjectPropValue    = 0x9804
    case getObjectPropList     = 0x9805
    case getObjectPropsRef     = 0x9810
    case getPartialObject64    = 0x95C1
}

public enum MTPResponse: UInt16 {
    case ok                        = 0x2001
    case generalError              = 0x2002
    case sessionNotOpen            = 0x2003
    case invalidTransactionID      = 0x2004
    case operationNotSupported     = 0x2005
    case parameterNotSupported     = 0x2006
    case incompleteTransfer        = 0x2007
    case invalidStorageID          = 0x2008
    case invalidObjectHandle       = 0x2009
    case devicePropNotSupported    = 0x200A
    case invalidObjectFormatCode   = 0x200B
    case storeFull                 = 0x200C
    case objectWriteProtected      = 0x200D
    case storeReadOnly             = 0x200E
    case accessDenied              = 0x200F
    case partialDeletion           = 0x2012
    case storeNotAvailable         = 0x2013
    case specByFormatUnsupported   = 0x2014
    case noValidObjectInfo         = 0x2015
    case deviceBusy                = 0x2019
    case invalidParentObject       = 0x201A
    case invalidParameter          = 0x201D
    case sessionAlreadyOpen        = 0x201E
    case transactionCancelled      = 0x201F
    case invalidObjectPropCode     = 0xA801
    case invalidObjectPropFormat   = 0xA802
    case objectTooLarge            = 0xA809
    case objectPropNotSupported    = 0xA80A

    /// Portuguese description shown to the user when a request fails.
    public var localizedDescription: String {
        switch self {
        case .ok: return "OK"
        case .accessDenied: return "Acesso negado pelo dispositivo"
        case .storeFull: return "Sem espaço livre no dispositivo"
        case .storeReadOnly: return "O armazenamento é somente leitura"
        case .objectWriteProtected: return "Arquivo protegido contra gravação"
        case .storeNotAvailable: return "Armazenamento indisponível (cartão removido?)"
        case .deviceBusy: return "Dispositivo ocupado — tente de novo"
        case .invalidObjectHandle: return "O arquivo não existe mais no dispositivo"
        case .invalidParentObject: return "Pasta de destino inválida"
        case .operationNotSupported: return "Operação não suportada por este aparelho"
        case .sessionNotOpen: return "Sessão MTP fechada"
        case .partialDeletion: return "Só parte dos itens pôde ser apagada"
        case .objectTooLarge: return "Arquivo grande demais para o sistema de arquivos do destino"
        case .transactionCancelled: return "Transferência cancelada pelo dispositivo"
        case .generalError: return "Erro genérico do dispositivo"
        default: return "Erro MTP 0x\(String(rawValue, radix: 16, uppercase: true))"
        }
    }
}

public enum MTPFormat {
    public static let undefined: UInt16   = 0x3000
    public static let association: UInt16 = 0x3001  // pasta
}

public enum MTPObjectProp {
    public static let storageID: UInt16      = 0xDC01
    public static let objectFormat: UInt16   = 0xDC02
    public static let objectSize: UInt16     = 0xDC04
    public static let fileName: UInt16       = 0xDC07
    public static let dateCreated: UInt16    = 0xDC08
    public static let dateModified: UInt16   = 0xDC09
    public static let parentObject: UInt16   = 0xDC0B
    public static let persistentUID: UInt16  = 0xDC41
    public static let name: UInt16           = 0xDC44
}

public enum MTPDeviceProp {
    public static let batteryLevel: UInt16       = 0x5001
    public static let syncPartner: UInt16        = 0xD401
    public static let deviceFriendlyName: UInt16 = 0xD402
}

public enum MTPDataType {
    public static let uint8: UInt16  = 0x0002
    public static let uint16: UInt16 = 0x0004
    public static let uint32: UInt16 = 0x0006
    public static let uint64: UInt16 = 0x0008
    public static let string: UInt16 = 0xFFFF
}

public enum MTPHandle {
    /// Raiz de um storage. Em GetObjectHandles/SendObjectInfo, 0xFFFFFFFF = raiz.
    public static let root: UInt32 = 0xFFFFFFFF
    public static let all: UInt32  = 0xFFFFFFFF
}

enum ContainerType: UInt16 {
    case command  = 1
    case data     = 2
    case response = 3
    case event    = 4
}
