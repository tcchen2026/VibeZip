import Foundation

/// Sample disk and archives used by the design build. Replace with a real 7-Zip engine bridge.
enum SampleLibrary {
    static func make() -> FileNode {
        let kestrel = A("Kestrel-4.2.0.7z", "2026-09-28 14:06", ArchiveInfo(.sevenZip, solid: true), [
            D("Kestrel-4.2.0", "2026-09-28 14:03", [
                D("bin", "2026-09-28 14:01", [
                    F("kestrel", 14_682_112, "2026-09-28 14:01", exec: true),
                    F("kestrel-cli", 3_214_880, "2026-09-28 14:01", exec: true),
                    F("kestrel-helper", 1_102_336, "2026-09-28 14:01", exec: true)]),
                D("lib", "2026-09-28 14:00", [
                    F("libkestrel.dylib", 8_716_288, "2026-09-28 14:00", exec: true),
                    F("libkestrel-render.dylib", 5_330_944, "2026-09-28 14:00", exec: true)]),
                D("docs", "2026-09-27 19:42", [
                    D("api", "2026-09-27 19:40", [
                        F("index.html", 48_213, "2026-09-27 19:40"), F("classes.html", 96_440, "2026-09-27 19:40"),
                        F("search.js", 182_004, "2026-09-27 19:39"), F("styles.css", 21_776, "2026-09-27 19:39")]),
                    F("manual.pdf", 6_204_118, "2026-09-26 11:15"),
                    F("quick-start.md", 14_302, "2026-09-27 19:38")]),
                D("assets", "2026-09-25 16:20", [
                    D("icons", "2026-09-25 16:20", [F("AppIcon-1024.png", 1_482_330, "2026-09-25 16:18"), F("toolbar.pdf", 88_120, "2026-09-25 16:20")]),
                    D("sounds", "2026-09-12 10:02", [F("chime.caf", 402_118, "2026-09-12 10:02"), F("done.caf", 198_344, "2026-09-12 10:02")]),
                    D("fonts", "2026-08-30 09:44", [F("KestrelSans-Regular.otf", 312_448, "2026-08-30 09:44"), F("KestrelSans-Bold.otf", 318_902, "2026-08-30 09:44")])]),
                D("config", "2026-09-24 09:05", [F("defaults.plist", 8_412, "2026-09-24 09:05"), F("presets.json", 22_931, "2026-09-24 09:01")]),
                F("CHANGELOG.md", 41_870, "2026-09-28 13:52"),
                F("README.md", 9_214, "2026-09-28 13:55"),
                F("LICENSE.txt", 11_357, "2026-01-14 10:00"),
                F("NOTICE", 2_104, "2026-01-14 10:00")])
        ])

        let recordings = A("field-recordings-2026.zip", "2026-09-19 21:14",
                           ArchiveInfo(.zip, encrypted: true, comment: "Field recordings, September 2026.\nRecorded on a Zoom F3 at 48 kHz / 32-bit float."), [
            F("Lisbon - Tram 28.wav", 48_211_904, "2026-09-04 08:12"),
            F("Rain on skylight.wav", 31_458_816, "2026-09-09 23:40"),
            F("Market at dawn.wav", 57_016_320, "2026-09-11 06:05"),
            F("notes.txt", 3_212, "2026-09-19 21:10")])

        let linuxTar = A("linux-6.18.tar", "2025-11-30 22:41", ArchiveInfo(.tar), [
            D("linux-6.18", "2025-11-30 22:41", [
                D("arch", "2025-11-30 22:41", [F("Kconfig", 91_234, "2025-11-30 22:41")]),
                D("drivers", "2025-11-30 22:41", [F("Makefile", 6_044, "2025-11-30 22:41")]),
                D("fs", "2025-11-30 22:41", [F("namei.c", 156_204, "2025-11-30 22:41")]),
                D("kernel", "2025-11-30 22:41", [F("fork.c", 89_120, "2025-11-30 22:41")]),
                D("mm", "2025-11-30 22:41", [F("memory.c", 192_330, "2025-11-30 22:41")]),
                F("COPYING", 496, "2025-11-30 22:41"), F("MAINTAINERS", 812_345, "2025-11-30 22:41"),
                F("Makefile", 71_104, "2025-11-30 22:41"), F("README", 727, "2025-11-30 22:41")])])
        let linuxXz = A("linux-6.18.tar.xz", "2025-11-30 22:44", ArchiveInfo(.xz), [linuxTar])

        let ubuntu = A("ubuntu-26.04-desktop-arm64.iso", "2026-04-23 17:02", ArchiveInfo(.iso), [
            D("boot", "2026-04-23 16:50", [F("grub.cfg", 1_342, "2026-04-23 16:50")]),
            D("casper", "2026-04-23 16:58", [F("minimal.squashfs", 2_147_221_504, "2026-04-23 16:58"), F("vmlinuz", 17_391_104, "2026-04-23 16:41")]),
            D("EFI", "2026-04-23 16:50", [F("bootaa64.efi", 951_816, "2026-04-23 16:50")]),
            F("md5sum.txt", 41_220, "2026-04-23 17:01")])

        let specimens = A("Type-Specimens.rar", "2026-08-02 12:30", ArchiveInfo(.rar), [
            F("Grotesk Specimen.pdf", 12_204_800, "2026-08-02 12:20"),
            F("Serif Specimen.pdf", 9_933_120, "2026-08-02 12:21"),
            F("read-me.txt", 1_840, "2026-08-02 12:29")])

        let taxes = A("Taxes 2025.7z", "2026-04-11 20:03", ArchiveInfo(.sevenZip, solid: true, encrypted: true, headersEncrypted: true), [
            D("Taxes 2025", "2026-04-11 20:02", [
                F("Return - final.pdf", 1_302_220, "2026-04-11 19:58"),
                F("Receipts.csv", 88_120, "2026-04-10 12:12"),
                F("1099 forms.pdf", 702_334, "2026-03-02 09:15")])])

        let contracts = A("Contracts.zip", "2026-07-21 10:15", ArchiveInfo(.zip), [
            F("Northwind - MSA (signed).pdf", 902_114, "2026-07-21 10:11"),
            F("Northwind - SOW 3.pdf", 312_664, "2026-07-21 10:12")])

        let photos = A("Photos-2024.7z.001", "2025-01-06 23:12", ArchiveInfo(.sevenZip, solid: true, volumes: 3), [
            D("Photos 2024", "2025-01-06 22:50", [
                F("IMG_0012.HEIC", 3_204_112, "2024-01-14 12:02"),
                F("IMG_2230.MOV", 3_122_045_120, "2024-07-09 09:10"),
                F("IMG_3940.MOV", 6_301_122_048, "2024-12-25 11:06")])])

        for archive in [linuxTar, linuxXz, kestrel, recordings, ubuntu, specimens, taxes, contracts, photos] {
            Packer.pack(archive)
        }
        ubuntu.size = 5_932_124_160

        return D("", "2026-06-08 10:00", [
            D("Applications", "2026-10-02 18:30", [
                F("Sevenfold.app", 48_211_374, "2026-10-02 18:30", app: true),
                F("TextEdit.app", 6_120_448, "2026-09-15 09:00", app: true),
                F("Preview.app", 21_402_112, "2026-09-15 09:00", app: true)]),
            D("Users", "2026-06-08 10:00", [
                D("mira", "2026-10-07 09:12", [
                    D("Desktop", "2026-10-06 18:42", [
                        F("Kestrel 4.2 release notes.txt", 6_211, "2026-10-05 17:30"),
                        F("Screenshot 2026-10-06 at 18.42.11.png", 2_412_882, "2026-10-06 18:42"),
                        D("Moodboard", "2026-09-29 11:02", [F("palette.png", 412_230, "2026-09-29 11:00")])]),
                    D("Documents", "2026-10-01 08:40", [
                        D("Projects", "2026-10-01 08:40", [
                            D("kestrel-site", "2026-10-01 08:40", [F("index.html", 18_220, "2026-10-01 08:40")]),
                            F("roadmap-2027.key", 8_204_112, "2026-09-30 17:22")]),
                        taxes, contracts]),
                    D("Downloads", "2026-10-07 09:12", [
                        kestrel, recordings, linuxXz, ubuntu, specimens,
                        F("invoice-2026-09.pdf", 120_334, "2026-10-01 08:02"),
                        F("dataset-q3.csv", 4_120_338, "2026-10-03 16:45")]),
                    D("Music", "2026-06-08 10:00", []),
                    D("Pictures", "2026-09-30 19:20", [F("IMG_4021.HEIC", 3_301_228, "2026-09-30 19:20")])])]),
            D("Volumes", "2026-10-07 08:00", [
                D("Backup T7", "2026-10-07 08:00", [
                    D("Archives", "2026-01-07 00:10", [
                        photos,
                        F("Photos-2024.7z.002", 4_290_772_992, "2025-01-06 23:12"),
                        F("Photos-2024.7z.003", 1_294_011_904, "2025-01-06 23:12")])])])
        ])
    }

    // MARK: Builders

    private static func T(_ s: String) -> Date {
        let p = s.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" }).compactMap { Int($0) }
        var c = DateComponents()
        c.year = p[0]; c.month = p[1]; c.day = p[2]
        c.hour = p.count > 3 ? p[3] : 0
        c.minute = p.count > 4 ? p[4] : 0
        return Calendar.current.date(from: c) ?? .now
    }

    private static func F(_ name: String, _ size: Int64, _ t: String, exec: Bool = false, app: Bool = false) -> FileNode {
        FileNode(name: name, kind: .file, size: size, modified: T(t), executable: exec, app: app)
    }

    private static func D(_ name: String, _ t: String, _ children: [FileNode]) -> FileNode {
        FileNode(name: name, kind: .folder, modified: T(t), children: children)
    }

    private static func A(_ name: String, _ t: String, _ info: ArchiveInfo, _ children: [FileNode]) -> FileNode {
        FileNode(name: name, kind: .archive, modified: T(t), children: children, archive: info)
    }
}
