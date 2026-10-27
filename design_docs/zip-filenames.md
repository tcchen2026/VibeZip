# ZIP filename decoding

ZIP entries can carry names without an authoritative Unicode encoding marker.
Interpreting those bytes with the wrong legacy code page can produce unreadable
names even when file data is valid. VibeZip detects encoding from filename
metadata once per open session and uses the resulting names throughout browsing,
preview, extraction and updates. Merely opening an archive does not rewrite it.

## Minimal engine extension

The fork enables `IArchiveGetRawProps` in the ZIP handler and exposes `kpidPath`
as raw bytes only when an entry has neither a UTF-8 flag nor a valid Info-ZIP
Unicode path extra field. Unicode extra fields use the upstream validation,
including the CRC check against the original name bytes. Authoritative names
continue through the normal upstream path decoder.

This keeps macOS encoding detection outside the upstream format handler while
making the original bytes available to the native bridge. The changed files are
[ZipHandler.h](../CPP/7zip/Archive/Zip/ZipHandler.h) and
[ZipHandler.cpp](../CPP/7zip/Archive/Zip/ZipHandler.cpp).

## Detection and decoding order

1. Keep upstream decoding for entries with authoritative Unicode metadata.
2. For unmarked names, first attempt strict UTF-8, including the ASCII fast path.
3. Collect a sample from names that are not valid UTF-8: at most 128 whole names
   and 256 KiB, separated by newlines. Never sample file contents or split a name
   at the sample boundary.
4. Call the Swift `filename_code_page` callback with that sample. On macOS it
   asks Foundation to detect a non-lossy encoding from the permitted candidates.
5. Decode each remaining unmarked name as UTF-8, then the detected code page,
   then CP437 if the preceding attempts fail. Cache non-ASCII decoded names by
   native item index in the session.

| Code page | Candidate |
| --- | --- |
| 936 | GBK / CP936 |
| 54936 | GB18030 |
| 950 | Big5 / CP950 |
| 932 | Windows Shift-JIS / CP932 |
| 949 | Korean / CP949 |
| 437 | CP437 fallback |

The detector uses `NSString.stringEncoding` with suggested encodings only,
Windows-origin input and lossy conversion disabled. Unavailable or inconclusive
detection returns CP437. The non-macOS detector currently returns CP437 directly.
Native conversion uses `iconv`; no detector service or network is involved.

Sources: [ZIPFilenameEncoding.swift](../macOS/Sources/VibeZipCore/ZIPFilenameEncoding.swift),
[Engine.swift](../macOS/Sources/VibeZipCore/Engine.swift),
[CVibeZip.h](../macOS/Sources/CVibeZip/include/CVibeZip.h),
[Native.cpp](../macOS/Sources/CVibeZip/Native.cpp), especially `prepareZIPNames`
and `itemPath`.

## Identity and safety

Every consumer uses `itemPath` and the same decoded-name cache. Updates use these
paths when writing name properties, avoiding a different interpretation during
an edit. The item index remains the identity even if displayed names collide.
Normal namespace validation still rejects an ambiguous update or extraction.

Decode multibyte names before treating characters as path syntax. In CP932, for
example, a character can contain the byte `0x5c`; it is not a directory separator
inside that encoded character. Actual backslashes in a decoded path remain
subject to the existing rejection rule. Embedded NUL bytes in raw names are
rejected, and nonempty decoded paths still pass normal extraction validation.

## Limits and verification

Unmarked names are inherently ambiguous. One legacy encoding is selected for an
archive sample, with per-entry UTF-8 precedence and fallback; mixed legacy code
pages or short coincidental byte sequences may still be misidentified. There is
no manual encoding selector yet. Filename detection does not change text-file
content decoding in the preview window.

[ZIPFilenameEncodingTests.swift](../macOS/Tests/VibeZipCoreTests/ZIPFilenameEncodingTests.swift)
constructs ZIP records with explicit raw name bytes. Tests cover GBK, Big5,
CP932, CP437, marked and unmarked UTF-8, valid and invalid Unicode extra fields,
extraction, updates, nested writeback and unsafe names. Prefer such fixtures to
archives created by the same encoder under test.
