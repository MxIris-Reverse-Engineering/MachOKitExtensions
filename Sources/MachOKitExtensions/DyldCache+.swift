import Foundation
import MachOKit

extension DyldCache {
    public var fileStartOffset: UInt64 {
        numericCast(
            header.sharedRegionStart - mainCacheHeader.sharedRegionStart
        )
    }
}

public enum DyldCacheImageSearchMode {
    case name(String)
    case path(String)
}

extension DyldCache {
    public func machOFile(by mode: DyldCacheImageSearchMode) -> MachOFile? {
        if let found = machOFiles().first(where: { $0.match(by: mode) }) {
            return found
        }

        guard let mainCache else { return nil }

        if let found = mainCache.machOFiles().first(where: { $0.match(by: mode) }) {
            return found
        }

        if let subCaches {
            for subCacheEntry in subCaches {
                if let subCache = try? subCacheEntry.subcache(for: mainCache), let found = subCache.machOFiles().first(where: { $0.match(by: mode) }) {
                    return found
                }
            }
        }
        return nil
    }
}

extension FullDyldCache {
    public func machOFile(by mode: DyldCacheImageSearchMode) -> MachOFile? {
        if let found = machOFiles().first(where: { $0.match(by: mode) }) {
            return found
        }

        return nil
    }
}

extension MachOFile {
    fileprivate func match(by mode: DyldCacheImageSearchMode) -> Bool {
        switch mode {
        case .name(let name):
            return URL(fileURLWithPath: imagePath)
                .deletingPathExtension()
                .lastPathComponent == name
        case .path(let path):
            return imagePath == path
        }
    }
}
