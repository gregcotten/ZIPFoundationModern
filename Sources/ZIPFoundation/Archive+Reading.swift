//
//  Archive+Reading.swift
//  ZIPFoundation
//
//  Copyright © 2017-2021 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import Foundation
import CSProgress

public extension Archive {
    /// Read a ZIP `Entry` from the receiver and write it to `url`.
    ///
    /// - Parameters:
    ///   - entry: The ZIP `Entry` to read.
    ///   - url: The destination file URL.
    ///   - bufferSize: The maximum size of the read buffer and the decompression buffer (if needed).
    ///   - skipCRC32: Optional flag to skip calculation of the CRC32 checksum to improve performance.
    ///   - progress: A progress object that can be used to track or cancel the extract operation.
    /// - Returns: The checksum of the processed content or 0 if the `skipCRC32` flag was set to `true`.
    /// - Throws: An error if the destination file cannot be written or the entry contains malformed content.
    func extract(_ entry: Entry, to url: URL, bufferSize: Int = defaultReadChunkSize, skipCRC32: Bool = false,
                 progress: CSProgress? = nil) throws -> CRC32
    {
        guard bufferSize > 0 else {
            throw ArchiveError.invalidBufferSize
        }
        let fileManager = FileManager()
        var checksum = CRC32(0)
        switch entry.type {
        case .file:
            guard !fileManager.itemExists(at: url) else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
            }
            try fileManager.createParentDirectoryStructure(for: url)
            guard let destinationFile = try? ArchiveHandle(forWriteUpdate: url) else {
                throw CocoaError(.fileNoSuchFile)
            }
            defer { try? destinationFile.close() }
            let consumer = { _ = try Data.write(chunk: $0, to: destinationFile) }
            checksum = try extract(entry, bufferSize: bufferSize, skipCRC32: skipCRC32,
                                   progress: progress, consumer: consumer)
        case .directory:
            let consumer = { (_: Data) in
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            }
            checksum = try extract(entry, bufferSize: bufferSize, skipCRC32: skipCRC32,
                                   progress: progress, consumer: consumer)
        case .symlink:
            guard !fileManager.itemExists(at: url) else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
            }
            let consumer = { (data: Data) in
                guard let linkPath = String(data: data, encoding: .utf8) else { throw ArchiveError.invalidEntryPath }
                try fileManager.createParentDirectoryStructure(for: url)
                try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: linkPath)
            }
            checksum = try extract(entry, bufferSize: bufferSize, skipCRC32: skipCRC32,
                                   progress: progress, consumer: consumer)
        }

        // FileManager.setAttributes can apply target-style attributes through symlinks.
        // That is not useful for the symlink itself and can fail for symlink chains
        // whose targets are created by later symlink entries.
        guard entry.type != .symlink else { return checksum }

        #if os(Windows)
            try? fileManager.setAttributes(entry.fileAttributes, ofItemAtPath: url.path)
        #else
            try fileManager.setAttributes(entry.fileAttributes, ofItemAtPath: url.path)
        #endif

        return checksum
    }

    /// Read a ZIP `Entry` from the receiver and forward its contents to a `Consumer` closure.
    ///
    /// - Parameters:
    ///   - entry: The ZIP `Entry` to read.
    ///   - bufferSize: The maximum size of the read buffer and the decompression buffer (if needed).
    ///   - skipCRC32: Optional flag to skip calculation of the CRC32 checksum to improve performance.
    ///   - progress: A progress object that can be used to track or cancel the extract operation.
    ///   - consumer: A closure that consumes contents of `Entry` as `Data` chunks.
    /// - Returns: The checksum of the processed content or 0 if the `skipCRC32` flag was set to `true`..
    /// - Throws: An error if the destination file cannot be written or the entry contains malformed content.
    func extract(_ entry: Entry, bufferSize: Int = defaultReadChunkSize, skipCRC32: Bool = false,
                 progress: CSProgress? = nil, consumer: Consumer) throws -> CRC32
    {
        guard bufferSize > 0 else {
            throw ArchiveError.invalidBufferSize
        }
        var checksum = CRC32(0)
        let localFileHeader = entry.localFileHeader
        guard entry.dataOffset <= .max else { throw ArchiveError.invalidLocalHeaderDataOffset }
        try archiveFile.seek(toOffset: entry.dataOffset)
        progress?.totalUnitCount = totalUnitCountForReading(entry)
        switch entry.type {
        case .file:
            guard let compressionMethod = CompressionMethod(rawValue: localFileHeader.compressionMethod) else {
                throw ArchiveError.invalidCompressionMethod
            }
            switch compressionMethod {
            case .none: checksum = try readUncompressed(entry: entry, bufferSize: bufferSize,
                                                        skipCRC32: skipCRC32, progress: progress, with: consumer)
            case .deflate: checksum = try readCompressed(entry: entry, bufferSize: bufferSize,
                                                         skipCRC32: skipCRC32, progress: progress, with: consumer)
            }
        case .directory:
            try consumer(Data())
            progress?.completedUnitCount = totalUnitCountForReading(entry)
        case .symlink:
            let localFileHeader = entry.localFileHeader
            let size = Int(localFileHeader.compressedSize)
            let data = try Data.readChunk(of: size, from: archiveFile)
            checksum = data.crc32(checksum: 0)
            try consumer(data)
            progress?.completedUnitCount = totalUnitCountForReading(entry)
        }
        return checksum
    }
}
