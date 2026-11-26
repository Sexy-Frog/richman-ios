import Foundation

/// Filesystem privacy helpers. App data is excluded from iCloud/iTunes backup
/// so ciphertext (and decrypted exports) never leave the device through a
/// backup, even if the device passcode is later compromised.
enum PrivacyStorage {
    static var appSupport: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
    }

    /// Call once at launch and after a wipe.
    static func prepare() {
        excludeFromBackup(appSupport)
        if let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first {
            excludeFromBackup(documents)
        }
    }

    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    /// Remove a directory tree without following symlinks.
    static func removeTree(_ url: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            try? fm.removeItem(at: url)
            return
        }
        for item in items {
            let values = try? item.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            if values?.isDirectory == true, values?.isSymbolicLink != true {
                removeTree(item)
            } else {
                try? fm.removeItem(at: item)
            }
        }
        try? fm.removeItem(at: url)
    }

    /// MapLibre tile caches, URL caches and snapshots live in Library/Caches.
    /// Empty them on a panic wipe so viewed locations cannot be reconstructed.
    static func wipeCaches() {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return }
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: caches,
            includingPropertiesForKeys: nil
        ) else { return }
        for item in items {
            try? FileManager.default.removeItem(at: item)
        }
    }
}
