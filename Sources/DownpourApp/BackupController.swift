import Foundation
import SwiftUI
import AppKit
import Photos
import BackupCore

/// Live progress for one source during a run.
struct SourceProgress: Identifiable {
    let source: BackupSource
    var phase: String = ""
    var completed: Int = 0
    var total: Int = 0
    var copied: Int = 0
    var reused: Int = 0
    var bytes: Int64 = 0
    var currentItem: String?
    var finished: Bool = false
    var summary: SourceSummary?

    var id: BackupSource { source }
    var fraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }
}

/// Owns app state, persistence, and orchestrates backup runs for the UI.
@MainActor
final class BackupController: ObservableObject {
    // Configuration (persisted).
    @Published var destinationPath: String { didSet { persist(); refreshDestinationInfo() } }
    @Published var includeDrive: Bool { didSet { persist() } }
    @Published var includePhotos: Bool { didSet { persist() } }
    @Published var includePhotoVideos: Bool { didSet { persist() } }
    @Published var includeHiddenPhotos: Bool { didSet { persist() } }
    @Published var retention: Int { didSet { persist() } }
    @Published var verify: Bool { didSet { persist() } }
    @Published var ejectAfterBackup: Bool { didSet { persist() } }
    @Published var notifyOnCompletion: Bool { didSet { persist() } }
    @Published var maxConcurrency: Int { didSet { persist() } }

    // Scheduling (persisted + reflected to launchd).
    @Published var scheduleEnabled: Bool { didSet { persist(); applySchedule() } }
    @Published var scheduleFrequency: ScheduleFrequency { didSet { persist(); applySchedule() } }
    @Published var scheduleHour: Int { didSet { persist(); applySchedule() } }

    // Runtime state.
    @Published var isRunning = false
    @Published var progress: [SourceProgress] = []
    @Published var logLines: [String] = []
    @Published var lastRun: RunSummary?
    @Published var filesystemInfo: FilesystemInfo?
    @Published var errorMessage: String?
    @Published var photosStatus: PHAuthorizationStatus = .notDetermined
    @Published var now = Date()
    @Published private(set) var startedAt: Date?

    private var runTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private let defaults = UserDefaults.standard

    init() {
        destinationPath = defaults.string(forKey: AppSettings.Keys.destination) ?? ""
        includeDrive = AppSettings.bool(AppSettings.Keys.includeDrive, default: true)
        includePhotos = AppSettings.bool(AppSettings.Keys.includePhotos, default: true)
        includePhotoVideos = AppSettings.bool(AppSettings.Keys.includePhotoVideos, default: true)
        includeHiddenPhotos = AppSettings.bool(AppSettings.Keys.includeHiddenPhotos, default: false)
        retention = AppSettings.int(AppSettings.Keys.retention, default: 10)
        verify = AppSettings.bool(AppSettings.Keys.verify, default: false)
        ejectAfterBackup = AppSettings.bool(AppSettings.Keys.ejectAfterBackup, default: false)
        notifyOnCompletion = AppSettings.bool(AppSettings.Keys.notifyOnCompletion, default: true)
        maxConcurrency = AppSettings.int(AppSettings.Keys.maxConcurrency, default: 6)
        scheduleEnabled = ScheduleManager.isInstalled
        scheduleFrequency = ScheduleFrequency(rawValue: defaults.string(forKey: AppSettings.Keys.scheduleFrequency) ?? "") ?? .daily
        scheduleHour = AppSettings.int(AppSettings.Keys.scheduleHour, default: 2)

        refreshDestinationInfo()
        refreshPermissions()
    }

    // MARK: Derived state

    var hasDestination: Bool { !destinationPath.isEmpty }
    var canRun: Bool { hasDestination && (includeDrive || includePhotos) && !isRunning }
    var destinationURL: URL? {
        destinationPath.isEmpty ? nil : URL(fileURLWithPath: destinationPath, isDirectory: true)
    }

    var disabledReason: String? {
        if isRunning { return nil }
        if !hasDestination { return "Choose a backup destination first." }
        if !includeDrive && !includePhotos { return "Select at least one thing to back up." }
        return nil
    }

    // MARK: Live run stats

    var elapsed: TimeInterval { startedAt.map { now.timeIntervalSince($0) } ?? 0 }
    var overallTotal: Int { progress.reduce(0) { $0 + $1.total } }
    var overallCompleted: Int { progress.reduce(0) { $0 + $1.completed } }
    var totalBytes: Int64 { progress.reduce(0) { $0 + $1.bytes } }
    var totalCopied: Int { progress.reduce(0) { $0 + $1.copied } }
    var totalReused: Int { progress.reduce(0) { $0 + $1.reused } }

    var overallFraction: Double {
        if !progress.isEmpty && progress.allSatisfy(\.finished) { return 1 }
        guard overallTotal > 0 else { return 0 }
        return min(1, Double(overallCompleted) / Double(overallTotal))
    }

    /// Bytes per second over the run so far.
    var throughput: Double {
        elapsed > 0.5 ? Double(totalBytes) / elapsed : 0
    }

    /// Estimated seconds remaining, from the file-processing rate.
    var etaSeconds: TimeInterval? {
        guard overallTotal > 0, overallCompleted > 0, elapsed > 1 else { return nil }
        let rate = Double(overallCompleted) / elapsed
        guard rate > 0 else { return nil }
        let remaining = Double(overallTotal - overallCompleted)
        return remaining / rate
    }

    // MARK: Destination

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Backup Folder"
        panel.message = "Pick a folder on your external disk to store backups."
        if panel.runModal() == .OK, let url = panel.url {
            destinationPath = url.path
        }
    }

    func refreshDestinationInfo() {
        guard let url = destinationURL else { filesystemInfo = nil; lastRun = nil; return }
        filesystemInfo = FilesystemInfo.inspect(url)
        lastRun = BackupEngine.lastRun(in: url)
    }

    func revealInFinder() {
        guard let url = destinationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openLogFolder() {
        NSWorkspace.shared.open(ScheduleManager.logDirectory)
    }

    // MARK: Permissions

    func refreshPermissions() {
        photosStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestPhotosAccess() {
        Task {
            _ = await PhotoKitExporter().requestAuthorization()
            await MainActor.run { self.refreshPermissions() }
        }
    }

    func openPhotosPrivacySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")
    }

    func openFullDiskAccessSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    // MARK: Scheduling

    var scheduleSummary: String {
        guard scheduleEnabled else { return "Off" }
        switch scheduleFrequency {
        case .daily: return "Daily at \(String(format: "%02d:00", scheduleHour))"
        default: return scheduleFrequency.label
        }
    }

    private func applySchedule() {
        do {
            if scheduleEnabled {
                try ScheduleManager.install(frequency: scheduleFrequency, hour: scheduleHour)
            } else {
                ScheduleManager.uninstall()
            }
        } catch {
            errorMessage = "Couldn't update the schedule: \(error.localizedDescription)"
        }
    }

    // MARK: Run / cancel

    func start() {
        guard let url = destinationURL, canRun else { return }
        var sources = Set<BackupSource>()
        if includeDrive { sources.insert(.drive) }
        if includePhotos { sources.insert(.photos) }

        let config = BackupConfig(
            destinationRoot: url,
            sources: sources,
            snapshotRetention: retention > 0 ? retention : nil,
            verifyAfterCopy: verify,
            includePhotoVideos: includePhotoVideos,
            includeHiddenPhotos: includeHiddenPhotos,
            maxConcurrency: maxConcurrency
        )

        isRunning = true
        errorMessage = nil
        logLines = []
        startedAt = Date()
        now = Date()
        progress = BackupSource.allCases
            .filter { sources.contains($0) }
            .map { SourceProgress(source: $0) }
        startTicking()

        let reporter = ClosureReporter { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.apply(event) }
        }
        let engine = BackupEngine()

        runTask = Task.detached(priority: .utility) {
            let failure: String?
            do {
                _ = try await engine.run(config: config, reporter: reporter)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { self.finish(failure: failure) }
        }
    }

    func cancel() {
        runTask?.cancel()
        appendLog("Cancelling…")
    }

    private func finish(failure: String?) {
        isRunning = false
        stopTicking()
        refreshDestinationInfo()
        if let failure { errorMessage = failure }

        let succeeded = failure == nil && (lastRun?.succeeded ?? true)
        if notifyOnCompletion {
            notify(
                title: succeeded ? "Downpour complete" : "Downpour finished with issues",
                body: "\(totalCopied) copied · \(ByteFormat.string(totalBytes))"
            )
        }
        if ejectAfterBackup && succeeded {
            ejectDestination()
        }
    }

    func ejectDestination() {
        guard let fs = filesystemInfo, fs.volumeURL.path != "/" else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["eject", fs.volumeURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            appendLog("Ejecting \(fs.volumeURL.lastPathComponent)…")
        } catch {
            appendLog("⚠️ Couldn't eject disk: \(error.localizedDescription)")
        }
    }

    // MARK: Live timer

    private func startTicking() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.now = Date() }
        }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
        now = Date()
    }

    // MARK: Event handling

    private func apply(_ event: BackupEvent) {
        switch event {
        case .phaseChanged(let source, let phase):
            updateProgress(source) { $0.phase = phase }
            appendLog("[\(source.displayName)] \(phase)")
        case .progress(let source, let completed, let total, let bytes, let item):
            updateProgress(source) {
                $0.completed = completed; $0.total = total; $0.bytes = bytes; $0.currentItem = item
            }
        case .itemBackedUp(let source, _, _, let reused):
            updateProgress(source) { reused ? ($0.reused += 1) : ($0.copied += 1) }
        case .warning(let source, let message):
            appendLog("⚠️ \(source.map { "[\($0.displayName)] " } ?? "")\(message)")
        case .log(let message):
            appendLog(message)
        case .sourceFinished(let summary):
            updateProgress(summary.source) {
                $0.finished = true; $0.summary = summary
                $0.copied = summary.filesCopied; $0.reused = summary.filesReused
            }
            appendLog("[\(summary.source.displayName)] done — \(summary.filesCopied) copied, \(summary.filesReused) reused, \(ByteFormat.string(summary.bytesCopied))")
        case .runFinished(let summary):
            lastRun = summary
        }
    }

    private func updateProgress(_ source: BackupSource, _ mutate: (inout SourceProgress) -> Void) {
        if let idx = progress.firstIndex(where: { $0.source == source }) {
            mutate(&progress[idx])
        } else {
            var p = SourceProgress(source: source)
            mutate(&p)
            progress.append(p)
        }
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
    }

    private func notify(title: String, body: String) {
        let t = title.replacingOccurrences(of: "\"", with: "'")
        let b = body.replacingOccurrences(of: "\"", with: "'")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \"\(b)\" with title \"\(t)\""]
        try? process.run()
    }

    /// Populate a realistic in-progress state for off-screen UI previews.
    func applyDemoRunningState() {
        isRunning = true
        startedAt = Date(timeIntervalSinceNow: -95)
        now = Date()
        var drive = SourceProgress(source: .drive)
        drive.phase = "Backing up 1,240 files"
        drive.total = 1240; drive.completed = 1240; drive.copied = 312; drive.reused = 928
        drive.bytes = 4_300_000_000; drive.finished = true
        var photos = SourceProgress(source: .photos)
        photos.phase = "Backing up 8,800 photos & videos"
        photos.total = 8800; photos.completed = 5210; photos.copied = 5012; photos.reused = 198
        photos.bytes = 11_800_000_000; photos.currentItem = "2021/07/IMG_4821.HEIC"
        progress = [drive, photos]
        logLines = [
            "[iCloud Drive] done — 312 copied, 928 reused, 4.3 GB",
            "[iCloud Photos] Backing up 8,800 photos & videos",
        ]
    }

    // MARK: Persistence

    private func persist() {
        let d = defaults
        d.set(destinationPath, forKey: AppSettings.Keys.destination)
        d.set(includeDrive, forKey: AppSettings.Keys.includeDrive)
        d.set(includePhotos, forKey: AppSettings.Keys.includePhotos)
        d.set(includePhotoVideos, forKey: AppSettings.Keys.includePhotoVideos)
        d.set(includeHiddenPhotos, forKey: AppSettings.Keys.includeHiddenPhotos)
        d.set(retention, forKey: AppSettings.Keys.retention)
        d.set(verify, forKey: AppSettings.Keys.verify)
        d.set(ejectAfterBackup, forKey: AppSettings.Keys.ejectAfterBackup)
        d.set(notifyOnCompletion, forKey: AppSettings.Keys.notifyOnCompletion)
        d.set(maxConcurrency, forKey: AppSettings.Keys.maxConcurrency)
        d.set(scheduleEnabled, forKey: AppSettings.Keys.scheduleEnabled)
        d.set(scheduleFrequency.rawValue, forKey: AppSettings.Keys.scheduleFrequency)
        d.set(scheduleHour, forKey: AppSettings.Keys.scheduleHour)
    }
}
