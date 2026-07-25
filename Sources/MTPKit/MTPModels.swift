import Foundation

// MARK: - Informações do aparelho

public struct MTPDeviceInfo: Sendable {
    public var standardVersion: UInt16 = 0
    public var vendorExtensionID: UInt32 = 0
    public var vendorExtensionDesc: String = ""
    public var operationsSupported: Set<UInt16> = []
    public var devicePropertiesSupported: Set<UInt16> = []
    public var manufacturer: String = ""
    public var model: String = ""
    public var deviceVersion: String = ""
    public var serialNumber: String = ""

    public func supports(_ op: MTPOp) -> Bool { operationsSupported.contains(op.rawValue) }

    static func parse(_ reader: inout ByteReader) throws -> MTPDeviceInfo {
        var info = MTPDeviceInfo()
        info.standardVersion = try reader.u16()
        info.vendorExtensionID = try reader.u32()
        _ = try reader.u16() // vendor extension version
        info.vendorExtensionDesc = try reader.string()
        _ = try reader.u16() // functional mode
        info.operationsSupported = Set(try reader.u16Array())
        _ = try reader.u16Array() // events
        info.devicePropertiesSupported = Set(try reader.u16Array())
        _ = try reader.u16Array() // capture formats
        _ = try reader.u16Array() // playback formats
        info.manufacturer = try reader.string()
        info.model = try reader.string()
        info.deviceVersion = try reader.string()
        info.serialNumber = try reader.string()
        return info
    }
}

// MARK: - Armazenamento

public struct MTPStorage: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let label: String
    public let volumeIdentifier: String
    public let capacity: Int64
    public let freeSpace: Int64
    public let isReadOnly: Bool
    public let isRemovable: Bool

    public var displayName: String {
        if !label.isEmpty { return label }
        if !volumeIdentifier.isEmpty { return volumeIdentifier }
        return isRemovable ? "Cartão SD" : "Armazenamento interno"
    }

    public var usedSpace: Int64 { max(0, capacity - freeSpace) }

    public init(id: UInt32, label: String, volumeIdentifier: String,
                capacity: Int64, freeSpace: Int64, isReadOnly: Bool, isRemovable: Bool) {
        self.id = id
        self.label = label
        self.volumeIdentifier = volumeIdentifier
        self.capacity = capacity
        self.freeSpace = freeSpace
        self.isReadOnly = isReadOnly
        self.isRemovable = isRemovable
    }

    static func parse(_ reader: inout ByteReader, id: UInt32) throws -> MTPStorage {
        let storageType = try reader.u16()      // 3 = fixed RAM, 4 = removable RAM
        _ = try reader.u16()                    // filesystem type
        let access = try reader.u16()           // 0 = read/write
        let capacity = try reader.u64()
        let free = try reader.u64()
        _ = try reader.u32()                    // free space in objects
        let description = try reader.string()
        let volumeID = (try? reader.string()) ?? ""

        return MTPStorage(
            id: id,
            label: description,
            volumeIdentifier: volumeID,
            capacity: Int64(clamping: capacity),
            freeSpace: Int64(clamping: free),
            isReadOnly: access != 0,
            isRemovable: storageType == 4
        )
    }
}

// MARK: - Objetos (arquivos e pastas)

public struct MTPObject: Identifiable, Hashable, Sendable {
    public let handle: UInt32
    public let storageID: UInt32
    public let parent: UInt32
    public let name: String
    public let format: UInt16
    public let size: Int64
    public let modified: Date?
    public let created: Date?

    public var id: UInt32 { handle }
    public var isFolder: Bool { format == MTPFormat.association }

    public init(handle: UInt32, storageID: UInt32, parent: UInt32, name: String,
                format: UInt16, size: Int64, modified: Date?, created: Date?) {
        self.handle = handle
        self.storageID = storageID
        self.parent = parent
        self.name = name
        self.format = format
        self.size = size
        self.modified = modified
        self.created = created
    }

    public var fileExtension: String {
        guard !isFolder else { return "" }
        return (name as NSString).pathExtension.lowercased()
    }

    static func parse(_ reader: inout ByteReader, handle: UInt32) throws -> MTPObject {
        let storageID = try reader.u32()
        let format = try reader.u16()
        _ = try reader.u16()                    // protection status
        let compressedSize = try reader.u32()
        _ = try reader.u16()                    // thumb format
        _ = try reader.u32()                    // thumb compressed size
        _ = try reader.u32()                    // thumb width
        _ = try reader.u32()                    // thumb height
        _ = try reader.u32()                    // image width
        _ = try reader.u32()                    // image height
        _ = try reader.u32()                    // image bit depth
        let parent = try reader.u32()
        _ = try reader.u16()                    // association type
        _ = try reader.u32()                    // association description
        _ = try reader.u32()                    // sequence number
        let name = try reader.string()
        let created = MTPDate.parse((try? reader.string()) ?? "")
        let modified = MTPDate.parse((try? reader.string()) ?? "")

        return MTPObject(
            handle: handle,
            storageID: storageID,
            parent: parent,
            name: name,
            format: format,
            // 0xFFFFFFFF sinaliza "maior que 4 GiB"; quem chama refina com ObjectSize (64 bits).
            size: compressedSize == 0xFFFF_FFFF ? -1 : Int64(compressedSize),
            modified: modified,
            created: created
        )
    }

    func withSize(_ newSize: Int64) -> MTPObject {
        MTPObject(handle: handle, storageID: storageID, parent: parent, name: name,
                  format: format, size: newSize, modified: modified, created: created)
    }
}

/// Datas MTP vêm como "YYYYMMDDThhmmss[.s][Z|±hhmm]".
enum MTPDate {
    static func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 15 else { return nil }
        let chars = Array(s)
        func num(_ range: Range<Int>) -> Int? {
            guard chars.count >= range.upperBound else { return nil }
            return Int(String(chars[range]))
        }
        guard chars[8] == "T",
              let year = num(0 ..< 4), let month = num(4 ..< 6), let day = num(6 ..< 8),
              let hour = num(9 ..< 11), let minute = num(11 ..< 13), let second = num(13 ..< 15)
        else { return nil }

        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second

        var calendar = Calendar(identifier: .gregorian)
        // Sem sufixo o horário é local ao aparelho, que na prática é o mesmo do Mac.
        if s.hasSuffix("Z") {
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        } else {
            calendar.timeZone = .current
        }
        return calendar.date(from: comps)
    }

    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.string(from: date)
    }
}
