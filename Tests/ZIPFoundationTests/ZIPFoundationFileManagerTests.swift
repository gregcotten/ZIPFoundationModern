//
//  ZIPFoundationFileManagerTests.swift
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
    func testZipItem() {
        let fileManager = FileManager()
        let assetURL = resourceURL(for: #function, pathExtension: "png")
        var fileArchiveURL = ZIPFoundationTests.tempZipDirectoryURL
        fileArchiveURL.appendPathComponent(archiveName(for: #function))
        do {
            try fileManager.zipItem(at: assetURL, to: fileArchiveURL)
        } catch { XCTFail("Failed to zip item at URL:\(assetURL). Error: \(error)") }
        guard let archive = Archive(url: fileArchiveURL, accessMode: .read) else {
            XCTFail("Failed to read archive."); return
        }
        XCTAssertNotNil(archive[assetURL.lastPathComponent])
        XCTAssert(archive.checkIntegrity())
        var directoryURL = ZIPFoundationTests.tempZipDirectoryURL
        directoryURL.appendPathComponent(ProcessInfo.processInfo.globallyUniqueString)
        var directoryArchiveURL = ZIPFoundationTests.tempZipDirectoryURL
        let pathComponent = archiveName(for: #function, suffix: "Directory")
        directoryArchiveURL.appendPathComponent(pathComponent)
        var parentDirectoryArchiveURL = ZIPFoundationTests.tempZipDirectoryURL
        let parentPathComponent = archiveName(for: #function, suffix: "ParentDirectory")
        parentDirectoryArchiveURL.appendPathComponent(parentPathComponent)
        var compressedDirectoryArchiveURL = ZIPFoundationTests.tempZipDirectoryURL
        let compressedPathComponent = archiveName(for: #function, suffix: "CompressedDirectory")
        compressedDirectoryArchiveURL.appendPathComponent(compressedPathComponent)
        let newAssetURL = directoryURL.appendingPathComponent(assetURL.lastPathComponent)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            try fileManager.createDirectory(at: directoryURL.appendingPathComponent("nested"),
                                            withIntermediateDirectories: true, attributes: nil)
            try fileManager.copyItem(at: assetURL, to: newAssetURL)
            try fileManager.createSymbolicLink(at: directoryURL.appendingPathComponent("link"),
                                               withDestinationURL: newAssetURL)
            try fileManager.zipItem(at: directoryURL, to: directoryArchiveURL)
            try fileManager.zipItem(at: directoryURL, to: parentDirectoryArchiveURL, shouldKeepParent: false)
            try fileManager.zipItem(at: directoryURL, to: compressedDirectoryArchiveURL, compressionMethod: .deflate)
        } catch { XCTFail("Unexpected error while trying to zip via fileManager. Error: \(error)") }
        guard let directoryArchive = Archive(url: directoryArchiveURL, accessMode: .read) else {
            XCTFail("Failed to read archive."); return
        }
        XCTAssert(directoryArchive.checkIntegrity())
        guard let parentDirectoryArchive = Archive(url: parentDirectoryArchiveURL, accessMode: .read) else {
            XCTFail("Failed to read archive."); return
        }
        XCTAssert(parentDirectoryArchive.checkIntegrity())
    }

    func testZipItemErrorConditions() {
        let fileManager = FileManager()

        do {
            try fileManager.zipItem(at: URL(fileURLWithPath: "/nothing"), to: URL(fileURLWithPath: "/nowhere"))
            XCTFail("Error when zipping non-existant archive not raised")
        } catch let error as CocoaError { XCTAssert(error.code == CocoaError.fileReadNoSuchFile)
        } catch {
            XCTFail("Unexpected error while trying to zip via fileManager. Error: \(error)")
        }

        do {
            try fileManager.zipItem(at: URL(fileURLWithPath: NSTemporaryDirectory()),
                                    to: URL(fileURLWithPath: NSTemporaryDirectory()))
            XCTFail("Error when zipping directory to already existing destination not raised")
        } catch let error as CocoaError { XCTAssert(error.code == CocoaError.fileWriteFileExists)
        } catch { XCTFail("Unexpected error while trying to zip via fileManager. Error: \(error)") }

        do {
            let unwritableURL = URL(fileURLWithPath: "/test.zip")
            try fileManager.zipItem(at: URL(fileURLWithPath: NSTemporaryDirectory()), to: unwritableURL)
            #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                // we absolutely know that you can't write to / on Apple operating systems
                XCTFail("Error when zipping to non writable archive not raised")
            #else
                print("it's odd, but you can totally write to the root of this drive. skipping test")
            #endif
        } catch let error as Archive.ArchiveError {
            XCTAssert(error == .unwritableArchive)
        } catch {
            XCTFail("Unexpected error while trying to zip via fileManager. Error: \(error)")
        }

        var directoryArchiveURL = ZIPFoundationTests.tempZipDirectoryURL
        let pathComponent = pathComponent(for: #function) + "Directory"
        directoryArchiveURL.appendPathComponent(pathComponent)
        directoryArchiveURL.appendPathExtension("zip")
        var unreadableFileURL = ZIPFoundationTests.tempZipDirectoryURL
        do {
            unreadableFileURL.appendPathComponent(pathComponent)
            unreadableFileURL.appendPathComponent(ProcessInfo.processInfo.globallyUniqueString)
            try fileManager.createParentDirectoryStructure(for: unreadableFileURL)
            let noPermissionAttributes = [FileAttributeKey.posixPermissions: Int16(0o000)]
            let result = fileManager.createFile(atPath: unreadableFileURL.path, contents: nil,
                                                attributes: noPermissionAttributes)
            XCTAssert(result == true)
            try fileManager.zipItem(at: unreadableFileURL.deletingLastPathComponent(), to: directoryArchiveURL)
        } catch let error as CocoaError {
            XCTAssert(error.code == CocoaError.fileReadNoPermission)
        } catch {
            XCTFail("Unexpected error while trying to zip via fileManager. Error: \(error)")
        }
    }

    func testUnzipItem() {
        let fileManager = FileManager()
        let archive = archive(for: #function, mode: .read)
        let destinationURL = createDirectory(for: #function)
        do {
            try fileManager.unzipItem(at: archive.url, to: destinationURL)
        } catch {
            XCTFail("Failed to extract item. Error: \(error)"); return
        }
        var itemsExist = false
        for entry in archive {
            let directoryURL = destinationURL.appendingPathComponent(entry.path)
            itemsExist = fileManager.itemExists(at: directoryURL)
            if !itemsExist { break }
        }
        XCTAssert(itemsExist)
    }

    #if !os(Windows)
    func testUnzipItemWithFrameworkSymlinkChain() {
        let fileManager = FileManager()
        let archive = archive(for: #function, mode: .create)
        let destinationURL = createDirectory(for: #function)
        let frameworkName = "Test.framework"
        let resourcesTarget = "Versions/Current/Resources"
        let currentTarget = "B"

        do {
            try archive.addEntry(with: "\(frameworkName)/", type: .directory, uncompressedSize: 0) { _, _ in Data() }
            try archive.addEntry(with: "\(frameworkName)/Versions/", type: .directory, uncompressedSize: 0) { _, _ in Data() }
            try archive.addEntry(with: "\(frameworkName)/Versions/B/", type: .directory, uncompressedSize: 0) { _, _ in Data() }
            try archive.addEntry(with: "\(frameworkName)/Versions/B/Resources/", type: .directory, uncompressedSize: 0) { _, _ in Data() }
            try archive.addEntry(with: "\(frameworkName)/Resources",
                                 type: .symlink,
                                 uncompressedSize: Int64(resourcesTarget.utf8.count)) { _, _ in
                Data(resourcesTarget.utf8)
            }
            try archive.addEntry(with: "\(frameworkName)/Versions/Current",
                                 type: .symlink,
                                 uncompressedSize: Int64(currentTarget.utf8.count)) { _, _ in
                Data(currentTarget.utf8)
            }

            try fileManager.unzipItem(at: archive.url, to: destinationURL)
        } catch {
            XCTFail("Failed to extract framework symlink chain. Error: \(error)")
            return
        }

        let frameworkURL = destinationURL.appendingPathComponent(frameworkName)
        XCTAssertEqual(try? fileManager.destinationOfSymbolicLink(atPath: frameworkURL.appendingPathComponent("Resources").path), resourcesTarget)
        XCTAssertEqual(try? fileManager.destinationOfSymbolicLink(atPath: frameworkURL.appendingPathComponent("Versions/Current").path), currentTarget)
        XCTAssertTrue(fileManager.itemExists(at: frameworkURL.appendingPathComponent("Resources")))
    }
    #endif

    func testUnzipItemWithPreferredEncoding() {
        let fileManager = FileManager()
        let encoding = String.Encoding.utf8
        let archive = archive(for: #function, mode: .read, preferredEncoding: encoding)
        let destinationURL = createDirectory(for: #function)
        do {
            try fileManager.unzipItem(at: archive.url, to: destinationURL, preferredEncoding: encoding)
        } catch {
            XCTFail("Failed to extract item. Error: \(error)"); return
        }
        var itemsExist = false
        for entry in archive {
            let directoryURL = destinationURL.appendingPathComponent(entry.path(using: encoding))
            itemsExist = fileManager.itemExists(at: directoryURL)
            if !itemsExist { break }
        }
        XCTAssert(itemsExist)
    }

    func testUnzipItemErrorConditions() {
        var nonexistantArchiveURL = ZIPFoundationTests.tempZipDirectoryURL
        nonexistantArchiveURL.appendPathComponent("invalid")
        let existingArchiveURL = resourceURL(for: #function, pathExtension: "zip")
        let destinationURL = ZIPFoundationTests.tempZipDirectoryURL
        var existingURL = destinationURL
        existingURL.appendPathComponent("test")
        existingURL.appendPathComponent("faust.txt")
        let fileManager = FileManager()
        do {
            try fileManager.unzipItem(at: nonexistantArchiveURL, to: ZIPFoundationTests.tempZipDirectoryURL)
            XCTFail("Error when unzipping non-existant archive not raised")
        } catch let error as CocoaError {
            XCTAssertTrue(error.code == CocoaError.fileReadNoSuchFile)
        } catch { XCTFail("Unexpected error while trying to unzip via fileManager. Error: \(error)"); return }
        do {
            try fileManager.createParentDirectoryStructure(for: existingURL)
            fileManager.createFile(atPath: existingURL.path, contents: Data(), attributes: nil)
            try fileManager.unzipItem(at: existingArchiveURL, to: destinationURL)
            XCTFail("Error when unzipping archive to existing destination not raised")
        } catch let error as CocoaError {
            XCTAssertTrue(error.code == CocoaError.fileWriteFileExists)
        } catch {
            XCTFail("Unexpected error while trying to unzip via fileManager. Error: \(error)"); return
        }
        let nonZipArchiveURL = resourceURL(for: #function, pathExtension: "png")
        do {
            try fileManager.unzipItem(at: nonZipArchiveURL, to: destinationURL)
            XCTFail("Error when trying to unzip non-archive not raised")
        } catch let error as Archive.ArchiveError {
            XCTAssertTrue(error == .unreadableArchive)
        } catch { XCTFail("Unexpected error while trying to unzip via fileManager. Error: \(error)"); return }
    }

    func testDirectoryCreationHelperMethods() {
        let processInfo = ProcessInfo.processInfo
        var nestedURL = ZIPFoundationTests.tempZipDirectoryURL
        nestedURL.appendPathComponent(processInfo.globallyUniqueString)
        nestedURL.appendPathComponent(processInfo.globallyUniqueString)
        do {
            try FileManager().createParentDirectoryStructure(for: nestedURL)
        } catch { XCTFail("Failed to create parent directory. Error: \(error)") }
    }

    func testFileAttributeHelperMethods() {
        let cdsBytes: [UInt8] = [0x50, 0x4B, 0x01, 0x02, 0x1E, 0x15, 0x14, 0x00,
                                 0x08, 0x08, 0x08, 0x00, 0xAB, 0x85, 0x77, 0x47,
                                 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
                                 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
                                 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                                 0xB0, 0x11, 0x00, 0x00, 0x00, 0x00]
        guard let cds = Entry.CentralDirectoryStructure(data: Data(cdsBytes),
                                                        additionalDataProvider: { count -> Data in
                                                            guard let pathData = "/".data(using: .utf8) else {
                                                                throw AdditionalDataError.encodingError
                                                            }
                                                            XCTAssert(count == pathData.count)
                                                            return pathData
                                                        })
        else {
            XCTFail("Failed to read central directory structure."); return
        }
        let lfhBytes: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x08, 0x08,
                                 0x08, 0x00, 0xAB, 0x85, 0x77, 0x47, 0x00, 0x00,
                                 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                                 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        guard let lfh = Entry.LocalFileHeader(data: Data(lfhBytes),
                                              additionalDataProvider: { _ -> Data in
                                                  Data()
                                              })
        else {
            XCTFail("Failed to read local file header."); return
        }
        guard let entry = Entry(centralDirectoryStructure: cds, localFileHeader: lfh) else {
            XCTFail("Failed to create test entry."); return
        }
        let attributes = entry.fileAttributes
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value else {
            XCTFail("Failed to read file attributes."); return
        }
        XCTAssert(permissions == UInt16(defaultDirectoryPermissions.rawValue))
    }

    func testFilePermissionHelperMethods() {
        var permissions = Entry.permissions(for: FileAttributes(externalRawValue: 777, isDirectoryHint: false).permissions, osType: .unix, entryType: .file)
        XCTAssertEqual(permissions, defaultFilePermissions)
        permissions = Entry.permissions(for: .init(rawValue: 0), osType: .msdos, entryType: .file)
        XCTAssertEqual(permissions, defaultFilePermissions)
        permissions = Entry.permissions(for: .init(rawValue: 0), osType: .msdos, entryType: .directory)
        XCTAssertEqual(permissions, defaultDirectoryPermissions)
    }

    func testFileModificationDateHelperMethods() {
        let msDOSDate = Date(timeIntervalSince1970: TimeInterval(Int.min)).fileModificationDate
        XCTAssert(msDOSDate == 0)
        let msDOSTime = Date(timeIntervalSince1970: TimeInterval(Int.min)).fileModificationTime
        XCTAssert(msDOSTime == 0)
        let invalidEarlyMSDOSDate = Date(timeIntervalSince1970: 0).fileModificationDate
        XCTAssert(invalidEarlyMSDOSDate == 33)
        let invalidLateMSDOSDate = Date(timeIntervalSince1970: 4_102_444_800).fileModificationDate
        XCTAssert(invalidLateMSDOSDate == 60961)
    }

    func testFileModificationDate() {
        var testDateComponents = DateComponents()
        testDateComponents.calendar = Calendar(identifier: Calendar.Identifier.gregorian)
        testDateComponents.timeZone = TimeZone(identifier: "UTC")
        testDateComponents.year = 2000
        testDateComponents.month = 1
        testDateComponents.day = 1
        testDateComponents.hour = 12
        testDateComponents.minute = 30
        testDateComponents.second = 10
        guard let testDate = testDateComponents.date else {
            XCTFail("Failed to create test date/timestamp"); return
        }
        let assetURL = resourceURL(for: #function, pathExtension: "png")
        let fileManager = FileManager()
        let archive = archive(for: #function, mode: .create)
        do {
            try fileManager.setAttributes([.modificationDate: testDate], ofItemAtPath: assetURL.path)
            let relativePath = assetURL.lastPathComponent
            let baseURL = assetURL.deletingLastPathComponent()
            try archive.addEntry(with: relativePath, relativeTo: baseURL)
            guard let entry = archive["\(assetURL.lastPathComponent)"] else {
                throw Archive.ArchiveError.unreadableArchive
            }
            guard let fileDate = entry.fileAttributes[.modificationDate] as? Date else {
                throw CocoaError(CocoaError.fileReadUnknown)
            }
            let currentTimeInterval = testDate.timeIntervalSinceReferenceDate
            let fileTimeInterval = fileDate.timeIntervalSinceReferenceDate
            // ZIP uses MSDOS timestamps, which provide very poor accuracy
            // https://blogs.msdn.microsoft.com/oldnewthing/20151030-00/?p=91881
            XCTAssertEqual(currentTimeInterval, fileTimeInterval, accuracy: 2.0)
        } catch { XCTFail("Failed to test last file modification date. Error: \(error)") }
    }

    func testPOSIXPermissions() throws {
        #if os(Windows)
            throw XCTSkip("Windows does not reliably round-trip POSIX file permissions.")
        #else
            let permissions = NSNumber(value: Int16(0o753))
            let assetURL = resourceURL(for: #function, pathExtension: "png")
            let fileManager = FileManager()
            let archive = archive(for: #function, mode: .create)
            do {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: assetURL.path)
                let assetPOSIXPermissions = UInt16(try fileManager.permissionsForItem(at: assetURL).rawValue)
                XCTAssertEqual(assetPOSIXPermissions, permissions.uint16Value, "permissions didn't actualy get set. expected: \(String(permissions.uint16Value, radix: 0o10)), actual: \(String(assetPOSIXPermissions, radix: 0o10))")
                let relativePath = assetURL.lastPathComponent
                let baseURL = assetURL.deletingLastPathComponent()
                try archive.addEntry(with: relativePath, relativeTo: baseURL)
                guard let entry = archive["\(assetURL.lastPathComponent)"] else {
                    throw Archive.ArchiveError.unreadableArchive
                }
                guard let filePermissions = entry.fileAttributes[.posixPermissions] as? NSNumber else {
                    throw CocoaError(CocoaError.fileReadUnknown)
                }
                XCTAssert(permissions.uint16Value == filePermissions.uint16Value, "invalid permissions. expected: \(String(permissions.uint16Value, radix: 0o10)), actual: \(String(filePermissions.uint16Value, radix: 0o10))")
            } catch { XCTFail("Failed to test POSIX permissions. Error: \(error)") }
        #endif
    }

    func testCRC32Check() {
        let fileManager = FileManager()
        let archive = archive(for: #function, mode: .read)
        let destinationURL = createDirectory(for: #function)
        do {
            try fileManager.unzipItem(at: archive.url, to: destinationURL)
            XCTFail("Extraction should fail")
        } catch let error as Archive.ArchiveError {
            XCTAssert(error == Archive.ArchiveError.invalidCRC32)
        } catch {
            XCTFail("Extraction should fail with an archive error. Error: \(error)")
        }
    }

    func testTraversalAttack() {
        let fileManager = FileManager()
        let archive = archive(for: #function, mode: .read)
        let destinationURL = createDirectory(for: #function)
        do {
            try fileManager.unzipItem(at: archive.url, to: destinationURL)
            XCTFail("Extraction should fail")
        } catch {
            XCTAssert((error as? CocoaError)?.code == .fileReadInvalidFileName); return
        }
    }

    func testTemporaryReplacementDirectoryURL() {
        let archive = archive(for: #function, mode: .create)
        var tempURLs = Set<URL>()
        defer {
            for url in tempURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        // We choose 2000 temp directories to test workaround for http://openradar.appspot.com/50553219
        for _ in 1 ... 2000 {
            let tempDir = URL.temporaryReplacementDirectoryURL(for: archive)
            XCTAssertFalse(tempURLs.contains(tempDir), "Temp directory URL should be unique. \(tempDir)")
            tempURLs.insert(tempDir)
        }

        // Also cover the fallback codepath in the helper method to generate a unique temp URL.
        // In-memory archives have no filesystem representation and therefore don't need a per-volume
        // temp URL.
        guard let memoryArchive = Archive(data: Data(), accessMode: .create) else {
            XCTFail("Temporary memory archive creation failed.")
            return
        }

        let memoryTempURL = URL.temporaryReplacementDirectoryURL(for: memoryArchive)
        XCTAssertNotNil(memoryTempURL, "Temporary URL creation for in-memory archive failed.")
    }
}
