import Foundation

public enum WorkspaceActivityScanner {
    private static let ignoredDirectoryNames: Set<String> = [
        ".build",
        ".git",
        "DerivedData",
        "dist",
        "node_modules"
    ]

    public static func activities(configuration: WorkspaceTriggerConfiguration, now: Date = Date()) -> [WorkspaceActivity] {
        configuration.normalizedPaths.compactMap { rawPath in
            activity(
                path: (rawPath as NSString).expandingTildeInPath,
                recentWindowSeconds: configuration.recentActivityWindowSeconds,
                now: now
            )
        }
    }

    private static func activity(path: String, recentWindowSeconds: Int, now: Date) -> WorkspaceActivity? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        let lockPath = URL(fileURLWithPath: path)
            .appendingPathComponent(".git")
            .appendingPathComponent("index.lock")
            .path
        if FileManager.default.fileExists(atPath: lockPath) {
            return WorkspaceActivity(path: path, signal: .gitIndexLock)
        }

        return newestRecentFileActivity(path: path, recentWindowSeconds: recentWindowSeconds, now: now)
    }

    private static func newestRecentFileActivity(
        path: String,
        recentWindowSeconds: Int,
        now: Date
    ) -> WorkspaceActivity? {
        let rootURL = URL(fileURLWithPath: path, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let cutoff = now.addingTimeInterval(-TimeInterval(recentWindowSeconds))
        var newest: (url: URL, modifiedAt: Date)?

        for case let fileURL as URL in enumerator {
            if ignoredDirectoryNames.contains(fileURL.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey]) else {
                continue
            }

            if values.isDirectory == true {
                continue
            }

            guard values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt >= cutoff else {
                continue
            }

            if newest == nil || modifiedAt > newest!.modifiedAt {
                newest = (fileURL, modifiedAt)
            }
        }

        guard let newest else {
            return nil
        }

        return WorkspaceActivity(
            path: path,
            signal: .recentFile(
                relativePath: relativePath(from: rootURL, to: newest.url),
                modifiedAt: newest.modifiedAt
            )
        )
    }

    private static func relativePath(from rootURL: URL, to fileURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path

        guard filePath.hasPrefix(rootPath) else {
            return fileURL.lastPathComponent
        }

        return String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
