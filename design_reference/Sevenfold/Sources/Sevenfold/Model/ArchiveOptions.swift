import Foundation

enum Hardware {
    static let cores = ProcessInfo.processInfo.activeProcessorCount
    static let memory = Int64(ProcessInfo.processInfo.physicalMemory)
    static let chip: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()
}

private let MB: Int64 = 1 << 20

/// Settings of 7-Zip's “Add to Archive” dialog.
struct AddOptions {
    struct Level: Identifiable, Hashable { let value: Int; let title: String; var id: Int { value } }

    static let levels = [Level(value: 0, title: "0 – Store"), Level(value: 1, title: "1 – Fastest"), Level(value: 3, title: "3 – Fast"),
                         Level(value: 5, title: "5 – Normal"), Level(value: 7, title: "7 – Maximum"), Level(value: 9, title: "9 – Ultra")]
    static let dictionaries: [Int64] = [64 << 10, 256 << 10, 1 * MB, 4 * MB, 16 * MB, 32 * MB, 64 * MB, 128 * MB, 256 * MB, 512 * MB, 1024 * MB]
    static let wordSizes = [8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 273]
    static let solidSizes = ["Non-solid", "16 MB", "256 MB", "1 GB", "2 GB", "4 GB", "16 GB", "Solid"]
    static let volumePresets = ["10M", "100M", "700M", "4092M", "4480M", "8128M"]

    enum UpdateMode: String, CaseIterable, Identifiable {
        case add = "Add and replace files", update = "Update and add files", freshen = "Freshen existing files", sync = "Synchronize files"
        var id: String { rawValue }
        var switches: String? {
            switch self {
            case .add, .update: nil
            case .freshen: "-up1q1r0x1y2z1w2"
            case .sync: "-up0q0r2x1y2z1w2"
            }
        }
    }

    enum PathMode: String, CaseIterable, Identifiable {
        case relative = "Relative pathnames", full = "Full pathnames", absolute = "Absolute pathnames"
        var id: String { rawValue }
    }

    var archivePath: String
    var format: ArchiveFormat = .sevenZip
    var level = 5
    var method = "LZMA2"
    var dictionary: Int64 = 16 * MB
    var wordSize = 32
    var solidBlock = "2 GB"
    var threads = Hardware.cores
    var volumes = ""
    var parameters = ""
    var updateMode: UpdateMode = .add
    var pathMode: PathMode = .relative
    var excludeMetadata = true
    var storeExtendedAttributes = true
    var deleteAfter = false
    var password = ""
    var passwordAgain = ""
    var showPassword = false
    var encryption = "AES-256"
    var encryptNames = false

    var dictionaryApplies: Bool { format.compresses && level > 0 && (method.hasPrefix("LZMA") || method == "PPMd") }
    var solidApplies: Bool { format == .sevenZip && level > 0 }
    var passwordsMatch: Bool { showPassword || password == passwordAgain }

    mutating func formatChanged() {
        method = format.methods.first ?? "Store"
        encryption = format.encryptionMethods.first ?? ""
        if !format.supportsEncryption { password = ""; passwordAgain = ""; encryptNames = false }
        let base = (archivePath as NSString).deletingPathExtension
        archivePath = base + "." + format.fileExtension
        applyLevelDefaults()
    }

    mutating func applyLevelDefaults() {
        let dict: [Int: Int64] = [1: 1 * MB, 3: 4 * MB, 5: 16 * MB, 7: 32 * MB, 9: 64 * MB]
        let word: [Int: Int] = [1: 32, 3: 32, 5: 32, 7: 64, 9: 64]
        let solid: [Int: String] = [1: "256 MB", 3: "1 GB", 5: "2 GB", 7: "4 GB", 9: "4 GB"]
        dictionary = method == "PPMd" ? (level >= 7 ? 128 * MB : 16 * MB) : (dict[level] ?? 16 * MB)
        wordSize = word[level] ?? 32
        solidBlock = solid[level] ?? "2 GB"
    }

    /// Rough memory needs, following 7-Zip's LZMA2 estimate (about 11.5× the dictionary per two threads).
    var memory: (compress: Int64, decompress: Int64) {
        guard format.compresses, level > 0 else { return (6 * MB, 2 * MB) }
        switch method {
        case "LZMA2", "LZMA":
            let encoders = Int64(method == "LZMA2" ? (threads + 1) / 2 : 1)
            return (encoders * (dictionary * 23 / 2 + 6 * MB) + Int64(threads) * 4 * MB + 32 * MB, dictionary + 3 * MB)
        case "PPMd": return (dictionary * Int64(threads) + 10 * MB, dictionary + 2 * MB)
        case "BZip2": return (Int64(threads) * 10 * MB, Int64(threads) * 6 * MB)
        default: return (Int64(threads) * 4 * MB + 10 * MB, 2 * MB)
        }
    }

    var ratio: Double {
        guard format.compresses, level > 0 else { return 1 }
        let lzma: [Int: Double] = [1: 0.42, 3: 0.36, 5: 0.31, 7: 0.29, 9: 0.28]
        let deflate: [Int: Double] = [1: 0.45, 3: 0.41, 5: 0.38, 7: 0.37, 9: 0.36]
        if method == "BZip2" { return 0.35 }
        if format == .zip || format == .gzip { return deflate[level] ?? 0.38 }
        return (lzma[level] ?? 0.31) * (method == "PPMd" ? 0.93 : 1)
    }

    var methodTag: String {
        if level == 0 { return "Copy" }
        switch method {
        case "LZMA2", "LZMA": return "\(method):\(Int(log2(Double(dictionary))))"
        case "PPMd": return "PPMd:o6:mem\(Int(log2(Double(dictionary))))"
        default: return method
        }
    }

    /// The same job for 7-Zip's macOS console binary, `7zz`.
    func commandLine(sources: [String]) -> String {
        var a = ["7zz", updateMode == .add ? "a" : "u", "-t\(format.rawValue)"]
        if format.compresses { a.append("-mx\(level)") }
        if format == .sevenZip && level > 0 {
            a.append("-m0=\(method.lowercased())")
            if method.hasPrefix("LZMA") { a.append("-md=\(dictionary >> 20)m"); a.append("-mfb=\(wordSize)") }
            let solid = solidBlock == "Non-solid" ? "off" : solidBlock == "Solid" ? "on" : solidBlock.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "B", with: "").lowercased()
            a.append("-ms=\(solid)")
        }
        if format == .zip && level > 0 { a.append("-mm=\(method)") }
        if format.compresses { a.append("-mmt=\(threads)") }
        if let s = updateMode.switches { a.append(s) }
        if pathMode == .full { a.append("-spf2") }
        if pathMode == .absolute { a.append("-spf") }
        if !password.isEmpty {
            a.append("-p")
            if format == .zip { a.append(encryption == "AES-256" ? "-mem=AES256" : "-mem=ZipCrypto") }
            if format == .sevenZip && encryptNames { a.append("-mhe=on") }
        }
        let vol = volumes.trimmingCharacters(in: .whitespaces)
        if !vol.isEmpty { a.append("-v\(vol.lowercased())") }
        if deleteAfter { a.append("-sdel") }
        if excludeMetadata { a += ["-xr!.DS_Store", "-xr!._*", "-xr!__MACOSX"] }
        if !parameters.isEmpty { a.append(parameters) }
        a.append(quoted((archivePath as NSString).lastPathComponent))
        a += sources.prefix(3).map(quoted)
        if sources.count > 3 { a.append("… \(sources.count - 3) more") }
        return a.joined(separator: " ")
    }
}

/// Settings of 7-Zip's “Extract” dialog.
struct ExtractOptions {
    enum PathMode: String, CaseIterable, Identifiable {
        case full = "Full pathnames", current = "Current pathnames", none = "No pathnames", absolute = "Absolute pathnames"
        var id: String { rawValue }
    }

    enum Overwrite: String, CaseIterable, Identifiable {
        case ask = "Ask before overwrite", overwrite = "Overwrite without prompt", skip = "Skip existing files"
        case renameExtracted = "Auto rename extracted files", renameExisting = "Auto rename existing files"
        var id: String { rawValue }
        var cliSwitch: String? {
            switch self {
            case .ask: nil
            case .overwrite: "-aoa"
            case .skip: "-aos"
            case .renameExtracted: "-aou"
            case .renameExisting: "-aot"
            }
        }
    }

    var destination: String
    var createFolder = true
    var folderName: String
    var pathMode: PathMode = .full
    var overwrite: Overwrite = .ask
    var password = ""
    var eliminateDuplicateRoot = true
    var restoreExtendedAttributes = true
    var keepQuarantine = true
    var revealInFinder = false

    var targetPath: String {
        let base = destination.hasSuffix("/") ? String(destination.dropLast()) : destination
        return createFolder && !folderName.isEmpty ? base + "/" + folderName : base
    }

    func commandLine(archive: String, items: [String]) -> String {
        var a = ["7zz", pathMode == .none ? "e" : "x", quoted(archive), "-o" + quoted(targetPath)]
        if let s = overwrite.cliSwitch { a.append(s) }
        if eliminateDuplicateRoot && createFolder { a.append("-spe") }
        if pathMode == .absolute { a.append("-spf") }
        if !password.isEmpty { a.append("-p") }
        a += items.prefix(3).map(quoted)
        return a.joined(separator: " ")
    }
}

private func quoted(_ s: String) -> String {
    s.contains(where: { " \"'()&;".contains($0) }) ? "\"\(s)\"" : s
}

enum Checksum {
    static let algorithms = ["CRC-32", "CRC-64", "XXH64", "MD5", "SHA-1", "SHA-256", "SHA-384", "SHA-512", "SHA3-256", "BLAKE2sp"]
    static let lengths: [String: Int] = ["CRC-32": 8, "CRC-64": 16, "XXH64": 16, "MD5": 32, "SHA-1": 40, "SHA-256": 64, "SHA-384": 96, "SHA-512": 128, "SHA3-256": 64, "BLAKE2sp": 64]

    static func digest(_ node: FileNode, _ algorithm: String) -> String {
        if algorithm == "CRC-32", !node.crc.isEmpty { return node.crc }
        return Hash.hex("\(algorithm):\(node.name):\(node.size)", length: lengths[algorithm] ?? 8)
    }
}
