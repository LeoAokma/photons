import Foundation
import GRDB

extension Catalog {
    /// Repair older imports of DNGs whose IFD0 is a <=512px preview (the Photons
    /// panorama writer's preview limit). Call once when opening a mobile library,
    /// not on every grid refresh. Missing/unreadable files remain eligible next time.
    /// Only dimensions change: source bytes, edits, history and render caches stay intact.
    @discardableResult
    public func repairDNGPreviewDimensions() throws -> Int {
        let candidates = try dbQueue.read { db in
            try Asset.fetchAll(db, sql: """
                SELECT * FROM assets WHERE deleted = 0 AND lower(ext) = 'dng'
                AND coalesce(width, 0) <= 512 AND coalesce(height, 0) <= 512
                """)
        }
        var corrections: [(asset: Asset, width: Int, height: Int)] = []
        for asset in candidates {
            let size: (Int, Int)? = autoreleasepool {
                guard let url = try? fileURL(for: asset),
                      let metadata = try? MetadataReader.read(url),
                      let width = metadata.width, let height = metadata.height,
                      width > 0, height > 0, max(width, height) > 512 else { return nil }
                return (width, height)
            }
            if let size { corrections.append((asset, size.0, size.1)) }
        }
        guard !corrections.isEmpty else { return 0 }
        return try dbQueue.write { db in
            var updated = 0
            for correction in corrections {
                let asset = correction.asset
                // Do not overwrite a concurrent metadata refresh from another reader.
                try db.execute(sql: """
                    UPDATE assets SET width = ?, height = ?
                    WHERE id = ? AND width IS ? AND height IS ?
                    """, arguments: [correction.width, correction.height, asset.id, asset.width, asset.height])
                updated += db.changesCount
            }
            return updated
        }
    }
}
