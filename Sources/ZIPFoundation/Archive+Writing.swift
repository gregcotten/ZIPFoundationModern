//
//  Archive+Writing.swift
//  ZIPFoundation
//
//  Copyright © 2017-2021 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import Foundation
import SystemPackage
import CSProgress

public extension Archive {
    internal enum ModifyOperation: Int {
        case remove = -1
        case add = 1
    }

    internal typealias EndOfCentralDirectoryStructure = (EndOfCentralDirectoryRecord, ZIP64EndOfCentralDirectory?)

    /// Write files, directories or symlinks to the receiver.
    ///
    /// - Parameters:
    ///   - path: The path that is used to identify an `Entry` within the `Archive` file.
    ///   - baseURL: The base URL of the resource to add.
    ///              The `baseURL` combined with `path` must form a fully qualified file URL.
    ///   - compressionMethod: Indicates the `CompressionMethod` that should be applied to `Entry`.
    ///                        By default, no compression will be applied.
    ///   - bufferSize: The maximum size of the write buffer and the compression buffer (if needed).
    ///   - progress: A progress object that can be used to track or cancel the add operation.
    /// - Throws: An error if the source file cannot be read or the receiver is not writable.
    func addEntry(with path: String, relativeTo baseURL: URL,
                  compressionMethod: CompressionMethod = .none,
                  bufferSize: Int = defaultWriteChunkSize, progress: CSProgress? = nil) throws
    {
        let fileURL = baseURL.appendingPathComponent(path)

        try addEntry(with: path, fileURL: fileURL, compressionMethod: compressionMethod,
                     bufferSize: bufferSize, progress: progress)
    }

    /// Write files, directories or symlinks to the receiver.
    ///
    /// - Parameters:
    ///   - path: The path that is used to identify an `Entry` within the `Archive` file.
    ///   - fileURL: An absolute file URL referring to the resource to add.
    ///   - compressionMethod: Indicates the `CompressionMethod` that should be applied to `Entry`.
    ///                        By default, no compression will be applied.
    ///   - bufferSize: The maximum size of the write buffer and the compression buffer (if needed).
    ///   - progress: A progress object that can be used to track or cancel the add operation.
    /// - Throws: An error if the source file cannot be read or the receiver is not writable.
    func addEntry(with path: String, fileURL: URL, compressionMethod: CompressionMethod = .none,
                  bufferSize: Int = defaultWriteChunkSize, progress: CSProgress? = nil) throws
    {
        let fileManager = FileManager()
        guard fileManager.itemExists(at: fileURL) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
        let type = try fileManager.fileTypeForItem(at: fileURL).entryType
        // symlinks do not need to be readable
        guard type == .symlink || fileManager.isReadableFile(atPath: fileURL.path) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        let modDate = try fileManager.fileModificationDateTimeForItem(at: fileURL)
        let uncompressedSize = type == .directory ? 0 : Int64(try fileManager.fileSizeForItem(at: fileURL))
        let permissions = try fileManager.permissionsForItem(at: fileURL)
        var provider: Provider
        switch type {
        case .file:
            guard let entryFile = try? ArchiveHandle(forReadingFrom: fileURL) else {
                throw CocoaError(.fileNoSuchFile)
            }
            defer { try? entryFile.close() }
            provider = { _, _ in try Data.readChunk(of: bufferSize, from: entryFile) }
            try addEntry(with: path, type: type, uncompressedSize: uncompressedSize,
                         modificationDate: modDate, permissions: permissions,
                         compressionMethod: compressionMethod, bufferSize: bufferSize,
                         progress: progress, provider: provider)
        case .directory:
            provider = { _, _ in Data() }
            try addEntry(with: path.hasSuffix("/") ? path : path + "/",
                         type: type, uncompressedSize: uncompressedSize,
                         modificationDate: modDate, permissions: permissions,
                         compressionMethod: compressionMethod, bufferSize: bufferSize,
                         progress: progress, provider: provider)
        case .symlink:
            provider = { _, _ -> Data in
                let linkDestination = try fileManager.destinationOfSymbolicLink(atPath: fileURL.path)
                let linkFileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: linkDestination)
                let linkLength = Int(strlen(linkFileSystemRepresentation))
                let linkBuffer = UnsafeBufferPointer(start: linkFileSystemRepresentation, count: linkLength)
                return Data(buffer: linkBuffer)
            }
            try addEntry(with: path, type: type, uncompressedSize: uncompressedSize,
                         modificationDate: modDate, permissions: permissions,
                         compressionMethod: compressionMethod, bufferSize: bufferSize,
                         progress: progress, provider: provider)
        }
    }

    /// Write files, directories or symlinks to the receiver.
    ///
    /// - Parameters:
    ///   - path: The path that is used to identify an `Entry` within the `Archive` file.
    ///   - type: Indicates the `Entry.EntryType` of the added content.
    ///   - uncompressedSize: The uncompressed size of the data that is going to be added with `provider`.
    ///   - modificationDate: A `Date` describing the file modification date of the `Entry`.
    ///                       Default is the current `Date`.
    ///   - permissions: POSIX file permissions for the `Entry`.
    ///                  Default is `0`o`644` for files and symlinks and `0`o`755` for directories.
    ///   - compressionMethod: Indicates the `CompressionMethod` that should be applied to `Entry`.
    ///                        By default, no compression will be applied.
    ///   - bufferSize: The maximum size of the write buffer and the compression buffer (if needed).
    ///   - progress: A progress object that can be used to track or cancel the add operation.
    ///   - provider: A closure that accepts a position and a chunk size. Returns a `Data` chunk.
    /// - Throws: An error if the source data is invalid or the receiver is not writable.
    func addEntry(with path: String, type: Entry.EntryType, uncompressedSize: Int64,
                  modificationDate: Date = Date(), permissions: FilePermissions? = nil,
                  compressionMethod: CompressionMethod = .none, bufferSize: Int = defaultWriteChunkSize,
                  progress: CSProgress? = nil, provider: Provider) throws
    {
        guard accessMode != .read else { throw ArchiveError.unwritableArchive }
        // Directories and symlinks cannot be compressed
        let compressionMethod = type == .file ? compressionMethod : .none
        progress?.totalUnitCount = type == .directory ? defaultDirectoryUnitCount : uncompressedSize
        let (eocdRecord, zip64EOCD) = (endOfCentralDirectoryRecord, zip64EndOfCentralDirectory)
        guard offsetToStartOfCentralDirectory <= .max else { throw ArchiveError.invalidCentralDirectoryOffset }
        var startOfCD = UInt64(offsetToStartOfCentralDirectory)

        try archiveFile.seek(toOffset: startOfCD)
        let existingSize = sizeOfCentralDirectory
        let existingData = try Data.readChunk(of: Int(existingSize), from: archiveFile)
        try archiveFile.seek(toOffset: startOfCD)
        let fileHeaderStart = try archiveFile.offset()
        let modDateTime = modificationDate.fileModificationDateTime
        defer { try? archiveFile.synchronize() }
        do {
            // Local File Header
            var localFileHeader = try writeLocalFileHeader(path: path, compressionMethod: compressionMethod,
                                                           size: (UInt64(uncompressedSize), 0), checksum: 0,
                                                           modificationDateTime: modDateTime)
            // File Data
            let (written, checksum) = try writeEntry(uncompressedSize: uncompressedSize, type: type,
                                                     compressionMethod: compressionMethod, bufferSize: bufferSize,
                                                     progress: progress, provider: provider)
            startOfCD = try archiveFile.offset()
            // Write the local file header a second time. Now with compressedSize (if applicable) and a valid checksum.
            try archiveFile.seek(toOffset: fileHeaderStart)
            localFileHeader = try writeLocalFileHeader(path: path, compressionMethod: compressionMethod,
                                                       size: (UInt64(uncompressedSize), UInt64(written)),
                                                       checksum: checksum, modificationDateTime: modDateTime)
            // Central Directory
            try archiveFile.seek(toOffset: startOfCD)
            _ = try Data.writeLargeChunk(existingData, to: archiveFile)
            let permissions = permissions ?? (type == .directory ? defaultDirectoryPermissions : defaultFilePermissions)
            let externalAttributes = FileAttributes(type: type, permissions: permissions)
            let centralDir = try writeCentralDirectoryStructure(localFileHeader: localFileHeader,
                                                                relativeOffset: UInt64(fileHeaderStart),
                                                                externalFileAttributes: externalAttributes)
            // End of Central Directory Record (including ZIP64 End of Central Directory Record/Locator)
            let startOfEOCD = try archiveFile.offset()
            let eocd = try writeEndOfCentralDirectory(centralDirectoryStructure: centralDir,
                                                      startOfCentralDirectory: UInt64(startOfCD),
                                                      startOfEndOfCentralDirectory: startOfEOCD, operation: .add)
            (endOfCentralDirectoryRecord, zip64EndOfCentralDirectory) = eocd
        } catch ArchiveError.cancelledOperation {
            try rollback(UInt64(fileHeaderStart), (existingData, existingSize), bufferSize, eocdRecord, zip64EOCD)
            throw ArchiveError.cancelledOperation
        }
    }

    /// Remove a ZIP `Entry` from the receiver.
    ///
    /// - Parameters:
    ///   - entry: The `Entry` to remove.
    ///   - bufferSize: The maximum size for the read and write buffers used during removal.
    ///   - progress: A progress object that can be used to track or cancel the remove operation.
    /// - Throws: An error if the `Entry` is malformed or the receiver is not writable.
    func remove(_ entry: Entry, bufferSize: Int = defaultReadChunkSize, progress: CSProgress? = nil) throws {
        guard accessMode != .read else { throw ArchiveError.unwritableArchive }
        let (tempArchive, tempDir) = try makeTempArchive()
        defer { tempDir.map { try? FileManager().removeItem(at: $0) } }
        progress?.totalUnitCount = totalUnitCountForRemoving(entry)
        var centralDirectoryData = Data()
        var offset: UInt64 = 0
        for currentEntry in self {
            let cds = currentEntry.centralDirectoryStructure
            if currentEntry != entry {
                let entryStart = cds.effectiveRelativeOffsetOfLocalHeader
                try archiveFile.seek(toOffset: entryStart)
                let provider: Provider = { _, chunkSize -> Data in
                    try Data.readChunk(of: chunkSize, from: self.archiveFile)
                }
                let consumer: Consumer = {
                    if progress?.isCancelled == true { throw ArchiveError.cancelledOperation }
                    _ = try Data.write(chunk: $0, to: tempArchive.archiveFile)
                    progress?.completedUnitCount += Int64($0.count)
                }
                guard currentEntry.localSize <= .max else { throw ArchiveError.invalidLocalHeaderSize }
                _ = try Data.consumePart(of: Int64(currentEntry.localSize), chunkSize: bufferSize,
                                         provider: provider, consumer: consumer)
                let updatedCentralDirectory = updateOffsetInCentralDirectory(centralDirectoryStructure: cds,
                                                                             updatedOffset: entryStart - offset)
                centralDirectoryData.append(updatedCentralDirectory.data)
            } else { offset = currentEntry.localSize }
        }
        let startOfCentralDirectory = try tempArchive.archiveFile.offset()
        _ = try Data.write(chunk: centralDirectoryData, to: tempArchive.archiveFile)
        let startOfEndOfCentralDirectory = try tempArchive.archiveFile.offset()
        tempArchive.endOfCentralDirectoryRecord = endOfCentralDirectoryRecord
        tempArchive.zip64EndOfCentralDirectory = zip64EndOfCentralDirectory
        let ecodStructure = try
            tempArchive.writeEndOfCentralDirectory(centralDirectoryStructure: entry.centralDirectoryStructure,
                                                   startOfCentralDirectory: startOfCentralDirectory,
                                                   startOfEndOfCentralDirectory: startOfEndOfCentralDirectory,
                                                   operation: .remove)
        (tempArchive.endOfCentralDirectoryRecord, tempArchive.zip64EndOfCentralDirectory) = ecodStructure
        (endOfCentralDirectoryRecord, zip64EndOfCentralDirectory) = ecodStructure
        try tempArchive.archiveFile.synchronize()
        try replaceCurrentArchive(with: tempArchive)
    }

    internal func replaceCurrentArchive(with archive: Archive) throws {
        try archiveFile.close()
        if isMemoryArchive {
            guard let data = archive.data,
                  let config = Archive.makeBackingConfiguration(for: data, mode: .update)
            else {
                throw ArchiveError.unwritableArchive
            }
            archiveFile = config.handle
            endOfCentralDirectoryRecord = config.endOfCentralDirectoryRecord
            zip64EndOfCentralDirectory = config.zip64EndOfCentralDirectory
        } else {
            let fileManager = FileManager()
            #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
                do {
                    _ = try fileManager.replaceItemAt(url, withItemAt: archive.url)
                } catch {
                    _ = try fileManager.removeItem(at: url)
                    _ = try fileManager.moveItem(at: archive.url, to: url)
                }
            #else
                _ = try fileManager.removeItem(at: url)
                _ = try fileManager.moveItem(at: archive.url, to: url)
            #endif
            guard let file = try? ArchiveHandle(forUpdating: url) else { throw ArchiveError.unreadableArchive }
            archiveFile = file
        }
    }
}

// MARK: - Private

private extension Archive {
    func updateOffsetInCentralDirectory(centralDirectoryStructure: CentralDirectoryStructure,
                                        updatedOffset: UInt64) -> CentralDirectoryStructure
    {
        let zip64ExtendedInformation = Entry.ZIP64ExtendedInformation(
            zip64ExtendedInformation: centralDirectoryStructure.zip64ExtendedInformation, offset: updatedOffset
        )
        let offsetInCD = updatedOffset < maxOffsetOfLocalFileHeader ? UInt32(updatedOffset) : UInt32.max
        return CentralDirectoryStructure(centralDirectoryStructure: centralDirectoryStructure,
                                         zip64ExtendedInformation: zip64ExtendedInformation,
                                         relativeOffset: offsetInCD)
    }

    func rollback(_ localFileHeaderStart: UInt64, _ existingCentralDirectory: (data: Data, size: UInt64),
                  _ bufferSize: Int, _ endOfCentralDirRecord: EndOfCentralDirectoryRecord,
                  _ zip64EndOfCentralDirectory: ZIP64EndOfCentralDirectory?) throws
    {
        try archiveFile.synchronize()
        try archiveFile.truncate(atOffset: localFileHeaderStart)
        try archiveFile.seek(toOffset: localFileHeaderStart)
        _ = try Data.writeLargeChunk(existingCentralDirectory.data, to: archiveFile)
        _ = try Data.write(chunk: existingCentralDirectory.data, to: archiveFile)
        if let zip64EOCD = zip64EndOfCentralDirectory {
            _ = try Data.write(chunk: zip64EOCD.data, to: archiveFile)
        }
        _ = try Data.write(chunk: endOfCentralDirRecord.data, to: archiveFile)
    }

    func makeTempArchive() throws -> (Archive, URL?) {
        var archive: Archive
        var url: URL?
        if isMemoryArchive {
            guard let tempArchive = Archive(data: Data(), accessMode: .create,
                                            preferredEncoding: preferredEncoding)
            else {
                throw ArchiveError.unwritableArchive
            }
            archive = tempArchive
        } else {
            let manager = FileManager()
            let tempDir = URL.temporaryReplacementDirectoryURL(for: self)
            let uniqueString = ProcessInfo.processInfo.globallyUniqueString
            let tempArchiveURL = tempDir.appendingPathComponent(uniqueString)
            try manager.createParentDirectoryStructure(for: tempArchiveURL)
            guard let tempArchive = Archive(url: tempArchiveURL, accessMode: .create) else {
                throw ArchiveError.unwritableArchive
            }
            archive = tempArchive
            url = tempDir
        }
        return (archive, url)
    }
}
