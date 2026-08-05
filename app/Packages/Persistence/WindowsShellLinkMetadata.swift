import Foundation

struct WindowsShellLinkMetadata {
    private static let headerSize = 0x4C
    private static let shellLinkCLSID: [UInt8] = [
        0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46,
    ]

    private static let hasLinkTargetIDList: UInt32 = 1 << 0
    private static let hasLinkInfo: UInt32 = 1 << 1
    private static let hasName: UInt32 = 1 << 2
    private static let hasRelativePath: UInt32 = 1 << 3
    private static let hasWorkingDirectory: UInt32 = 1 << 4
    private static let hasArguments: UInt32 = 1 << 5
    private static let hasIconLocation: UInt32 = 1 << 6
    private static let isUnicode: UInt32 = 1 << 7

    let targetPath: String?
    let iconPath: String?
    let workingDirectory: String?
    let iconIndex: Int

    var iconReferences: [ShortcutIconReference] {
        var result: [ShortcutIconReference] = []
        if let iconPath, !iconPath.isEmpty {
            result.append(
                ShortcutIconReference(
                    windowsPath: iconPath,
                    iconIndex: iconIndex,
                    workingDirectory: workingDirectory
                )
            )
        }
        if let targetPath, !targetPath.isEmpty {
            result.append(
                ShortcutIconReference(
                    windowsPath: targetPath,
                    iconIndex: iconIndex,
                    workingDirectory: workingDirectory
                )
            )
        }
        return result
    }

    init?(data: Data) {
        let reader = LittleEndianDataReader(data: data)
        guard reader.uint32(at: 0) == UInt32(Self.headerSize),
              reader.bytes(at: 4, count: Self.shellLinkCLSID.count)
                == Self.shellLinkCLSID,
              let flags = reader.uint32(at: 0x14),
              let rawIconIndex = reader.int32(at: 0x38) else {
            return nil
        }

        var cursor = Self.headerSize
        if flags & Self.hasLinkTargetIDList != 0 {
            guard let identifierListSize = reader.uint16(at: cursor),
                  let next = reader.offset(
                    cursor,
                    advancingBy: 2 + Int(identifierListSize)
                  ) else {
                return nil
            }
            cursor = next
        }

        var parsedTargetPath: String?
        if flags & Self.hasLinkInfo != 0 {
            guard let linkInfoSizeValue = reader.uint32(at: cursor) else {
                return nil
            }
            let linkInfoSize = Int(linkInfoSizeValue)
            guard let linkInfoEnd = reader.offset(
                cursor,
                advancingBy: linkInfoSize
            ), let linkInfo = WindowsShellLinkInfo(
                reader: reader,
                offset: cursor,
                endOffset: linkInfoEnd
            ) else {
                return nil
            }
            parsedTargetPath = linkInfo.localTargetPath
            cursor = linkInfoEnd
        }

        let usesUnicode = flags & Self.isUnicode != 0
        var parsedWorkingDirectory: String?
        var parsedIconPath: String?
        let stringFields: [(flag: UInt32, assign: (String) -> Void)] = [
            (Self.hasName, { _ in }),
            (Self.hasRelativePath, { value in
                if parsedTargetPath == nil {
                    parsedTargetPath = value
                }
            }),
            (Self.hasWorkingDirectory, { parsedWorkingDirectory = $0 }),
            (Self.hasArguments, { _ in }),
            (Self.hasIconLocation, { parsedIconPath = $0 }),
        ]
        for field in stringFields where flags & field.flag != 0 {
            guard let parsed = reader.countedString(
                at: cursor,
                unicode: usesUnicode
            ) else {
                return nil
            }
            field.assign(parsed.value)
            cursor = parsed.nextOffset
        }

        targetPath = parsedTargetPath
        iconPath = parsedIconPath
        workingDirectory = parsedWorkingDirectory
        iconIndex = Int(rawIconIndex)
    }
}
private struct WindowsShellLinkInfo {
    let localTargetPath: String?

    init?(
        reader: LittleEndianDataReader,
        offset: Int,
        endOffset: Int
    ) {
        guard let sizeValue = reader.uint32(at: offset),
              let headerSizeValue = reader.uint32(at: offset + 4) else {
            return nil
        }
        let size = Int(sizeValue)
        let headerSize = Int(headerSizeValue)
        guard size >= 0x1C,
              endOffset - offset == size,
              headerSize >= 0x1C,
              headerSize <= size,
              let localBasePathOffsetValue = reader.uint32(at: offset + 16),
              let commonPathSuffixOffsetValue = reader.uint32(at: offset + 24) else {
            return nil
        }

        let unicodeBasePathOffset: Int?
        let unicodeSuffixOffset: Int?
        if headerSize >= 0x24 {
            guard let baseValue = reader.uint32(at: offset + 28),
                  let suffixValue = reader.uint32(at: offset + 32) else {
                return nil
            }
            unicodeBasePathOffset = baseValue == 0 ? nil : Int(baseValue)
            unicodeSuffixOffset = suffixValue == 0 ? nil : Int(suffixValue)
        } else {
            unicodeBasePathOffset = nil
            unicodeSuffixOffset = nil
        }

        let localBasePathOffset = localBasePathOffsetValue == 0
            ? nil
            : Int(localBasePathOffsetValue)
        let commonPathSuffixOffset = commonPathSuffixOffsetValue == 0
            ? nil
            : Int(commonPathSuffixOffsetValue)
        let basePath = unicodeBasePathOffset.flatMap {
            reader.nullTerminatedUTF16String(
                at: offset + $0,
                before: endOffset
            )
        } ?? localBasePathOffset.flatMap {
            reader.nullTerminatedANSIString(
                at: offset + $0,
                before: endOffset
            )
        }
        let suffix = unicodeSuffixOffset.flatMap {
            reader.nullTerminatedUTF16String(
                at: offset + $0,
                before: endOffset
            )
        } ?? commonPathSuffixOffset.flatMap {
            reader.nullTerminatedANSIString(
                at: offset + $0,
                before: endOffset
            )
        }

        localTargetPath = Self.join(basePath: basePath, suffix: suffix)
    }

    private static func join(basePath: String?, suffix: String?) -> String? {
        let base = basePath?.trimmingCharacters(
            in: CharacterSet(charactersIn: "\0")
        )
        let suffix = suffix?.trimmingCharacters(
            in: CharacterSet(charactersIn: "\0")
        )
        guard let base, !base.isEmpty else { return suffix }
        guard let suffix, !suffix.isEmpty else { return base }

        let normalizedBase = base.replacingOccurrences(of: "/", with: #"\"#)
        let normalizedSuffix = suffix.replacingOccurrences(of: "/", with: #"\"#)
        if normalizedBase.caseInsensitiveCompare(normalizedSuffix) == .orderedSame
            || normalizedBase.lowercased().hasSuffix(
                #"\"# + normalizedSuffix.lowercased()
            ) {
            return normalizedBase
        }
        return normalizedBase.trimmingCharacters(
            in: CharacterSet(charactersIn: #"\"#)
        ) + #"\"# + normalizedSuffix.trimmingCharacters(
            in: CharacterSet(charactersIn: #"\"#)
        )
    }
}

private struct LittleEndianDataReader {
    let data: Data

    func uint16(at offset: Int) -> UInt16? {
        guard let first = byte(at: offset),
              let second = byte(at: offset + 1) else {
            return nil
        }
        return UInt16(first) | (UInt16(second) << 8)
    }

    func uint32(at offset: Int) -> UInt32? {
        guard let first = uint16(at: offset),
              let second = uint16(at: offset + 2) else {
            return nil
        }
        return UInt32(first) | (UInt32(second) << 16)
    }

    func int32(at offset: Int) -> Int32? {
        uint32(at: offset).map(Int32.init(bitPattern:))
    }

    func bytes(at offset: Int, count: Int) -> [UInt8]? {
        guard let end = self.offset(offset, advancingBy: count) else {
            return nil
        }
        let startIndex = data.index(data.startIndex, offsetBy: offset)
        let endIndex = data.index(data.startIndex, offsetBy: end)
        return Array(data[startIndex..<endIndex])
    }

    func offset(_ offset: Int, advancingBy byteCount: Int) -> Int? {
        guard offset >= 0,
              byteCount >= 0,
              offset <= data.count,
              byteCount <= data.count - offset else {
            return nil
        }
        return offset + byteCount
    }

    func countedString(
        at offset: Int,
        unicode: Bool
    ) -> (value: String, nextOffset: Int)? {
        guard let characterCountValue = uint16(at: offset) else { return nil }
        let characterCount = Int(characterCountValue)
        let byteCount: Int
        if unicode {
            guard characterCount <= (data.count - offset - 2) / 2 else {
                return nil
            }
            byteCount = characterCount * 2
        } else {
            byteCount = characterCount
        }
        guard let stringOffset = self.offset(offset, advancingBy: 2),
              let nextOffset = self.offset(
                stringOffset,
                advancingBy: byteCount
              ), let rawBytes = bytes(at: stringOffset, count: byteCount),
              let value = unicode
                ? decodeUTF16(rawBytes)
                : decodeANSI(rawBytes) else {
            return nil
        }
        return (
            value.trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
            nextOffset
        )
    }

    func nullTerminatedUTF16String(
        at offset: Int,
        before endOffset: Int
    ) -> String? {
        guard offset >= 0,
              endOffset <= data.count,
              offset < endOffset,
              (endOffset - offset).isMultiple(of: 2) else {
            return nil
        }
        var cursor = offset
        while cursor + 1 < endOffset {
            guard let value = uint16(at: cursor) else { return nil }
            if value == 0 {
                guard let rawBytes = bytes(
                    at: offset,
                    count: cursor - offset
                ) else {
                    return nil
                }
                return decodeUTF16(rawBytes)
            }
            cursor += 2
        }
        return nil
    }

    func nullTerminatedANSIString(
        at offset: Int,
        before endOffset: Int
    ) -> String? {
        guard offset >= 0,
              endOffset <= data.count,
              offset < endOffset else {
            return nil
        }
        var cursor = offset
        while cursor < endOffset {
            guard let value = byte(at: cursor) else { return nil }
            if value == 0 {
                guard let rawBytes = bytes(
                    at: offset,
                    count: cursor - offset
                ) else {
                    return nil
                }
                return decodeANSI(rawBytes)
            }
            cursor += 1
        }
        return nil
    }

    private func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.index(data.startIndex, offsetBy: offset)]
    }

    private func decodeUTF16(_ bytes: [UInt8]) -> String? {
        guard bytes.count.isMultiple(of: 2) else { return nil }
        return String(data: Data(bytes), encoding: .utf16LittleEndian)
    }

    private func decodeANSI(_ bytes: [UInt8]) -> String? {
        guard bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }
}
