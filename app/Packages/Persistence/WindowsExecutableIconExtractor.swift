import Foundation

public enum WindowsExecutableIconExtractor {
    public static func iconData(at executableURL: URL) -> Data? {
        guard let values = try? executableURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= Int(UInt32.max),
              let data = try? Data(contentsOf: executableURL, options: [.mappedIfSafe]) else {
            return nil
        }
        return iconData(from: data)
    }

    public static func iconData(from executableData: Data) -> Data? {
        PEIconParser(data: executableData)?.bestIconData()
    }
}

private struct PEIconParser {
    private static let maximumCollectedResourceBytes = 32 * 1_024 * 1_024
    private static let maximumSingleResourceBytes = 16 * 1_024 * 1_024
    private static let maximumReconstructedIconBytes = 8 * 1_024 * 1_024

    private struct Section {
        let virtualAddress: Int
        let virtualSize: Int
        let rawOffset: Int
        let rawSize: Int
    }

    private struct ResourceEntry {
        let id: Int
        let targetOffset: Int
        let isDirectory: Bool
    }

    private struct GroupIconEntry {
        let width: UInt8
        let height: UInt8
        let colorCount: UInt8
        let reserved: UInt8
        let planes: UInt16
        let bitCount: UInt16
        let imageData: Data

        var pixelDimension: Int {
            max(width == 0 ? 256 : Int(width), height == 0 ? 256 : Int(height))
        }
    }

    private let data: Data
    private let sections: [Section]
    private let resourceRootOffset: Int
    private let resourceSize: Int

    init?(data: Data) {
        self.data = data
        guard data.count >= 64,
              Self.uint16(in: data, at: 0) == 0x5A4D,
              let peOffsetValue = Self.uint32(in: data, at: 0x3C) else {
            return nil
        }

        let peOffset = Int(peOffsetValue)
        guard Self.uint32(in: data, at: peOffset) == 0x0000_4550,
              let sectionCountValue = Self.uint16(in: data, at: peOffset + 6),
              let optionalHeaderSizeValue = Self.uint16(in: data, at: peOffset + 20) else {
            return nil
        }

        let sectionCount = Int(sectionCountValue)
        let optionalHeaderSize = Int(optionalHeaderSizeValue)
        guard sectionCount > 0, sectionCount <= 96 else { return nil }

        let optionalHeaderOffset = peOffset + 24
        guard let magic = Self.uint16(in: data, at: optionalHeaderOffset) else { return nil }
        let dataDirectoryOffset: Int
        switch magic {
        case 0x10B:
            dataDirectoryOffset = optionalHeaderOffset + 96
        case 0x20B:
            dataDirectoryOffset = optionalHeaderOffset + 112
        default:
            return nil
        }

        let resourceDirectoryOffset = dataDirectoryOffset + (2 * 8)
        guard resourceDirectoryOffset + 8 <= optionalHeaderOffset + optionalHeaderSize,
              let resourceRVAValue = Self.uint32(in: data, at: resourceDirectoryOffset),
              let resourceSizeValue = Self.uint32(in: data, at: resourceDirectoryOffset + 4),
              resourceRVAValue > 0,
              resourceSizeValue > 0,
              resourceSizeValue <= 64 * 1_024 * 1_024 else {
            return nil
        }

        let sectionTableOffset = optionalHeaderOffset + optionalHeaderSize
        var parsedSections: [Section] = []
        parsedSections.reserveCapacity(sectionCount)
        for index in 0..<sectionCount {
            let offset = sectionTableOffset + (index * 40)
            guard let virtualSize = Self.uint32(in: data, at: offset + 8),
                  let virtualAddress = Self.uint32(in: data, at: offset + 12),
                  let rawSize = Self.uint32(in: data, at: offset + 16),
                  let rawOffset = Self.uint32(in: data, at: offset + 20) else {
                return nil
            }
            parsedSections.append(
                Section(
                    virtualAddress: Int(virtualAddress),
                    virtualSize: Int(virtualSize),
                    rawOffset: Int(rawOffset),
                    rawSize: Int(rawSize)
                )
            )
        }

        guard let rootOffset = Self.fileOffset(
            forRVA: Int(resourceRVAValue),
            byteCount: 16,
            sections: parsedSections,
            dataCount: data.count
        ) else {
            return nil
        }

        sections = parsedSections
        resourceRootOffset = rootOffset
        resourceSize = Int(resourceSizeValue)
    }

    func bestIconData() -> Data? {
        let icons = resources(ofType: 3)
        let groups = resources(ofType: 14)
        guard !icons.isEmpty, !groups.isEmpty else { return nil }

        var best: (score: Int, resourceID: Int, data: Data)?
        for (resourceID, groupData) in groups {
            guard let entries = groupEntries(from: groupData, icons: icons),
                  let iconData = makeIconFile(from: entries) else {
                continue
            }
            let largestDimension = entries.map(\.pixelDimension).max() ?? 0
            let score = (largestDimension * largestDimension * 1_000) + entries.count
            if best == nil
                || score > best!.score
                || (score == best!.score && resourceID < best!.resourceID)
            {
                best = (score, resourceID, iconData)
            }
        }
        return best?.data
    }

    private func resources(ofType typeID: Int) -> [Int: Data] {
        guard let typeEntry = directoryEntries(relativeOffset: 0)
            .first(where: { $0.id == typeID && $0.isDirectory }) else {
            return [:]
        }

        var result: [Int: Data] = [:]
        var cachedDataByEntryOffset: [Int: Data] = [:]
        var collectedByteCount = 0
        for nameEntry in directoryEntries(relativeOffset: typeEntry.targetOffset) {
            guard let dataEntryOffset = firstDataEntryOffset(for: nameEntry, depth: 0) else {
                continue
            }
            let resolvedData: Data
            if let cachedData = cachedDataByEntryOffset[dataEntryOffset] {
                resolvedData = cachedData
            } else {
                guard let parsedData = resourceData(at: dataEntryOffset),
                      parsedData.count <= Self.maximumCollectedResourceBytes - collectedByteCount else {
                    continue
                }
                resolvedData = parsedData
                cachedDataByEntryOffset[dataEntryOffset] = parsedData
                collectedByteCount += parsedData.count
            }
            result[nameEntry.id] = resolvedData
        }
        return result
    }

    private func firstDataEntryOffset(for entry: ResourceEntry, depth: Int) -> Int? {
        if !entry.isDirectory {
            return entry.targetOffset
        }
        guard depth < 3 else { return nil }
        for child in directoryEntries(relativeOffset: entry.targetOffset) {
            if let result = firstDataEntryOffset(for: child, depth: depth + 1) {
                return result
            }
        }
        return nil
    }

    private func directoryEntries(relativeOffset: Int) -> [ResourceEntry] {
        guard relativeOffset >= 0,
              relativeOffset <= resourceSize - 16,
              let namedCount = Self.uint16(in: data, at: resourceRootOffset + relativeOffset + 12),
              let identifierCount = Self.uint16(in: data, at: resourceRootOffset + relativeOffset + 14) else {
            return []
        }

        let entryCount = Int(namedCount) + Int(identifierCount)
        guard entryCount <= 1_024,
              relativeOffset + 16 + (entryCount * 8) <= resourceSize else {
            return []
        }

        var entries: [ResourceEntry] = []
        entries.reserveCapacity(Int(identifierCount))
        let entriesOffset = resourceRootOffset + relativeOffset + 16
        for index in 0..<entryCount {
            let offset = entriesOffset + (index * 8)
            guard let name = Self.uint32(in: data, at: offset),
                  let target = Self.uint32(in: data, at: offset + 4),
                  name & 0x8000_0000 == 0 else {
                continue
            }
            entries.append(
                ResourceEntry(
                    id: Int(name),
                    targetOffset: Int(target & 0x7FFF_FFFF),
                    isDirectory: target & 0x8000_0000 != 0
                )
            )
        }
        return entries
    }

    private func resourceData(at dataEntryOffset: Int) -> Data? {
        guard dataEntryOffset >= 0,
              dataEntryOffset <= resourceSize - 16 else {
            return nil
        }
        let offset = resourceRootOffset + dataEntryOffset
        guard let dataRVA = Self.uint32(in: data, at: offset),
              let byteCountValue = Self.uint32(in: data, at: offset + 4),
              byteCountValue > 0,
              byteCountValue <= Self.maximumSingleResourceBytes else {
            return nil
        }
        let byteCount = Int(byteCountValue)
        guard let fileOffset = Self.fileOffset(
            forRVA: Int(dataRVA),
            byteCount: byteCount,
            sections: sections,
            dataCount: data.count
        ) else {
            return nil
        }
        return Self.bytes(in: data, at: fileOffset, count: byteCount)
    }

    private func groupEntries(from groupData: Data, icons: [Int: Data]) -> [GroupIconEntry]? {
        guard Self.uint16(in: groupData, at: 0) == 0,
              Self.uint16(in: groupData, at: 2) == 1,
              let entryCountValue = Self.uint16(in: groupData, at: 4) else {
            return nil
        }
        let entryCount = Int(entryCountValue)
        guard entryCount > 0,
              entryCount <= 256,
              6 + (entryCount * 14) <= groupData.count else {
            return nil
        }

        var entries: [GroupIconEntry] = []
        entries.reserveCapacity(entryCount)
        for index in 0..<entryCount {
            let offset = 6 + (index * 14)
            guard let width = Self.uint8(in: groupData, at: offset),
                  let height = Self.uint8(in: groupData, at: offset + 1),
                  let colorCount = Self.uint8(in: groupData, at: offset + 2),
                  let reserved = Self.uint8(in: groupData, at: offset + 3),
                  let planes = Self.uint16(in: groupData, at: offset + 4),
                  let bitCount = Self.uint16(in: groupData, at: offset + 6),
                  let iconID = Self.uint16(in: groupData, at: offset + 12),
                  let imageData = icons[Int(iconID)],
                  !imageData.isEmpty,
                  imageData.count <= Int(UInt32.max) else {
                continue
            }
            entries.append(
                GroupIconEntry(
                    width: width,
                    height: height,
                    colorCount: colorCount,
                    reserved: reserved,
                    planes: planes,
                    bitCount: bitCount,
                    imageData: imageData
                )
            )
        }
        return entries.isEmpty ? nil : entries
    }

    private func makeIconFile(from entries: [GroupIconEntry]) -> Data? {
        guard entries.count <= Int(UInt16.max) else { return nil }
        let directoryByteCount = 6 + (entries.count * 16)
        guard directoryByteCount <= Self.maximumReconstructedIconBytes else { return nil }
        var outputByteCount = directoryByteCount
        for entry in entries {
            guard entry.imageData.count <= Self.maximumReconstructedIconBytes - outputByteCount else {
                return nil
            }
            outputByteCount += entry.imageData.count
        }

        var output = Data()
        output.reserveCapacity(outputByteCount)
        Self.append(UInt16(0), to: &output)
        Self.append(UInt16(1), to: &output)
        Self.append(UInt16(entries.count), to: &output)

        var imageOffset = directoryByteCount
        for entry in entries {
            guard imageOffset <= Int(UInt32.max) else { return nil }
            output.append(entry.width)
            output.append(entry.height)
            output.append(entry.colorCount)
            output.append(entry.reserved)
            Self.append(entry.planes, to: &output)
            Self.append(entry.bitCount, to: &output)
            Self.append(UInt32(entry.imageData.count), to: &output)
            Self.append(UInt32(imageOffset), to: &output)
            imageOffset += entry.imageData.count
        }

        for entry in entries {
            output.append(entry.imageData)
        }
        return output
    }

    private static func fileOffset(
        forRVA rva: Int,
        byteCount: Int,
        sections: [Section],
        dataCount: Int
    ) -> Int? {
        guard rva >= 0, byteCount >= 0 else { return nil }
        for section in sections {
            let span = max(section.virtualSize, section.rawSize)
            guard rva >= section.virtualAddress,
                  rva - section.virtualAddress <= span else {
                continue
            }
            let delta = rva - section.virtualAddress
            guard delta <= section.rawSize,
                  byteCount <= section.rawSize - delta else {
                continue
            }
            let offset = section.rawOffset + delta
            guard offset >= 0,
                  offset <= dataCount,
                  byteCount <= dataCount - offset else {
                return nil
            }
            return offset
        }
        return nil
    }

    private static func uint8(in data: Data, at offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[offset]
    }

    private static func uint16(in data: Data, at offset: Int) -> UInt16? {
        guard let first = uint8(in: data, at: offset),
              let second = uint8(in: data, at: offset + 1) else {
            return nil
        }
        return UInt16(first) | (UInt16(second) << 8)
    }

    private static func uint32(in data: Data, at offset: Int) -> UInt32? {
        guard let lower = uint16(in: data, at: offset),
              let upper = uint16(in: data, at: offset + 2) else {
            return nil
        }
        return UInt32(lower) | (UInt32(upper) << 16)
    }

    private static func bytes(in data: Data, at offset: Int, count: Int) -> Data? {
        guard offset >= 0,
              count >= 0,
              offset <= data.count,
              count <= data.count - offset else {
            return nil
        }
        return Data(data[offset..<(offset + count)])
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
