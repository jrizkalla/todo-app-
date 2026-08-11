import Foundation
import Compression

/// A minimal ZIP reader and writer.
///
/// The export format is a zip because that is what the user opens on any
/// platform without a tool — Finder, Files, Windows Explorer, and every
/// scripting language's standard library all read it. Foundation ships no zip
/// API (`AppleArchive` writes `.aar`, which none of those open), so the
/// container is written here directly over `Compression`'s raw DEFLATE.
///
/// Only the subset the archive needs is implemented: no encryption, no spanning,
/// no zip64. That is a real limit — an archive over 4 GB, or with more than
/// 65,535 entries, cannot be written — but a to-do database reaching either is
/// not a case worth carrying the extra format complexity for. `ZipWriter.build`
/// reports `entryLimitExceeded` rather than emitting a file that claims to be a
/// zip and is not.
///
/// The reader is deliberately more permissive than the writer, for the same
/// reason the YAML parser is: an archive that has been through a cloud sync, a
/// rename, or another tool's rewrite should still give up its files.
enum Zip {

    /// Uncompressed, or DEFLATE.
    ///
    /// Stored entries exist because DEFLATE can inflate incompressible data;
    /// the writer picks whichever is smaller per entry.
    enum Method: UInt16 {
        case stored = 0
        case deflate = 8
    }

    struct Entry {
        var path: String
        var data: Data
    }

    enum ZipError: LocalizedError {
        case notAZipArchive
        case centralDirectoryUnreadable
        case entryLimitExceeded
        case entryTooLarge(path: String)

        var errorDescription: String? {
            switch self {
            case .notAZipArchive:
                "This file is not a zip archive."
            case .centralDirectoryUnreadable:
                "The zip archive's directory is damaged and could not be read."
            case .entryLimitExceeded:
                "The archive has too many files to write (limit 65,535)."
            case .entryTooLarge(let path):
                "‘\(path)’ is larger than the 4 GB limit for this archive format."
            }
        }
    }
}

// MARK: - Writing

enum ZipWriter {

    /// Build a zip archive containing `entries`.
    ///
    /// Entries are written in the order given, each followed by a central
    /// directory record at the end, per the PKWARE APPNOTE layout.
    static func build(_ entries: [Zip.Entry]) throws -> Data {
        guard entries.count <= 0xFFFF else { throw Zip.ZipError.entryLimitExceeded }

        var payload = Data()
        var directory = Data()

        for entry in entries {
            guard entry.data.count <= 0xFFFF_FFFF else {
                throw Zip.ZipError.entryTooLarge(path: entry.path)
            }

            let name = Data(entry.path.utf8)
            let crc = CRC32.checksum(entry.data)
            let localHeaderOffset = UInt32(payload.count)

            // Compress, but keep the original when DEFLATE does not pay for
            // itself — which is the normal outcome for very short files.
            let deflated = Deflate.compress(entry.data)
            let method: Zip.Method
            let stored: Data
            if let deflated, deflated.count < entry.data.count {
                method = .deflate
                stored = deflated
            } else {
                method = .stored
                stored = entry.data
            }

            // Local file header.
            payload.append(uint32: 0x0403_4B50)
            payload.append(uint16: 20)                      // version needed
            payload.append(uint16: 0x0800)                  // UTF-8 name flag
            payload.append(uint16: method.rawValue)
            payload.append(uint16: 0)                       // mod time
            payload.append(uint16: 0)                       // mod date
            payload.append(uint32: crc)
            payload.append(uint32: UInt32(stored.count))
            payload.append(uint32: UInt32(entry.data.count))
            payload.append(uint16: UInt16(name.count))
            payload.append(uint16: 0)                       // extra length
            payload.append(name)
            payload.append(stored)

            // Central directory record.
            directory.append(uint32: 0x0201_4B50)
            directory.append(uint16: 20)                    // version made by
            directory.append(uint16: 20)                    // version needed
            directory.append(uint16: 0x0800)
            directory.append(uint16: method.rawValue)
            directory.append(uint16: 0)
            directory.append(uint16: 0)
            directory.append(uint32: crc)
            directory.append(uint32: UInt32(stored.count))
            directory.append(uint32: UInt32(entry.data.count))
            directory.append(uint16: UInt16(name.count))
            directory.append(uint16: 0)                     // extra
            directory.append(uint16: 0)                     // comment
            directory.append(uint16: 0)                     // disk number
            directory.append(uint16: 0)                     // internal attrs
            directory.append(uint32: 0)                     // external attrs
            directory.append(uint32: localHeaderOffset)
            directory.append(name)
        }

        var archive = payload
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)

        // End of central directory.
        archive.append(uint32: 0x0605_4B50)
        archive.append(uint16: 0)                           // this disk
        archive.append(uint16: 0)                           // directory's disk
        archive.append(uint16: UInt16(entries.count))
        archive.append(uint16: UInt16(entries.count))
        archive.append(uint32: UInt32(directory.count))
        archive.append(uint32: directoryOffset)
        archive.append(uint16: 0)                           // comment length

        return archive
    }
}

// MARK: - Reading

enum ZipReader {

    /// Read every entry out of a zip archive.
    ///
    /// Walks the central directory, which is the authoritative index — scanning
    /// for local headers instead would misread any archive whose entries were
    /// rewritten in place by another tool.
    ///
    /// A single unreadable entry is skipped rather than failing the archive: the
    /// import above this is built to work from whatever files it does get, so
    /// one damaged record should cost the user that record and nothing more.
    static func entries(in archive: Data) throws -> [Zip.Entry] {
        guard archive.count >= 22 else { throw Zip.ZipError.notAZipArchive }

        guard let endOffset = locateEndOfCentralDirectory(in: archive) else {
            throw Zip.ZipError.notAZipArchive
        }

        let entryCount = Int(archive.uint16(at: endOffset + 10) ?? 0)
        guard var cursor = archive.uint32(at: endOffset + 16).map(Int.init) else {
            throw Zip.ZipError.centralDirectoryUnreadable
        }

        var results: [Zip.Entry] = []
        // Bounded by the declared count, but the signature check below is what
        // actually terminates the walk on a truncated directory.
        for _ in 0..<entryCount {
            guard cursor + 46 <= archive.count,
                  archive.uint32(at: cursor) == 0x0201_4B50
            else { break }

            let method = archive.uint16(at: cursor + 10) ?? 0
            let compressedSize = Int(archive.uint32(at: cursor + 20) ?? 0)
            let nameLength = Int(archive.uint16(at: cursor + 28) ?? 0)
            let extraLength = Int(archive.uint16(at: cursor + 30) ?? 0)
            let commentLength = Int(archive.uint16(at: cursor + 32) ?? 0)
            let localOffset = Int(archive.uint32(at: cursor + 42) ?? 0)

            let nameStart = cursor + 46
            guard nameStart + nameLength <= archive.count else { break }
            let name = String(
                decoding: archive.slice(at: nameStart, count: nameLength) ?? Data(),
                as: UTF8.self
            )

            cursor = nameStart + nameLength + extraLength + commentLength

            // Directory entries carry no payload.
            if name.hasSuffix("/") { continue }

            if let data = payload(
                in: archive,
                localHeaderOffset: localOffset,
                method: method,
                compressedSize: compressedSize
            ) {
                results.append(Zip.Entry(path: name, data: data))
            }
        }

        return results
    }

    /// Extract one entry's bytes, reading the name and extra lengths from the
    /// local header — they may legitimately differ from the central directory's.
    private static func payload(
        in archive: Data,
        localHeaderOffset: Int,
        method: UInt16,
        compressedSize: Int
    ) -> Data? {
        guard localHeaderOffset >= 0,
              localHeaderOffset + 30 <= archive.count,
              archive.uint32(at: localHeaderOffset) == 0x0403_4B50
        else { return nil }

        let nameLength = Int(archive.uint16(at: localHeaderOffset + 26) ?? 0)
        let extraLength = Int(archive.uint16(at: localHeaderOffset + 28) ?? 0)
        let start = localHeaderOffset + 30 + nameLength + extraLength

        guard let raw = archive.slice(at: start, count: compressedSize) else { return nil }

        switch method {
        case Zip.Method.stored.rawValue:
            return raw
        case Zip.Method.deflate.rawValue:
            return Deflate.decompress(raw)
        default:
            // An entry compressed with something this reader does not
            // implement (bzip2, LZMA) — skipped, not fatal.
            return nil
        }
    }

    /// Find the end-of-central-directory record.
    ///
    /// It sits at the end of the file, but a trailing comment may follow it, so
    /// the signature is searched for backwards over the maximum comment length.
    private static func locateEndOfCentralDirectory(in archive: Data) -> Int? {
        let minimumRecord = 22
        let searchLimit = min(archive.count, minimumRecord + 0xFFFF)
        let lowest = archive.count - searchLimit

        var offset = archive.count - minimumRecord
        while offset >= lowest {
            if archive.uint32(at: offset) == 0x0605_4B50 { return offset }
            offset -= 1
        }
        return nil
    }
}

// MARK: - DEFLATE

/// Raw DEFLATE, which is the compression ZIP method 8 stores.
///
/// `Compression`'s `COMPRESSION_ZLIB` algorithm is raw deflate with no zlib
/// wrapper, which is exactly what belongs in a zip entry.
private enum Deflate {

    /// Working buffer for the streaming loop.
    ///
    /// Fixed rather than sized from the entry, because on the decode side the
    /// only available estimate is the archive's own declared uncompressed size —
    /// a number a corrupt or hostile file controls. Trusting it meant a entry
    /// claiming 4 GB allocated 4 GB up front. The loop below drains the stream
    /// in as many passes as it takes, so the buffer never needs to hold the
    /// whole result anyway.
    private static let bufferSize = 64 * 1024

    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        return perform(data, operation: COMPRESSION_STREAM_ENCODE)
    }

    static func decompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        return perform(data, operation: COMPRESSION_STREAM_DECODE)
    }

    private static func perform(
        _ input: Data,
        operation: compression_stream_operation
    ) -> Data? {
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }

        guard compression_stream_init(
            streamPointer, operation, COMPRESSION_ZLIB
        ) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(streamPointer) }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data()

        let succeeded = input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }

            streamPointer.pointee.src_ptr = base
            streamPointer.pointee.src_size = input.count

            repeat {
                streamPointer.pointee.dst_ptr = buffer
                streamPointer.pointee.dst_size = bufferSize

                let status = compression_stream_process(
                    streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )

                let produced = bufferSize - streamPointer.pointee.dst_size
                if produced > 0 { output.append(buffer, count: produced) }

                switch status {
                case COMPRESSION_STATUS_END:
                    return true
                case COMPRESSION_STATUS_OK:
                    // Output buffer filled; go round again for the rest.
                    continue
                default:
                    return false
                }
            } while true
        }

        return succeeded ? output : nil
    }
}

// MARK: - CRC32

/// ZIP stores a CRC-32 per entry, and readers that check it reject an archive
/// whose value is wrong — so it has to be real, not zero.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in
            value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Byte access

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func append(uint32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    /// Little-endian reads that answer nil rather than trapping when the offset
    /// runs past the end — every field the reader parses comes from a file that
    /// may be truncated.
    ///
    /// Offsets are relative to `startIndex`, so these stay correct on a `Data`
    /// that is itself a slice.
    func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }

    /// A copy of `count` bytes at `offset`, re-based to zero so callers can index
    /// it from the start.
    func slice(at offset: Int, count length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset + length <= count else { return nil }
        let base = startIndex + offset
        return Data(self[base..<(base + length)])
    }
}
