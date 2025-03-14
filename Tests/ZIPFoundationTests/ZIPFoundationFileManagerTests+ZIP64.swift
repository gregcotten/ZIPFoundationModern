//
//  ZIPFoundationFileManagerTests+ZIP64.swift
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
    private enum ZIP64FileManagerTestsError: Error, CustomStringConvertible {
        case failedToZipItem(url: URL, underlying: Error?)
        case failedToReadArchive(url: URL)
        case failedToUnzipItem(underlying: Error?)

        var description: String {
            switch self {
            case let .failedToZipItem(assetURL, error):
                return "Failed to zip item at URL: \(assetURL). (Error: \(String(describing: error)))"
            case let .failedToReadArchive(fileArchiveURL):
                return "Failed to read archive at URL: \(fileArchiveURL)"
            case let .failedToUnzipItem(error):
                return "Failed to unzip item. (Error: \(String(describing: error)))"
            }
        }
    }

    func testZipCompressedZIP64Item() {
        do {
            try archiveZIP64Item(for: #function, compressionMethod: .deflate)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testZipUncompressedZIP64Item() {
        do {
            try archiveZIP64Item(for: #function, compressionMethod: .none)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testUnzipCompressedZIP64Item() {
        // stored by zip 3.0 via command line: zip -0 -fz
        //
        // testUnzipCompressedZIP64Item.zip/
        //   ├─ directory
        //   ├─ testLink
        //   ├─ nested
        //     ├─ nestedLink
        //     ├─ faust copy.txt
        //     ├─ deep
        //       ├─ another.random
        //   ├─ faust.txt
        //   ├─ empty
        //   ├─ data.random
        //   ├─ random.data
        do {
            try unarchiveZIP64Item(for: #function)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testUnzipUncompressedZIP64Item() {
        // stored by zip 3.0 via command line: zip -0 -fz
        //
        // testUnzipCompressedZIP64Item.zip/
        //   ├─ directory
        //   ├─ testLink
        //   ├─ nested
        //     ├─ nestedLink
        //     ├─ faust copy.txt
        //     ├─ deep
        //       ├─ another.random
        //   ├─ faust.txt
        //   ├─ empty
        //   ├─ data.random
        //   ├─ random.data
        do {
            try unarchiveZIP64Item(for: #function)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testUnzipItemWithZIP64DataDescriptor() {
        // testUnzipCompressedZIP64Item.zip
        //   ├─ simple.data
        do {
            try unarchiveZIP64Item(for: #function)
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: - Helpers

    private func archiveZIP64Item(for testFunction: String, compressionMethod: CompressionMethod) throws {
        mockIntMaxValues(int32Factor: 16, int16Factor: 16)
        defer { self.resetIntMaxValues() }
        let assetURL = resourceURL(for: testFunction, pathExtension: "png")
        var fileArchiveURL = ZIPFoundationTests.tempZipDirectoryURL
        fileArchiveURL.appendPathComponent(archiveName(for: testFunction))
        do {
            try FileManager().zipItem(at: assetURL, to: fileArchiveURL, compressionMethod: compressionMethod)
        } catch {
            throw ZIP64FileManagerTestsError.failedToZipItem(url: assetURL, underlying: error)
        }
        guard let archive = Archive(url: fileArchiveURL, accessMode: .read) else {
            throw ZIP64FileManagerTestsError.failedToReadArchive(url: fileArchiveURL)
        }
        XCTAssertNotNil(archive[assetURL.lastPathComponent])
        XCTAssert(archive.checkIntegrity())
    }

    private func unarchiveZIP64Item(for testFunction: String) throws {
        let fileManager = FileManager()
        let archive = archive(for: testFunction, mode: .read)
        let destinationURL = createDirectory(for: testFunction)
        do {
            try fileManager.unzipItem(at: archive.url, to: destinationURL)
        } catch {
            throw ZIP64FileManagerTestsError.failedToUnzipItem(underlying: error)
        }
        var itemsExist = false
        for entry in archive {
            let directoryURL = destinationURL.appendingPathComponent(entry.path)
            itemsExist = fileManager.itemExists(at: directoryURL)
            if !itemsExist { break }
        }
        XCTAssert(itemsExist)
    }
}
