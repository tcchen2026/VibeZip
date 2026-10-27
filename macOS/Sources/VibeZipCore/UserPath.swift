import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Display paths use the account's home, not the app's sandbox container.
/// Expanding a path does not grant access to it.
public enum UserPath {
    public static let homeDirectory = (accountHomeDirectory()
        ?? FileManager.default.homeDirectory(forUser: NSUserName())
        ?? FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL

    private static func accountHomeDirectory() -> URL? {
        var size = max(1024, sysconf(_SC_GETPW_R_SIZE_MAX))
        while size <= 1_048_576 {
            var record = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: size)
            var path: String?
            let code = buffer.withUnsafeMutableBufferPointer { storage in
                let code = getpwuid_r(getuid(), &record, storage.baseAddress!, storage.count, &result)
                if code == 0, result != nil, let home = record.pw_dir { path = String(cString: home) }
                return code
            }
            if let path = path, !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
            if code != ERANGE { return nil }
            size *= 2
        }
        return nil
    }

    public static func abbreviate(_ path: String, home: URL = homeDirectory) -> String {
        let base = home.standardizedFileURL.path
        if path == base { return "~" }
        guard base != "/", path.hasPrefix(base + "/") else { return path }
        return "~" + path.dropFirst(base.count)
    }

    public static func expand(_ path: String, home: URL = homeDirectory) -> String {
        let base = home.standardizedFileURL.path
        if path == "~" { return base }
        if path.hasPrefix("~/") { return base + path.dropFirst() }
        return (path as NSString).expandingTildeInPath
    }
}
