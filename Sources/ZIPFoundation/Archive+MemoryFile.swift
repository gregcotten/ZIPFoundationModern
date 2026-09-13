//
//  Archive+MemoryFile.swift
//  ZIPFoundation
//
//  Copyright © 2017-2021 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import Foundation

extension Archive {
    var isMemoryArchive: Bool { url.scheme == memoryURLScheme }
}

public extension Archive {
    /// Returns a `Data` object containing a representation of the receiver.
    var data: Data? {
        switch archiveFile.backing {
        case let .memory(mem):
            return mem.data
        case .file:
            return nil
        }
    }
}

class MemoryFile {
    enum Error: Swift.Error {
        case isClosed
    }

    private(set) var data: Data
    private(set) var isClosed: Bool = false
    private(set) var offset: Int = 0

    init(data: Data) {
        assert(data.startIndex == 0, "Need zero-indexed data for any of this logic to work")
        self.data = data
    }

    private func ensureNotClosed() throws {
        guard !isClosed else { throw Error.isClosed }
    }

    func seek(toOffset offset: UInt64) {
        self.offset = Int(offset)
    }

    func readToEnd() throws -> Data? {
        try ensureNotClosed()

        let read = Data(data[offset ..< data.endIndex])
        offset = data.endIndex
        return read
    }

    func read(upToCount count: Int) throws -> Data? {
        try ensureNotClosed()

        let end = min(offset + count, data.endIndex)
        let read = Data(data[offset ..< end])
        offset = end
        return read
    }

    func seekToEnd() -> UInt64 {
        offset = data.endIndex
        return UInt64(offset)
    }

    func write(contentsOf moreData: some DataProtocol) throws {
        try ensureNotClosed()

        let spaceRemaining = data.endIndex - offset

        if moreData.count > spaceRemaining {
            data.append(contentsOf: Array(repeating: 0, count: moreData.count - spaceRemaining))
        }

        data.replaceSubrange(offset ..< offset + moreData.count, with: moreData)

        offset += moreData.count
    }

    func close() {
        isClosed = true
    }

    func truncate(atOffset truncateOffset: UInt64) throws {
        try ensureNotClosed()
        let truncateOffset = data.startIndex + Int(truncateOffset)

        if truncateOffset < data.endIndex {
            data.removeSubrange(truncateOffset ..< data.endIndex)
        } else if truncateOffset > data.endIndex {
            data.append(contentsOf: Array(repeating: 0, count: truncateOffset - data.endIndex))
        }

        offset = truncateOffset
    }
}
