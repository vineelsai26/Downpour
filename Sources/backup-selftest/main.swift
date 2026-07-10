import Foundation
import BackupCore

// Minimal self-test runner — `swift test`/XCTest requires full Xcode, which we
// don't assume. Run with:  swift run backup-selftest

final class TestRunner {
    var failures = 0
    var passed = 0

    func check(_ condition: Bool, _ message: String) {
        if condition {
            passed += 1
        } else {
            failures += 1
            FileHandle.standardError.write(Data("  ✗ \(message)\n".utf8))
        }
    }

    func run(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            print("✓ \(name)")
        } catch {
            failures += 1
            FileHandle.standardError.write(Data("✗ \(name): \(error)\n".utf8))
        }
    }
}

func makeTempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("icbackup-selftest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
func writeFile(_ relative: String, _ contents: String, in root: URL) throws -> (size: Int64, modified: TimeInterval) {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.data(using: .utf8)!.write(to: url)
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    return (Int64(values.fileSize ?? 0), values.contentModificationDate?.timeIntervalSince1970 ?? 0)
}

let t = TestRunner()
let fm = FileManager.default

t.run("manifest round trip") {
    let tmp = try makeTempDir(); defer { try? fm.removeItem(at: tmp) }
    var manifest = Manifest(source: .drive)
    manifest.entries["a/b.txt"] = ManifestEntry(relativePath: "a/b.txt", size: 10, modified: 123, sha256: "abc", snapshotName: "s1")
    try manifest.save(to: tmp)
    let loaded = Manifest.load(for: .drive, in: tmp)
    t.check(loaded.entries["a/b.txt"]?.size == 10, "manifest size persisted")
    t.check(loaded.entries["a/b.txt"]?.snapshotName == "s1", "manifest snapshotName persisted")
}

t.run("hardlink snapshot reuses unchanged files") {
    let tmp = try makeTempDir(); defer { try? fm.removeItem(at: tmp) }
    let src = tmp.appendingPathComponent("src", isDirectory: true)
    let dst = tmp.appendingPathComponent("dst", isDirectory: true)
    let meta = try writeFile("notes.txt", "hello", in: src)

    let store = SnapshotStore(sourceRoot: dst, supportsHardlinks: true)
    t.check(store.strategy == .hardlink, "APFS temp dir uses hardlink strategy")

    let s1 = try store.beginSession(timestamp: Date(timeIntervalSince1970: 1000))
    let r1 = try s1.placeFile(relativePath: "notes.txt", sourceURL: src.appendingPathComponent("notes.txt"),
                              size: meta.size, modified: meta.modified, previousEntry: nil, verify: false)
    t.check(r1.copied, "first snapshot copies fresh")
    try store.finalize(session: s1, retention: 10)

    let prev = ManifestEntry(relativePath: "notes.txt", size: meta.size, modified: meta.modified, snapshotName: s1.snapshotName)
    let s2 = try store.beginSession(timestamp: Date(timeIntervalSince1970: 2000))
    let r2 = try s2.placeFile(relativePath: "notes.txt", sourceURL: src.appendingPathComponent("notes.txt"),
                              size: meta.size, modified: meta.modified, previousEntry: prev, verify: false)
    t.check(!r2.copied, "unchanged file hardlinked, not copied")
    try store.finalize(session: s2, retention: 10)

    let f1 = dst.appendingPathComponent("snapshots/\(s1.snapshotName)/notes.txt")
    let f2 = dst.appendingPathComponent("snapshots/\(s2.snapshotName)/notes.txt")
    let i1 = try f1.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
    let i2 = try f2.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
    t.check(i1 == i2, "hardlinked files share identity")
}

t.run("changed file is re-copied, not linked") {
    let tmp = try makeTempDir(); defer { try? fm.removeItem(at: tmp) }
    let src = tmp.appendingPathComponent("src", isDirectory: true)
    let dst = tmp.appendingPathComponent("dst", isDirectory: true)
    let m1 = try writeFile("doc.txt", "v1", in: src)
    let store = SnapshotStore(sourceRoot: dst, supportsHardlinks: true)
    let s1 = try store.beginSession(timestamp: Date(timeIntervalSince1970: 1000))
    _ = try s1.placeFile(relativePath: "doc.txt", sourceURL: src.appendingPathComponent("doc.txt"),
                         size: m1.size, modified: m1.modified, previousEntry: nil, verify: false)
    try store.finalize(session: s1, retention: 10)

    let m2 = try writeFile("doc.txt", "v2-longer", in: src) // changed size
    let prev = ManifestEntry(relativePath: "doc.txt", size: m1.size, modified: m1.modified, snapshotName: s1.snapshotName)
    let s2 = try store.beginSession(timestamp: Date(timeIntervalSince1970: 2000))
    let r2 = try s2.placeFile(relativePath: "doc.txt", sourceURL: src.appendingPathComponent("doc.txt"),
                              size: m2.size, modified: m2.modified, previousEntry: prev, verify: true)
    t.check(r2.copied, "changed file is copied fresh")
    let content = try String(contentsOf: dst.appendingPathComponent("snapshots/\(s2.snapshotName)/doc.txt"), encoding: .utf8)
    t.check(content == "v2-longer", "new snapshot has updated content")
}

t.run("mirror prunes deleted files") {
    let tmp = try makeTempDir(); defer { try? fm.removeItem(at: tmp) }
    let src = tmp.appendingPathComponent("src", isDirectory: true)
    let dst = tmp.appendingPathComponent("dst", isDirectory: true)
    try writeFile("keep.txt", "a", in: src)
    try writeFile("remove.txt", "b", in: src)
    let store = SnapshotStore(sourceRoot: dst, supportsHardlinks: false)
    t.check(store.strategy == .mirror, "non-hardlink fs uses mirror strategy")

    let s1 = try store.beginSession(timestamp: Date(timeIntervalSince1970: 1000))
    for name in ["keep.txt", "remove.txt"] {
        let v = try src.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        _ = try s1.placeFile(relativePath: name, sourceURL: src.appendingPathComponent(name),
                             size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate?.timeIntervalSince1970 ?? 0,
                             previousEntry: nil, verify: false)
    }
    try store.finalize(session: s1, retention: nil)
    t.check(fm.fileExists(atPath: dst.appendingPathComponent("current/remove.txt").path), "remove.txt present after run 1")

    let s2 = try store.beginSession(timestamp: Date(timeIntervalSince1970: 2000))
    let v = try src.appendingPathComponent("keep.txt").resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    _ = try s2.placeFile(relativePath: "keep.txt", sourceURL: src.appendingPathComponent("keep.txt"),
                         size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate?.timeIntervalSince1970 ?? 0,
                         previousEntry: nil, verify: false)
    try store.finalize(session: s2, retention: nil)
    t.check(fm.fileExists(atPath: dst.appendingPathComponent("current/keep.txt").path), "keep.txt retained")
    t.check(!fm.fileExists(atPath: dst.appendingPathComponent("current/remove.txt").path), "deleted file pruned from mirror")
}

t.run("retention prunes old snapshots") {
    let tmp = try makeTempDir(); defer { try? fm.removeItem(at: tmp) }
    let src = tmp.appendingPathComponent("src", isDirectory: true)
    let dst = tmp.appendingPathComponent("dst", isDirectory: true)
    let meta = try writeFile("f.txt", "x", in: src)
    let store = SnapshotStore(sourceRoot: dst, supportsHardlinks: true)
    for i in 0..<5 {
        let s = try store.beginSession(timestamp: Date(timeIntervalSince1970: TimeInterval(1000 + i)))
        _ = try s.placeFile(relativePath: "f.txt", sourceURL: src.appendingPathComponent("f.txt"),
                            size: meta.size, modified: meta.modified, previousEntry: nil, verify: false)
        try store.finalize(session: s, retention: 3)
    }
    let snaps = (try? fm.contentsOfDirectory(atPath: dst.appendingPathComponent("snapshots").path)) ?? []
    t.check(snaps.count == 3, "retention kept only 3 snapshots (got \(snaps.count))")
}

t.run("non-positive retention never deletes snapshots") {
    let tmp = try makeTempDir(); defer { try? fm.removeItem(at: tmp) }
    let src = tmp.appendingPathComponent("src", isDirectory: true)
    let dst = tmp.appendingPathComponent("dst", isDirectory: true)
    let meta = try writeFile("f.txt", "x", in: src)
    let store = SnapshotStore(sourceRoot: dst, supportsHardlinks: true)
    for i in 0..<2 {
        let s = try store.beginSession(timestamp: Date(timeIntervalSince1970: TimeInterval(2000 + i)))
        _ = try s.placeFile(relativePath: "f.txt", sourceURL: src.appendingPathComponent("f.txt"), size: meta.size, modified: meta.modified, previousEntry: nil, verify: false)
        try store.finalize(session: s, retention: 0)
    }
    let snaps = (try? fm.contentsOfDirectory(atPath: dst.appendingPathComponent("snapshots").path)) ?? []
    t.check(snaps.count == 2, "non-positive retention must preserve snapshots")
}

t.run("snapshot paths cannot escape the target directory") {
    let tmp = try makeTempDir(); defer { try? fm.removeItem(at: tmp) }
    let src = tmp.appendingPathComponent("src", isDirectory: true)
    let dst = tmp.appendingPathComponent("dst", isDirectory: true)
    let meta = try writeFile("f.txt", "x", in: src)
    let store = SnapshotStore(sourceRoot: dst, supportsHardlinks: true)
    let session = try store.beginSession(timestamp: Date())
    var rejected = false
    do { _ = try session.placeFile(relativePath: "../escape.txt", sourceURL: src.appendingPathComponent("f.txt"), size: meta.size, modified: meta.modified, previousEntry: nil, verify: false) } catch { rejected = true }
    t.check(rejected, "path traversal must be rejected")
}

t.run("downloader resolves .icloud placeholder names") {
    let dl = ICloudDownloader()
    let placeholder = URL(fileURLWithPath: "/x/y/.Report.pdf.icloud")
    let real = dl.realItemURL(for: placeholder)
    t.check(real.lastPathComponent == "Report.pdf", "placeholder collapses to real name")
    t.check(dl.isPlaceholder(placeholder), "detects placeholder")
    t.check(!dl.isPlaceholder(URL(fileURLWithPath: "/x/y/Report.pdf")), "real file is not a placeholder")
}

t.run("filesystem inspection works on temp dir") {
    let tmp = try makeTempDir(); defer { try? fm.removeItem(at: tmp) }
    let info = FilesystemInfo.inspect(tmp)
    t.check(info != nil, "inspect returns info")
    t.check((info?.totalBytes ?? 0) > 0, "total capacity reported")
}

print("\n\(t.passed) checks passed, \(t.failures) failed")
exit(t.failures == 0 ? 0 : 1)
