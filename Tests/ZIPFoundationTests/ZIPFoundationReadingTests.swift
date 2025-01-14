//
//  ZIPFoundationReadingTests.swift
//  ZIPFoundation
//
//  Copyright © 2017-2021 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import XCTest
@testable import ZIPFoundation

extension ZIPFoundationTests {
    func testExtractUncompressedFolderEntries() {
        let archive = archive(for: #function, mode: .read)
        for (i, entry) in archive.enumerated() {
            do {
                // Test extracting to memory
                var checksum = try archive.extract(entry, bufferSize: 32, consumer: { _ in })
                XCTAssert(entry.checksum == checksum)
                // Test extracting to file
                var fileURL = createDirectory(for: #function)
                fileURL.appendPathComponent(entry.path)
                checksum = try archive.extract(entry, to: fileURL)
                XCTAssert(entry.checksum == checksum)
                let fileManager = FileManager()
                XCTAssertTrue(fileManager.itemExists(at: fileURL))
                if entry.type == .file {
                    let fileData = try Data(contentsOf: fileURL)
                    let checksum = fileData.crc32(checksum: 0)
                    XCTAssert(checksum == entry.checksum)
                }
            } catch {
                XCTFail("Failed to unzip uncompressed folder entry \(i) (\(entry)) Error: \(error)")
            }
        }
    }

    func testExtractCompressedFolderEntries() {
        let archive = archive(for: #function, mode: .read)
        for (i, entry) in archive.enumerated() {
            do {
                // Test extracting to memory
                var checksum = try archive.extract(entry, bufferSize: 128, consumer: { _ in })
                XCTAssert(entry.checksum == checksum)
                // Test extracting to file
                var fileURL = createDirectory(for: #function)
                fileURL.appendPathComponent(entry.path)
                checksum = try archive.extract(entry, to: fileURL)
                XCTAssert(entry.checksum == checksum)
                let fileManager = FileManager()
                XCTAssertTrue(fileManager.itemExists(at: fileURL))
                if entry.type != .directory {
                    let fileData = try Data(contentsOf: fileURL)
                    let checksum = fileData.crc32(checksum: 0)
                    XCTAssert(checksum == entry.checksum)
                }
            } catch {
                XCTFail("Failed to unzip compressed folder entry \(i) (\(entry)) Error: \(error)")
            }
        }
    }

    func testExtractUncompressedDataDescriptorArchive() {
        let archive = archive(for: #function, mode: .read)
        for (i, entry) in archive.enumerated() {
            do {
                let checksum = try archive.extract(entry, consumer: { _ in })
                XCTAssert(entry.checksum == checksum)
            } catch {
                XCTFail("Failed to unzip data descriptor archive entry \(i) (\(entry)) Error: \(error)")
            }
        }
    }

    func testExtractCompressedDataDescriptorArchive() {
        let archive = archive(for: #function, mode: .read)
        for (i, entry) in archive.enumerated() {
            do {
                let checksum = try archive.extract(entry, consumer: { _ in })
                XCTAssert(entry.checksum == checksum)
            } catch {
                XCTFail("Failed to unzip data descriptor archive entry \(i) (\(entry)). Error: \(error)")
            }
        }
    }

    func testExtractPreferredEncoding() {
        let encoding = String.Encoding.utf8
        let archive = archive(for: #function, mode: .read, preferredEncoding: encoding)
        XCTAssertTrue(archive.checkIntegrity())
        let imageEntry = archive["data/pic👨‍👩‍👧‍👦🎂.jpg"]
        XCTAssertNotNil(imageEntry)
        let textEntry = archive["data/Benoît.txt"]
        XCTAssertNotNil(textEntry)
    }

    func testExtractMSDOSArchive() {
        let archive = archive(for: #function, mode: .read)
        for entry in archive {
            do {
                let checksum = try archive.extract(entry, consumer: { _ in })
                XCTAssert(entry.checksum == checksum)
            } catch {
                XCTFail("Failed to unzip MSDOS archive. Error: \(error)")
            }
        }
    }

    /// extremely long path names don't work on Windows and will cause a fatalError in this code
    #if !os(Windows)
        func testExtractErrorConditions() {
            let archive = archive(for: #function, mode: .read)
            XCTAssertNotNil(archive)
            guard let fileEntry = archive["testZipItem.png"] else {
                XCTFail("Failed to obtain test asset from archive.")
                return
            }
            XCTAssertNotNil(fileEntry)
            do {
                _ = try archive.extract(fileEntry, to: archive.url)
            } catch let error as CocoaError {
                XCTAssert(error.code == CocoaError.fileWriteFileExists)
            } catch {
                XCTFail("Unexpected error while trying to extract entry to existing URL. Error: \(error)")
                return
            }
            guard let linkEntry = archive["testZipItemLink"] else {
                XCTFail("Failed to obtain test asset from archive.")
                return
            }
            do {
                let longFileName = String(repeating: ProcessInfo.processInfo.globallyUniqueString, count: 100)
                var overlongURL = URL(fileURLWithPath: NSTemporaryDirectory())
                overlongURL.appendPathComponent(longFileName)
                _ = try archive.extract(fileEntry, to: overlongURL)
            } catch let error as CocoaError {
                XCTAssert(error.code == CocoaError.fileNoSuchFile)
            } catch {
                XCTFail("Unexpected error while trying to extract entry to invalid URL. Error: \(error)")
                return
            }
            XCTAssertNotNil(linkEntry)
            do {
                _ = try archive.extract(linkEntry, to: archive.url)
            } catch let error as CocoaError {
                XCTAssert(error.code == CocoaError.fileWriteFileExists)
            } catch {
                XCTFail("Unexpected error while trying to extract link entry to existing URL. Error: \(error)")
                return
            }
        }
    #endif

    func testCorruptFileErrorConditions() throws {
        let archiveURL = resourceURL(for: #function, pathExtension: "zip")
        let destinationFile = try ArchiveHandle(forUpdating: archiveURL)

        do {
            try destinationFile.seek(toOffset: 64)
            // We have to inject a large enough zeroes block to guarantee that libcompression
            // detects the failure when reading the stream
            _ = try Data.write(chunk: Data(count: 512 * 1024), to: destinationFile)
            try destinationFile.close()
            guard let archive = Archive(url: archiveURL, accessMode: .read) else {
                XCTFail("Failed to read archive.")
                return
            }
            guard let entry = archive["data.random"] else {
                XCTFail("Failed to read entry.")
                return
            }
            _ = try archive.extract(entry, consumer: { _ in })
        } catch let error as Data.CompressionError {
            XCTAssert(error == Data.CompressionError.corruptedData)
        } catch {
            XCTFail("Unexpected error while testing an archive with corrupt entry data. Error: \(error)")
        }
    }

    func testCorruptSymbolicLinkErrorConditions() {
        let archive = archive(for: #function, mode: .read)
        for entry in archive {
            do {
                var tempFileURL = URL(fileURLWithPath: NSTemporaryDirectory())
                tempFileURL.appendPathComponent(ProcessInfo.processInfo.globallyUniqueString)
                _ = try archive.extract(entry, to: tempFileURL)
            } catch let error as Archive.ArchiveError {
                XCTAssert(error == .invalidEntryPath)
            } catch {
                XCTFail("Unexpected error while trying to extract entry with invalid symbolic link. Error: \(error)")
            }
        }
    }

    func testInvalidCompressionMethodErrorConditions() {
        let archive = archive(for: #function, mode: .read)
        for entry in archive {
            do {
                _ = try archive.extract(entry, consumer: { _ in })
            } catch let error as Archive.ArchiveError {
                XCTAssert(error == .invalidCompressionMethod)
            } catch {
                XCTFail("Unexpected error while trying to extract entry with invalid compression method link. Error: \(error)")
            }
        }
    }

    func testExtractEncryptedArchiveErrorConditions() {
        let archive = archive(for: #function, mode: .read)
        var entriesRead = 0
        for _ in archive {
            entriesRead += 1
        }
        // We currently don't support encryption so we expect failed initialization for entry objects.
        XCTAssert(entriesRead == 0)
    }

    func testExtractInvalidBufferSizeErrorConditions() {
        let archive = archive(for: #function, mode: .read)
        let entry = archive["text.txt"]!
        XCTAssertThrowsError(try archive.extract(entry, to: URL(fileURLWithPath: ""), bufferSize: 0, skipCRC32: true))
        let archive2 = self.archive(for: #function, mode: .read)
        let entry2 = archive2["text.txt"]!
        XCTAssertThrowsError(try archive2.extract(entry2, bufferSize: 0, skipCRC32: true, consumer: { _ in }))
    }

    func testExtractUncompressedEmptyFile() {
        // We had a logic error, where completion handlers for empty entries were not called
        // Ensure that this edge case works
        var didCallCompletion = false
        let archive = archive(for: #function, mode: .read)
        guard let entry = archive["empty.txt"] else { XCTFail("Failed to extract entry."); return }

        do {
            _ = try archive.extract(entry) { data in
                XCTAssertEqual(data.count, 0)
                didCallCompletion = true
            }
        } catch {
            XCTFail("Unexpected error while trying to extract empty file of uncompressed archive. Error: \(error)")
        }
        XCTAssert(didCallCompletion)
    }

    func testExtractUncompressedEntryCancelation() {
        let archive = archive(for: #function, mode: .read)
        guard let entry = archive["original"] else { XCTFail("Failed to extract entry."); return }
        let progress = archive.makeProgressForReading(entry)
        do {
            var readCount = 0
            _ = try archive.extract(entry, bufferSize: 1, progress: progress) { data in
                readCount += data.count
                if readCount == 4 { progress.cancel() }
            }
        } catch let error as Archive.ArchiveError {
            XCTAssert(error == Archive.ArchiveError.cancelledOperation)
            XCTAssertEqual(progress.fractionCompleted, 0.5, accuracy: .ulpOfOne)
        } catch {
            XCTFail("Unexpected error while trying to cancel extraction. Error: \(error)")
        }
    }

    func testExtractCompressedEntryCancelation() {
        let archive = archive(for: #function, mode: .read)
        guard let entry = archive["random"] else { XCTFail("Failed to extract entry."); return }
        let progress = archive.makeProgressForReading(entry)
        do {
            var readCount = 0
            _ = try archive.extract(entry, bufferSize: 256, progress: progress) { data in
                readCount += data.count
                if readCount == 512 { progress.cancel() }
            }
        } catch let error as Archive.ArchiveError {
            XCTAssert(error == Archive.ArchiveError.cancelledOperation)
            XCTAssertEqual(progress.fractionCompleted, 0.5, accuracy: .ulpOfOne)
        } catch {
            XCTFail("Unexpected error while trying to cancel extraction. Error: \(error)")
        }
    }

    func testProgressHelpers() {
        let tempPath = NSTemporaryDirectory()
        var nonExistantURL = URL(fileURLWithPath: tempPath)
        nonExistantURL.appendPathComponent("invalid.path")
        let archive = archive(for: #function, mode: .update)
        XCTAssert(archive.totalUnitCountForAddingItem(at: nonExistantURL) == -1)
    }

    func testDetectEntryType() {
        let archive = archive(for: #function, mode: .read)
        let expectedData: [String: Entry.EntryType] = [
            "META-INF/": .directory,
            "META-INF/container.xml": .file,
        ]
        for entry in archive {
            XCTAssertEqual(entry.type, expectedData[entry.path])
        }
    }
}
