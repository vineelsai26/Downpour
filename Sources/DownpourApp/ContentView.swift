import SwiftUI
import Photos
import BackupCore
import VKit

struct ContentView: View {
    var body: some View {
        ScrollView {
            BackupBody()
        }
    }
}

/// The scrollable content. Kept separate from `ContentView`'s `ScrollView` so it
/// can also be rendered off-screen (ImageRenderer can't render ScrollViews).
struct BackupBody: View {
    @EnvironmentObject var controller: BackupController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            header
            PermissionsSection()
            DestinationSection()
            SourcesSection()
            OptionsSection()
            ScheduleSection()
            runControls
            if controller.isRunning || !controller.progress.isEmpty {
                ProgressSection()
            }
            if let last = controller.lastRun, !controller.isRunning {
                LastRunSection(summary: last)
            }
            if !controller.logLines.isEmpty {
                LogSection()
            }
        }
        .padding(Theme.pagePadding)
    }

    private var header: some View {
        AppHeader(
            title: "Downpour",
            subtitle: "Back up iCloud Drive & Photos to an external disk",
            systemImage: "externaldrive.badge.icloud"
        ) {
            if controller.hasDestination {
                Button { controller.revealInFinder() } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal backup in Finder")
                Button { controller.openLogFolder() } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .help("Open log folder")
            }
        }
    }

    @ViewBuilder private var runControls: some View {
        HStack(spacing: 12) {
            if controller.isRunning {
                Button(role: .cancel) { controller.cancel() } label: {
                    Label("Cancel", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            } else {
                Button { controller.start() } label: {
                    Label("Back Up Now", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!controller.canRun)
            }
        }
        if let reason = controller.disabledReason, !controller.isRunning {
            Label(reason, systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let error = controller.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Permissions

private struct PermissionsSection: View {
    @EnvironmentObject var controller: BackupController

    private var photosNeedsAttention: Bool {
        controller.includePhotos &&
        controller.photosStatus != .authorized &&
        controller.photosStatus != .limited
    }

    var body: some View {
        if photosNeedsAttention {
            Card(title: "Permissions", systemImage: "lock.shield") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Photos access required").font(.headline)
                        Text(photosMessage).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if controller.photosStatus == .notDetermined {
                        Button("Grant") { controller.requestPhotosAccess() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Open Settings") { controller.openPhotosPrivacySettings() }
                    }
                }
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "folder.badge.gearshape").foregroundStyle(.secondary)
                    Text("If iCloud Drive files fail to read, grant **Full Disk Access** too.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open") { controller.openFullDiskAccessSettings() }
                }
            }
        }
    }

    private var photosMessage: String {
        switch controller.photosStatus {
        case .denied, .restricted:
            return "Access was denied. Enable Downpour under Photos in System Settings (choose Full Access)."
        default:
            return "Grant access so your full-resolution photo & video originals can be backed up."
        }
    }
}

// MARK: - Destination

private struct DestinationSection: View {
    @EnvironmentObject var controller: BackupController

    var body: some View {
        Card(title: "Destination", systemImage: "externaldrive") {
            HStack {
                Text(controller.hasDestination ? controller.destinationPath : "No folder selected")
                    .foregroundStyle(controller.hasDestination ? .primary : .secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { controller.chooseDestination() }
            }
            if let fs = controller.filesystemInfo {
                HStack(spacing: 16) {
                    Label(fs.typeName.uppercased(), systemImage: "internaldrive")
                    Label("\(ByteFormat.string(fs.freeBytes)) free", systemImage: "gauge.with.dots.needle.33percent")
                    if fs.supportsHardlinks {
                        Label("Snapshots", systemImage: "clock.arrow.circlepath").foregroundStyle(.green)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)

                if !fs.supportsHardlinks {
                    Label("This disk is \(fs.typeName.uppercased()), which can't store snapshot history efficiently. It'll keep a single mirror instead. Format as APFS for versioned snapshots.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Sources

private struct SourcesSection: View {
    @EnvironmentObject var controller: BackupController

    var body: some View {
        Card(title: "What to back up", systemImage: "checklist") {
            Toggle(isOn: $controller.includeDrive) {
                Label("iCloud Drive", systemImage: "folder")
            }
            Toggle(isOn: $controller.includePhotos) {
                Label("iCloud Photos", systemImage: "photo.on.rectangle")
            }
            if controller.includePhotos {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Include videos", isOn: $controller.includePhotoVideos)
                    Toggle("Include hidden photos", isOn: $controller.includeHiddenPhotos)
                }
                .toggleStyle(.checkbox)
                .font(.callout)
                .padding(.leading, 26)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Options

private struct OptionsSection: View {
    @EnvironmentObject var controller: BackupController

    var body: some View {
        Card(title: "Options", systemImage: "slider.horizontal.3") {
            Stepper(value: $controller.retention, in: 0...100) {
                HStack {
                    Text("Keep snapshots")
                    Spacer()
                    Text(controller.retention == 0 ? "All" : "\(controller.retention)")
                        .foregroundStyle(.secondary)
                }
            }
            Stepper(value: $controller.maxConcurrency, in: 1...12) {
                HStack {
                    OptionLabel("Parallel transfers", subtitle: "Download & copy this many files at once.")
                    Spacer()
                    Text("\(controller.maxConcurrency)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Toggle(isOn: $controller.verify) {
                OptionLabel("Verify copies (slower)", subtitle: "Re-hash each copied file to confirm it wrote correctly.")
            }
            Toggle(isOn: $controller.notifyOnCompletion) {
                OptionLabel("Notify when finished", subtitle: "Show a notification after each backup.")
            }
            Toggle(isOn: $controller.ejectAfterBackup) {
                OptionLabel("Eject disk after backup", subtitle: "Safely unmount the backup disk when a run succeeds.")
            }
        }
    }
}

// MARK: - Schedule

private struct ScheduleSection: View {
    @EnvironmentObject var controller: BackupController

    var body: some View {
        Card(title: "Automatic backups", systemImage: "calendar.badge.clock") {
            Toggle(isOn: $controller.scheduleEnabled) {
                OptionLabel(
                    "Run backups on a schedule",
                    subtitle: controller.scheduleEnabled ? controller.scheduleSummary : "Off — back up manually"
                )
            }
            if controller.scheduleEnabled {
                Picker("Frequency", selection: $controller.scheduleFrequency) {
                    ForEach(ScheduleFrequency.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)

                if controller.scheduleFrequency == .daily {
                    Stepper(value: $controller.scheduleHour, in: 0...23) {
                        HStack {
                            Text("At")
                            Spacer()
                            Text(String(format: "%02d:00", controller.scheduleHour))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                Label("Runs in the background even when the app is closed, as long as you're logged in and the disk is connected.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Progress

private struct ProgressSection: View {
    @EnvironmentObject var controller: BackupController

    var body: some View {
        Card(title: controller.isRunning ? "Backing up…" : "Last run progress",
             systemImage: "arrow.triangle.2.circlepath") {
            // Headline percent + counts.
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(controller.overallFraction * 100))%")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    if controller.overallTotal > 0 {
                        Text("\(controller.overallCompleted) of \(controller.overallTotal) items")
                            .font(.callout)
                    }
                    Text(Format.duration(controller.elapsed) + " elapsed")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if controller.isRunning && controller.overallTotal == 0 {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                ProgressView(value: controller.overallFraction)
            }

            // Stat row.
            HStack(spacing: 0) {
                StatCell("Copied", "\(controller.totalCopied)")
                StatCell("Reused", "\(controller.totalReused)")
                StatCell("Size", ByteFormat.string(controller.totalBytes))
                if controller.isRunning {
                    StatCell("Speed", controller.throughput > 0 ? Format.rate(controller.throughput) : "—")
                    StatCell("ETA", controller.etaSeconds.map(Format.duration) ?? "—")
                }
            }

            // Per-source mini rows.
            ForEach(controller.progress) { p in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Label(p.source.displayName, systemImage: p.source == .drive ? "folder" : "photo.on.rectangle")
                            .font(.subheadline)
                        Spacer()
                        if p.finished {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if p.total > 0 {
                            Text("\(p.completed)/\(p.total)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    ProgressView(value: p.finished ? 1 : p.fraction)
                    Text(detail(for: p))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(.top, 2)
            }
        }
    }

    private func detail(for p: SourceProgress) -> String {
        if p.finished {
            return p.summary.map { "\($0.filesCopied) copied · \($0.filesReused) reused · \(ByteFormat.string($0.bytesCopied))" } ?? "Done"
        }
        if let item = p.currentItem {
            return "\(p.phase) — \((item as NSString).lastPathComponent)"
        }
        return p.phase
    }
}

// MARK: - Last run

private struct LastRunSection: View {
    let summary: RunSummary

    var body: some View {
        Card(title: "Last backup", systemImage: summary.succeeded ? "checkmark.seal" : "xmark.seal") {
            HStack {
                Image(systemName: summary.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(summary.succeeded ? .green : .orange)
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text(summary.succeeded ? "Succeeded" : "Finished with errors").font(.headline)
                    Text(summary.finishedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("\(summary.totalFilesCopied) files").font(.headline)
                    Text(ByteFormat.string(summary.totalBytesCopied)).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(summary.sources, id: \.source) { s in
                HStack {
                    Label(s.source.displayName, systemImage: s.source == .drive ? "folder" : "photo.on.rectangle")
                        .font(.caption)
                    Spacer()
                    Text("\(s.filesCopied) copied · \(s.filesReused) reused · \(ByteFormat.string(s.bytesCopied))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = summary.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Log

private struct LogSection: View {
    @EnvironmentObject var controller: BackupController

    var body: some View {
        Card(title: "Activity", systemImage: "text.alignleft") {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(controller.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                }
                .frame(height: 140)
                .onChange(of: controller.logLines.count) { _, count in
                    withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }
}

