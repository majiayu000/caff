import Foundation

enum PathExpansion {
    static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
