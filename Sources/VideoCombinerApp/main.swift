import SwiftUI
import AppKit
import AVKit
@preconcurrency import AVFoundation
import UniformTypeIdentifiers
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import CryptoKit

extension AVAssetExportSession: @retroactive @unchecked Sendable {}

/// Content view that does not report an intrinsic size, so the hosting view cannot force the window to resize.
final class FlexibleContainerView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}

enum AppLog {
    // Set by the view model so AppDelegate can write into the in-app Debug log.
    static var sink: ((String) -> Void)?

    static func log(_ line: String) {
        // Logging can happen off the main thread (e.g. during export). Always bounce to main
        // so the UI can append safely.
        DispatchQueue.main.async {
            sink?(line)
        }
    }
}

@main
struct VideoCombinerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The main window is created by AppKit in AppDelegate so content never renders under the title bar.
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var containerController: NSViewController?
    private var hostingController: NSHostingController<AnyView>?
    private var lastResizeLoggedSize: NSSize = .zero
    private var lastFrameLogged: NSRect = .zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        if window != nil { return }

        // Host SwiftUI in a child controller pinned to the window's contentLayoutGuide so it
        // never renders under the title bar even if macOS toggles "unified" titlebar chrome
        // during window zoom/magnify. AnyView lets us cast to NSHostingView<AnyView> so we can
        // set sizingOptions and stop the window from being forced to full screen height.
        let host = NSHostingController(rootView: AnyView(ContentView()))
        host.view.translatesAutoresizingMaskIntoConstraints = false

        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        win.title = "VideoCombiner"
        win.titlebarAppearsTransparent = false
        win.titleVisibility = .visible
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        win.showsResizeIndicator = true
        win.delegate = self

        let container = NSViewController()
        container.view = FlexibleContainerView()
        container.addChild(host)
        container.view.addSubview(host.view)
        win.contentViewController = container

        // Constrain SwiftUI content to the container's safeAreaLayoutGuide so it stays below
        // the titlebar/unified toolbar region (including during window zoom/magnify).
        let safe = container.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: safe.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
        ])

        // Stop the hosting view from dictating window size (it was forcing full screen height).
        if let hostingView = host.view as? NSHostingView<AnyView> {
            hostingView.sizingOptions = []  // No min/intrinsic/max; window size is fully under our control.
        }
        host.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        host.view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        // Seed a reasonable minimum size; we'll refine this after the window is on a screen.
        win.contentMinSize = NSSize(width: 820, height: 520)

        // Pick a sane initial size inside the visible screen area. This prevents "restored"
        // absurd window frames that push the bottom (footer) off-screen.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let targetContentW = min(980, visible.width * 0.92)
            let targetContentH = min(720, visible.height * 0.82)
            win.setContentSize(NSSize(width: targetContentW, height: targetContentH))

            var f = win.frame
            // Comfortable margins so the window doesn't feel glued to the screen or Dock.
            let edgeMargin: CGFloat = 28
            let bottomMargin: CGFloat = 40
            let inset = NSRect(
                x: visible.minX + edgeMargin,
                y: visible.minY + bottomMargin,
                width: visible.width - (edgeMargin * 2),
                height: visible.height - edgeMargin - bottomMargin
            )
            f.origin.x = inset.midX - f.width / 2
            f.origin.y = inset.midY - f.height / 2
            if f.minX < inset.minX { f.origin.x = inset.minX }
            if f.maxX > inset.maxX { f.origin.x = inset.maxX - f.width }
            if f.minY < inset.minY { f.origin.y = inset.minY }
            if f.maxY > inset.maxY { f.origin.y = inset.maxY - f.height }
            win.setFrame(f.integral, display: false)
        } else {
            win.center()
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
        self.containerController = container
        self.hostingController = host

        // Re-apply our frame after layout so we override any size the hosting view forces.
        let desiredFrame = win.frame
        DispatchQueue.main.async {
            let titlebarH = max(0, win.frame.height - win.contentRect(forFrameRect: win.frame).height)
            let titlebarText = String(format: "%.1f", titlebarH)
            AppLog.log("Window ready | styleMask=\(win.styleMask.rawValue) titlebarH=\(titlebarText) frame=\(NSStringFromRect(win.frame))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak win] in
            guard let win = win else { return }
            win.setFrame(desiredFrame, display: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak win] in
            guard let win = win else { return }
            win.setFrame(desiredFrame, display: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            Task { @MainActor in
                self?.applyScreenAwareMinSize()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        // Quit when the main window closes.
        NSApp.terminate(nil)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let delta = abs(frameSize.height - lastResizeLoggedSize.height) + abs(frameSize.width - lastResizeLoggedSize.width)
        if delta > 6 {
            lastResizeLoggedSize = frameSize
            AppLog.log("windowWillResize | proposed=\(NSStringFromSize(frameSize)) contentMin=\(NSStringFromSize(sender.contentMinSize)) contentMax=\(NSStringFromSize(sender.contentMaxSize))")
        }
        return frameSize
    }

    func windowDidResize(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        let f = win.frame
        let delta = abs(f.origin.x - lastFrameLogged.origin.x)
            + abs(f.origin.y - lastFrameLogged.origin.y)
            + abs(f.size.width - lastFrameLogged.size.width)
            + abs(f.size.height - lastFrameLogged.size.height)
        if delta > 6 {
            lastFrameLogged = f
            AppLog.log("windowDidResize | frame=\(NSStringFromRect(f)) isZoomed=\(win.isZoomed) inLiveResize=\(win.inLiveResize)")
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        applyScreenAwareMinSize()
        // Do not reposition the window here — it was snapping the window to the top when
        // the user dragged it, because we'd clamp and push the frame back into bounds.
    }

    @MainActor
    private func applyScreenAwareMinSize() {
        guard let win = window else { return }
        guard let screen = win.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let minW = min(880, max(520, visible.width * 0.32))
        let minH = min(560, max(360, visible.height * 0.36))
        let newMin = NSSize(width: minW, height: minH)
        if win.contentMinSize != newMin {
            win.contentMinSize = newMin
            AppLog.log("contentMinSize updated | screenVisible=\(NSStringFromRect(visible)) contentMin=\(NSStringFromSize(newMin))")
        }
    }
}

enum ExportProfile: String, CaseIterable, Identifiable {
    case h264 = "H.264 (MP4)"
    case hevc = "HEVC / H.265 (MOV)"
    case proRes = "Apple ProRes 422 (MOV)"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .h264:
            return "Best compatibility across devices and players."
        case .hevc:
            return "Smaller files at higher quality on modern Apple devices."
        case .proRes:
            return "Editing-grade quality with larger file sizes."
        }
    }

    var presetName: String {
        switch self {
        case .h264:
            return AVAssetExportPresetHighestQuality
        case .hevc:
            return AVAssetExportPresetHEVCHighestQuality
        case .proRes:
            return AVAssetExportPresetAppleProRes422LPCM
        }
    }

    var fileType: AVFileType {
        switch self {
        case .h264:
            return .mp4
        case .hevc, .proRes:
            return .mov
        }
    }

    var fileExtension: String {
        switch self {
        case .h264:
            return "mp4"
        case .hevc, .proRes:
            return "mov"
        }
    }

    var utType: UTType {
        switch self {
        case .h264:
            return .mpeg4Movie
        case .hevc, .proRes:
            return .quickTimeMovie
        }
    }
}

struct TimedScriptEntry {
    let index: Int
    let url: URL
    let text: String
    let start: CMTime
    let duration: CMTime

    var targetWordRange: ClosedRange<Int> {
        let seconds = max(CMTimeGetSeconds(duration), 0)
        let low = max(Int((seconds * 1.8).rounded(.down)), 1)
        let high = max(Int((seconds * 2.6).rounded(.up)), low)
        return low...high
    }
}

private enum SRTParser {
    struct Cue {
        let start: CMTime
        let duration: CMTime
        let text: String
    }

    static func parse(text: String) -> [Cue] {
        let cleaned = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = cleaned
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var cues: [Cue] = []
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
            if lines.isEmpty { continue }

            // Accept either:
            // 1) index line, timestamp line, text...
            // 2) timestamp line, text...
            let timestampLine: String
            let textLines: [String]
            if lines.count >= 2, lines[1].contains("-->") {
                timestampLine = lines[1]
                textLines = Array(lines.dropFirst(2))
            } else if lines[0].contains("-->") {
                timestampLine = lines[0]
                textLines = Array(lines.dropFirst(1))
            } else {
                continue
            }

            guard let (start, end) = parseTimestampLine(timestampLine) else { continue }
            let body = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { continue }

            let durationSeconds = max(CMTimeGetSeconds(end) - CMTimeGetSeconds(start), 0.05)
            cues.append(
                Cue(
                    start: start,
                    duration: CMTime(seconds: durationSeconds, preferredTimescale: 600),
                    text: body
                )
            )
        }

        return cues.sorted { CMTimeCompare($0.start, $1.start) < 0 }
    }

    private static func parseTimestampLine(_ line: String) -> (CMTime, CMTime)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }
        let left = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let right = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = parseTimestamp(left), let e = parseTimestamp(right) else { return nil }
        return (s, e)
    }

    private static func parseTimestamp(_ s: String) -> CMTime? {
        // Accept: HH:MM:SS,mmm or MM:SS,mmm
        let mainParts = s.split(separator: ",", omittingEmptySubsequences: false)
        guard mainParts.count >= 2 else { return nil }
        let timePart = String(mainParts[0])
        let msPart = String(mainParts[1])
        let ms = Double(msPart.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        let t = timePart.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) ?? 0 }
        if t.count == 3 {
            let seconds = t[0] * 3600 + t[1] * 60 + t[2] + (ms / 1000.0)
            return CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        }
        if t.count == 2 {
            let seconds = t[0] * 60 + t[1] + (ms / 1000.0)
            return CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        }
        return nil
    }
}

struct ClipSceneCaption: Hashable, Identifiable, Codable {
    let index: Int
    let startSeconds: Double
    let endSeconds: Double
    let caption: String

    var id: Int { index }

    var durationSeconds: Double {
        max(endSeconds - startSeconds, 0)
    }
}

struct ExportArtifacts {
    let timedEntries: [TimedScriptEntry]
    let totalDuration: CMTime
}

enum SubtitlePosition: String, CaseIterable, Identifiable {
    case lowerThird = "Lower Third"
    case bottomSafe = "Bottom Safe"
    case center = "Center"

    var id: String { rawValue }

    var verticalRatio: CGFloat {
        switch self {
        case .lowerThird:
            return 0.74
        case .bottomSafe:
            return 0.82
        case .center:
            return 0.56
        }
    }
}

enum SubtitleTimingMode: String, CaseIterable, Identifiable {
    case clipTimed = "Per Clip"
    case sceneTimed = "Scene Timed"

    var id: String { rawValue }
}

enum SubtitleTone: String, CaseIterable, Identifiable {
    case literal = "Literal"
    case humorTourGuide = "Humor Tour Guide"

    var id: String { rawValue }
}

enum DescriptionLanguage: String, CaseIterable, Identifiable {
    case english = "English"
    case traditionalChinese = "繁體中文"

    var id: String { rawValue }

    var analyzerArg: String {
        switch self {
        case .english: return "en"
        case .traditionalChinese: return "zh-Hant"
        }
    }
}

struct SubtitleStyle {
    let position: SubtitlePosition
    let fontScale: Double
    let backgroundOpacity: Double

    static let `default` = SubtitleStyle(
        position: .lowerThird,
        fontScale: 1.0,
        backgroundOpacity: 0.62
    )
}

private struct CachedClipAnalysis: Codable {
    let filePath: String
    let fileSize: Int
    let modificationTime: TimeInterval
    let lang: String
    let maxWords: Int
    let segmentSeconds: Double
    let description: String
    let engine: String
    let warnings: [String]
    let scenes: [ClipSceneCaption]
}

private enum ClipAnalysisCacheStore {
    private static func cacheDir() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("VideoCombiner/cache/v1", isDirectory: true)
    }

    private static func fileFingerprint(for url: URL) -> (size: Int, mtime: TimeInterval)? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values?.fileSize,
              let mtime = values?.contentModificationDate?.timeIntervalSince1970 else { return nil }
        return (size, mtime)
    }

    private static func key(for url: URL, size: Int, mtime: TimeInterval, lang: String, maxWords: Int, segmentSeconds: Double) -> String {
        let raw = "\(url.path)|\(size)|\(mtime)|\(lang)|\(maxWords)|\(segmentSeconds)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func load(url: URL, lang: String, maxWords: Int, segmentSeconds: Double) -> CachedClipAnalysis? {
        guard let dir = cacheDir(),
              let fp = fileFingerprint(for: url) else { return nil }
        let k = key(for: url, size: fp.size, mtime: fp.mtime, lang: lang, maxWords: maxWords, segmentSeconds: segmentSeconds)
        let path = dir.appendingPathComponent("\(k).json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(CachedClipAnalysis.self, from: data)
    }

    static func save(url: URL, lang: String, maxWords: Int, analysis: CachedClipAnalysis) {
        guard let dir = cacheDir() else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fp = fileFingerprint(for: url)
            let size = fp?.size ?? analysis.fileSize
            let mtime = fp?.mtime ?? analysis.modificationTime
            let k = key(for: url, size: size, mtime: mtime, lang: lang, maxWords: maxWords, segmentSeconds: analysis.segmentSeconds)
            let path = dir.appendingPathComponent("\(k).json")
            let data = try JSONEncoder().encode(analysis)
            try data.write(to: path, options: [.atomic])
        } catch {
            // Cache is a best-effort optimization; ignore write failures.
        }
    }

    static func remove(url: URL, lang: String, maxWords: Int, segmentSeconds: Double) {
        guard let dir = cacheDir(),
              let fp = fileFingerprint(for: url) else { return }
        let k = key(for: url, size: fp.size, mtime: fp.mtime, lang: lang, maxWords: maxWords, segmentSeconds: segmentSeconds)
        let path = dir.appendingPathComponent("\(k).json")
        try? FileManager.default.removeItem(at: path)
    }
}

@MainActor
final class VideoMergeViewModel: ObservableObject {
    @Published var selectedURLs: [URL] = []
    @Published var clipDescriptions: [URL: String] = [:]
    @Published var clipEngines: [URL: String] = [:]
    @Published var clipWarnings: [URL: [String]] = [:]
    @Published var clipScenes: [URL: [ClipSceneCaption]] = [:]
    @Published var clipKeyframes: [URL: [NSImage]] = [:]
    @Published var previewKeyframeCount: Int = 3
    @Published var descriptionEngine: ClipDescriptionBuilder.EngineId = .auto
    @Published var clipScripts: [URL: String] = [:]
    @Published var clipDurations: [URL: Double] = [:]
    @Published var selectedProfile: ExportProfile = .h264
    @Published var pythonInterpreterPath = ""
    @Published var descriptionLanguage: DescriptionLanguage = .english {
        didSet {
            UserDefaults.standard.set(descriptionLanguage.analyzerArg, forKey: descriptionLanguageDefaultsKey)
        }
    }
    @Published var descriptionMaxWords: Int = 140 {
        didSet {
            let clamped = min(max(descriptionMaxWords, 60), 300)
            if clamped != descriptionMaxWords {
                descriptionMaxWords = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: descriptionMaxWordsDefaultsKey)
        }
    }
    // Timestamped description granularity (also drives scene-timed subtitle segmentation).
    @Published var analysisSegmentSeconds: Double = 2.0 {
        didSet {
            let clamped = min(max(analysisSegmentSeconds, 1.0), 30.0)
            if clamped != analysisSegmentSeconds {
                analysisSegmentSeconds = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: analysisSegmentSecondsDefaultsKey)
        }
    }
    @Published var debugLog = ""
    @Published var debugLoggingEnabled = true
    @Published var burnInSubtitles = true
    @Published var exportSRT = true
    @Published var exportScriptDocument = true
    @Published var combinedDescriptionExported = false
    @Published var subtitleTimingMode: SubtitleTimingMode = .sceneTimed
    @Published var subtitleTone: SubtitleTone = .humorTourGuide {
        didSet {
            UserDefaults.standard.set(subtitleTone.rawValue, forKey: subtitleToneDefaultsKey)
        }
    }
    @Published var subtitlePosition: SubtitlePosition = .lowerThird
    @Published var subtitleFontScale = 1.0
    @Published var subtitleBackgroundOpacity = 0.62
    @Published var isExporting = false
    @Published var isGeneratingDescriptions = false
    @Published var isConfiguringGPULimit = false
    @Published var isRefreshingGPULimit = false
    @Published var isGeneratingClaudeSubtitle = false
    @Published var statusMessage = "Choose videos and export."
    @Published var statusDetail: String? = nil
    @Published var importedSubtitleEntries: [TimedScriptEntry] = []
    @Published var importedSRTPath: String? = nil
    @Published var claudeSubtitlePrompt = ""
    @Published var claudeSubtitleYAML = ""
    @Published var claudeSubtitleSourceLabel = "Current generated YAML"
    @Published var configuredGPUMemoryLimitMB: Int = 18000 {
        didSet {
            let upper = gpuMemoryLimitSystemUpperBoundMB
            let clamped = min(max(configuredGPUMemoryLimitMB, 1024), upper)
            if clamped != configuredGPUMemoryLimitMB {
                configuredGPUMemoryLimitMB = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: gpuMemoryLimitDefaultsKey)
        }
    }
    @Published var currentGPUMemoryLimitMB: Int? = nil
    @Published var currentGPUMemoryLimitDetail = "Current limit unavailable until refreshed."

    private var physicalMemoryMB: Int {
        max(1, Int(ProcessInfo.processInfo.physicalMemory / 1_048_576))
    }

    private var gpuMemoryLimitSystemUpperBoundMB: Int {
        let actual = currentGPUMemoryLimitMB ?? 0
        return max(actual, physicalMemoryMB)
    }

    var gpuMemoryLimitRangeMB: ClosedRange<Int> {
        let upper = max(gpuMemoryLimitSystemUpperBoundMB, configuredGPUMemoryLimitMB)
        return 1024...upper
    }

    private let pythonPathDefaultsKey = "vcat.pythonInterpreterPath"
    private let descriptionLanguageDefaultsKey = "vcat.descriptionLanguage"
    private let descriptionMaxWordsDefaultsKey = "vcat.descriptionMaxWords"
    private let analysisSegmentSecondsDefaultsKey = "vcat.analysisSegmentSeconds"
    private let subtitleToneDefaultsKey = "vcat.subtitleTone"
    private let gpuMemoryLimitDefaultsKey = "vcat.gpuMemoryLimitMB"
    private var keyframeInFlight: Set<URL> = []

    init() {
        defer {
            refreshCurrentGPUMemoryLimit()
        }

        if let storedLang = UserDefaults.standard.string(forKey: descriptionLanguageDefaultsKey) {
            if storedLang == "zh-Hant" {
                descriptionLanguage = .traditionalChinese
            } else if storedLang == "en" {
                descriptionLanguage = .english
            }
        }

        let storedMax = UserDefaults.standard.integer(forKey: descriptionMaxWordsDefaultsKey)
        if storedMax > 0 {
            descriptionMaxWords = min(max(storedMax, 60), 300)
        }

        let storedSegment = UserDefaults.standard.double(forKey: analysisSegmentSecondsDefaultsKey)
        if storedSegment > 0 {
            analysisSegmentSeconds = min(max(storedSegment, 1.0), 30.0)
        }

        if let storedTone = UserDefaults.standard.string(forKey: subtitleToneDefaultsKey),
           let tone = SubtitleTone(rawValue: storedTone) {
            subtitleTone = tone
        }

        AppLog.sink = { [weak self] line in
            self?.appendLog(line)
        }

        if let storedLimit = UserDefaults.standard.object(forKey: gpuMemoryLimitDefaultsKey) as? Int,
           storedLimit > 0 {
            configuredGPUMemoryLimitMB = storedLimit
        }

        // Priority: user setting -> env var -> repo-local .venv -> system python.
        if let stored = UserDefaults.standard.string(forKey: pythonPathDefaultsKey),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pythonInterpreterPath = stored
            logStartup()
            return
        }

        if let env = ProcessInfo.processInfo.environment["VCAT_PYTHON"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pythonInterpreterPath = env
            logStartup()
            return
        }

        if let discovered = discoverVenvPythonNearApp() {
            pythonInterpreterPath = discovered
            logStartup()
            return
        }

        let repoVenvPython = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".venv/bin/python")
        if FileManager.default.isExecutableFile(atPath: repoVenvPython.path) {
            pythonInterpreterPath = repoVenvPython.path
            logStartup()
            return
        }

        pythonInterpreterPath = "python3"
        logStartup()
    }

    var totalDurationText: String {
        ClipDescriptionBuilder.formatDuration(totalDurationSeconds)
    }

    var totalDurationSeconds: Double {
        selectedURLs.reduce(0) { $0 + (clipDurations[$1] ?? 0) }
    }

    var recommendedNarrationRangeText: String {
        let low = max(Int((totalDurationSeconds * 1.8).rounded(.down)), 0)
        let high = max(Int((totalDurationSeconds * 2.6).rounded(.up)), low)
        return "\(low)-\(high) words"
    }

    func addVideos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK {
            selectedURLs.append(contentsOf: panel.urls)
            sortSelectedURLs()
            statusMessage = "Added \(panel.urls.count) video(s)."
            loadDurations(for: panel.urls)
            preloadCachedAnalyses(for: panel.urls)
        }
    }

    private func sortSelectedURLs() {
        selectedURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func removeSelected(at offsets: IndexSet) {
        for index in offsets {
            guard selectedURLs.indices.contains(index) else { continue }
            let url = selectedURLs[index]
            clipDescriptions[url] = nil
            clipScripts[url] = nil
            clipDurations[url] = nil
            clipEngines[url] = nil
            clipWarnings[url] = nil
            clipScenes[url] = nil
            clipKeyframes[url] = nil
        }
        selectedURLs.remove(atOffsets: offsets)
    }

    func removeClip(at index: Int) {
        guard selectedURLs.indices.contains(index) else { return }
        let url = selectedURLs[index]
        clipDescriptions[url] = nil
        clipScripts[url] = nil
        clipDurations[url] = nil
        clipEngines[url] = nil
        clipWarnings[url] = nil
        clipScenes[url] = nil
        clipKeyframes[url] = nil
        selectedURLs.remove(at: index)
    }

    func moveUp(index: Int) {
        guard index > 0, index < selectedURLs.count else { return }
        selectedURLs.swapAt(index, index - 1)
    }

    func moveDown(index: Int) {
        guard index >= 0, index < selectedURLs.count - 1 else { return }
        selectedURLs.swapAt(index, index + 1)
    }

    func clearAll() {
        selectedURLs.removeAll()
        clipDescriptions.removeAll()
        clipEngines.removeAll()
        clipWarnings.removeAll()
        clipScenes.removeAll()
        clipKeyframes.removeAll()
        clipScripts.removeAll()
        clipDurations.removeAll()
    }

    func generateDescriptionsForAll(forceRefresh: Bool = false) {
        guard !selectedURLs.isEmpty else {
            statusMessage = "No videos selected."
            return
        }
        guard !isGeneratingDescriptions else { return }

        isGeneratingDescriptions = true
        statusMessage = forceRefresh ? "Regenerating clip descriptions..." : "Generating clip descriptions..."
        statusDetail = "Running local analyzer. If a macOS admin dialog appeared, approve it to continue."
        let urls = selectedURLs
        if forceRefresh {
            invalidateCachedAnalyses(for: urls)
        }

        Task<Void, Never> {
            let results = await ClipDescriptionBuilder.describeAll(
                urls: urls,
                pythonExec: resolvedPythonExec(),
                maxWords: descriptionMaxWords,
                language: descriptionLanguage,
                segmentSeconds: analysisSegmentSeconds,
                engine: descriptionEngine
            )
            await MainActor.run {
                for (url, outcome) in results {
                    switch outcome {
                    case .success(let result):
                        if self.debugLoggingEnabled {
                            for line in result.debugLines {
                                self.appendLog(line)
                            }
                        }
                        self.updateAnalysisState(
                            for: url,
                            description: result.description,
                            engine: result.engine,
                            warnings: result.warnings,
                            scenes: result.scenes
                        )
                        self.persistAnalysisToCache(url: url, result: result)
                        if self.clipScripts[url, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.clipScripts[url] = DraftScriptBuilder.draft(from: result.description, fallbackFilename: url.deletingPathExtension().lastPathComponent)
                        }
                    case .failure(let error):
                        self.updateAnalysisState(
                            for: url,
                            description: "Unable to describe this clip automatically.",
                            engine: nil,
                            warnings: ["\(error.localizedDescription)"],
                            scenes: []
                        )
                        if self.debugLoggingEnabled {
                            self.appendLog("Describe failed: \(url.path) error=\(error.localizedDescription)")
                        }
                    }
                }
                self.isGeneratingDescriptions = false
                self.statusDetail = nil
                self.statusMessage = forceRefresh
                    ? "Descriptions regenerated for \(urls.count) clip(s)."
                    : "Descriptions generated for \(urls.count) clip(s)."
            }
        }
    }

    func regenerateDescriptionsForAll() {
        generateDescriptionsForAll(forceRefresh: true)
    }

    func generateDescription(for url: URL) {
        guard !isGeneratingDescriptions else { return }

        isGeneratingDescriptions = true
        statusMessage = "Generating description for \(url.lastPathComponent)..."
        statusDetail = "Running local analyzer. If a macOS admin dialog appeared, approve it to continue."

        Task<Void, Never> {
            do {
                let result = try await ClipDescriptionBuilder.describe(
                    url: url,
                    pythonExec: resolvedPythonExec(),
                    maxWords: descriptionMaxWords,
                    language: descriptionLanguage,
                    segmentSeconds: analysisSegmentSeconds,
                    engine: descriptionEngine
                )
                await MainActor.run {
                    if self.debugLoggingEnabled {
                        for line in result.debugLines {
                            self.appendLog(line)
                        }
                    }
                    self.updateAnalysisState(
                        for: url,
                        description: result.description,
                        engine: result.engine,
                        warnings: result.warnings,
                        scenes: result.scenes
                    )
                    self.persistAnalysisToCache(url: url, result: result)
                    if self.clipScripts[url, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.clipScripts[url] = DraftScriptBuilder.draft(from: result.description, fallbackFilename: url.deletingPathExtension().lastPathComponent)
                    }
                    self.isGeneratingDescriptions = false
                    self.statusDetail = nil
                    self.statusMessage = "Description generated for \(url.lastPathComponent)."
                }
            } catch {
                await MainActor.run {
                    self.updateAnalysisState(
                        for: url,
                        description: "Unable to describe this clip automatically.",
                        engine: nil,
                        warnings: ["\(error.localizedDescription)"],
                        scenes: []
                    )
                    if self.debugLoggingEnabled {
                        self.appendLog("Describe failed: \(url.path) error=\(error.localizedDescription)")
                    }
                    self.isGeneratingDescriptions = false
                    self.statusDetail = nil
                    self.statusMessage = "Description failed for \(url.lastPathComponent)."
                }
            }
        }
    }

    private func persistAnalysisToCache(url: URL, result: ClipDescriptionBuilder.DescribeResult) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let cached = CachedClipAnalysis(
            filePath: url.path,
            fileSize: size,
            modificationTime: mtime,
            lang: descriptionLanguage.analyzerArg,
            maxWords: descriptionMaxWords,
            segmentSeconds: analysisSegmentSeconds,
            description: result.description,
            engine: result.engine,
            warnings: result.warnings,
            scenes: result.scenes
        )
        ClipAnalysisCacheStore.save(url: url, lang: descriptionLanguage.analyzerArg, maxWords: descriptionMaxWords, analysis: cached)
        if debugLoggingEnabled {
            appendLog("Cache saved: \(url.lastPathComponent) (\(cached.lang), \(cached.maxWords)w, \(cached.segmentSeconds)s)")
        }
    }

    private func updateAnalysisState(
        for url: URL,
        description: String?,
        engine: String?,
        warnings: [String]?,
        scenes: [ClipSceneCaption]?
    ) {
        var descriptions = clipDescriptions
        descriptions[url] = description
        clipDescriptions = descriptions

        var engines = clipEngines
        engines[url] = engine
        clipEngines = engines

        var warningMap = clipWarnings
        warningMap[url] = warnings
        clipWarnings = warningMap

        var sceneMap = clipScenes
        sceneMap[url] = scenes
        clipScenes = sceneMap
    }

    private func invalidateCachedAnalyses(for urls: [URL]) {
        let lang = descriptionLanguage.analyzerArg
        let maxWords = descriptionMaxWords
        let segment = analysisSegmentSeconds
        for url in urls {
            ClipAnalysisCacheStore.remove(url: url, lang: lang, maxWords: maxWords, segmentSeconds: segment)
            updateAnalysisState(for: url, description: nil, engine: nil, warnings: nil, scenes: nil)
            if debugLoggingEnabled {
                appendLog("Cache cleared: \(url.lastPathComponent) (\(lang), \(maxWords)w, \(segment)s)")
            }
        }
    }

    private func preloadCachedAnalyses(for urls: [URL]) {
        let lang = descriptionLanguage.analyzerArg
        let maxWords = descriptionMaxWords
        let segment = analysisSegmentSeconds
        for url in urls {
            guard clipDescriptions[url] == nil else { continue }
            guard let cached = ClipAnalysisCacheStore.load(url: url, lang: lang, maxWords: maxWords, segmentSeconds: segment) else { continue }
            updateAnalysisState(
                for: url,
                description: cached.description,
                engine: cached.engine,
                warnings: cached.warnings,
                scenes: cached.scenes
            )
            if debugLoggingEnabled {
                appendLog("Cache hit: \(url.lastPathComponent) (\(cached.lang), \(cached.maxWords)w, \(cached.segmentSeconds)s)")
            }
        }
    }

    func generateDraftScriptsForAll() {
        guard !selectedURLs.isEmpty else {
            statusMessage = "No videos selected."
            return
        }

        // Always seed clip-level voiceover lines (used for narration planning + optional clip-timed SRT).
        for url in selectedURLs {
            let source = clipDescriptions[url] ?? ""
            if clipScripts[url, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clipScripts[url] = DraftScriptBuilder.draft(from: source, fallbackFilename: url.deletingPathExtension().lastPathComponent)
            }
        }

        if subtitleTimingMode == .sceneTimed {
            let sceneCueCount = selectedURLs.reduce(0) { partial, url in
                partial + (clipScenes[url]?.filter { !$0.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count ?? 0)
            }
            if sceneCueCount > 0 {
                statusMessage = "Scene-timed subtitles ready (\(sceneCueCount) cue(s))."
            } else {
                statusMessage = "No scene captions yet. Generate descriptions first to produce scene-timed subtitles."
            }
            return
        }

        let missing = selectedURLs.filter { clipDescriptions[$0] == nil }
        if missing.isEmpty {
            statusMessage = "Draft subtitles updated from existing descriptions."
        } else {
            statusMessage = "Draft subtitles updated. Generate descriptions for stronger results."
        }
    }

    func exportMergedVideo() {
        guard !selectedURLs.isEmpty else {
            statusMessage = "No videos selected."
            return
        }

        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "combined.\(selectedProfile.fileExtension)"
        savePanel.allowedContentTypes = [selectedProfile.utType]

        guard savePanel.runModal() == .OK, let destination = savePanel.url else {
            statusMessage = "Export canceled."
            return
        }

        isExporting = true
        statusMessage = "Exporting..."

        let timedEntries = activeSubtitleEntries()
        let subtitleEntries = timedEntries.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        Task {
            do {
                try await VideoCombiner.merge(
                    inputURLs: selectedURLs,
                    outputURL: destination,
                    profile: selectedProfile,
                    subtitles: burnInSubtitles ? subtitleEntries : [],
                    subtitleStyle: currentSubtitleStyle
                )

                let artifacts = ExportArtifacts(timedEntries: timedEntries, totalDuration: totalDurationCMTime())
                try exportSidecars(for: destination, artifacts: artifacts)

                await MainActor.run {
                    self.isExporting = false
                    self.statusMessage = "Export completed: \(destination.lastPathComponent)"
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.statusMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func exportProxyVideoForAI() {
        guard !selectedURLs.isEmpty else {
            statusMessage = "No videos selected."
            return
        }

        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "combined_proxy.mp4"
        savePanel.allowedContentTypes = [.mpeg4Movie]

        guard savePanel.runModal() == .OK, let destination = savePanel.url else {
            statusMessage = "Export canceled."
            return
        }

        isExporting = true
        statusMessage = "Exporting proxy..."

        Task {
            do {
                // Proxy is for upload to subtitle tools: low bitrate + low FPS, but keep geometry unchanged.
                try await VideoCombiner.exportProxyViaExportSession(
                    inputURLs: selectedURLs,
                    outputURL: destination,
                    targetFPS: 5,
                    targetTotalBitrate: 250_000
                )
                await MainActor.run {
                    self.isExporting = false
                    self.statusMessage = "Proxy export completed: \(destination.lastPathComponent)"
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.statusMessage = "Proxy export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func activeSubtitleEntries() -> [TimedScriptEntry] {
        if !importedSubtitleEntries.isEmpty {
            return importedSubtitleEntries.sorted { CMTimeCompare($0.start, $1.start) < 0 }
        }
        let clipTimedEntries = buildTimedEntries()
        return subtitleTimingMode == .sceneTimed ? buildSceneTimedEntries() : clipTimedEntries
    }

    // Export an SRT containing timestamped clip descriptions (scene captions). Intended for copy/paste into an external model.
    func exportDescriptionSRT() {
        guard !selectedURLs.isEmpty else {
            statusMessage = "No videos selected."
            return
        }

        statusMessage = "Building description SRT..."
        Task {
            let entries = await buildDescriptionSRTEntries()
            await MainActor.run {
                guard !entries.isEmpty else {
                    self.statusMessage = "No timestamped descriptions yet. Generate descriptions first."
                    return
                }
                let srt = SubtitleSidecarWriter.makeSRT(entries: entries)
                guard !srt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.statusMessage = "No usable cues found (empty captions or invalid timings)."
                    return
                }

                let savePanel = NSSavePanel()
                savePanel.canCreateDirectories = true
                savePanel.nameFieldStringValue = "timestamped_descriptions.srt"
                savePanel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .text]

                guard savePanel.runModal() == .OK, let destination = savePanel.url else {
                    self.statusMessage = "Export canceled."
                    return
                }
                do {
                    try srt.write(to: destination, atomically: true, encoding: .utf8)
                    self.statusMessage = "Exported description SRT: \(destination.lastPathComponent)"
                } catch {
                    self.statusMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func exportCombinedDescription() {
        guard !selectedURLs.isEmpty else {
            statusMessage = "No videos selected."
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "combined_descriptions.yaml"
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .text]

        guard panel.runModal() == .OK, let destination = panel.url else {
            statusMessage = "Export canceled."
            return
        }

        let yaml = RawDescriptionSidecarWriter.makeYAML(
            urls: selectedURLs,
            clipDescriptions: clipDescriptions,
            clipScenes: clipScenes,
            clipDurations: clipDurations,
            clipEngines: clipEngines,
            clipWarnings: clipWarnings
        )
        do {
            try yaml.write(to: destination, atomically: true, encoding: .utf8)
            statusMessage = "Combined description exported: \(destination.lastPathComponent)"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func copyDescriptionSRTToClipboard() {
        statusMessage = "Building description SRT..."
        Task {
            let entries = await buildDescriptionSRTEntries()
            await MainActor.run {
                guard !entries.isEmpty else {
                    self.statusMessage = "No timestamped descriptions yet. Generate descriptions first."
                    return
                }
                let srt = SubtitleSidecarWriter.makeSRT(entries: entries)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(srt, forType: .string)
                self.statusMessage = "Copied timestamped description SRT."
            }
        }
    }

    func copyTimestampedDescriptionTextToClipboard() {
        statusMessage = "Building timestamped descriptions..."
        Task {
            let entries = await buildDescriptionSRTEntries()
            await MainActor.run {
                guard !entries.isEmpty else {
                    self.statusMessage = "No timestamped descriptions yet. Generate descriptions first."
                    return
                }
                let text = Self.makeTimestampedDescriptionText(entries: entries)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.statusMessage = "Copied timestamped descriptions."
            }
        }
    }

    private static func makeTimestampedDescriptionText(entries: [TimedScriptEntry]) -> String {
        let spoken = entries.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && CMTimeCompare($0.duration, .zero) > 0 }
        func srtTimestamp(_ time: CMTime) -> String {
            let totalMilliseconds = max(Int((CMTimeGetSeconds(time) * 1000).rounded()), 0)
            let hours = totalMilliseconds / 3_600_000
            let minutes = (totalMilliseconds % 3_600_000) / 60_000
            let seconds = (totalMilliseconds % 60_000) / 1000
            let milliseconds = totalMilliseconds % 1000
            return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
        }

        return spoken.map { entry in
            let start = srtTimestamp(entry.start)
            let end = srtTimestamp(entry.start + entry.duration)
            return "\(start) --> \(end)\n\(entry.text)"
        }.joined(separator: "\n\n")
    }

    private func ensuredClipDurationSeconds(for url: URL) async -> Double {
        if let existing = clipDurations[url], existing > 0 { return existing }
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)) ?? .zero
        let raw = CMTimeGetSeconds(duration)
        let seconds = (raw.isFinite && !raw.isNaN) ? max(raw, 0) : 0
        await MainActor.run {
            self.clipDurations[url] = seconds
        }
        return seconds
    }

    private func buildDescriptionSRTEntries() async -> [TimedScriptEntry] {
        var currentOffsetSeconds: Double = 0
        var out: [TimedScriptEntry] = []
        var cueIndex = 1

        for url in selectedURLs {
            let loadedDuration = await ensuredClipDurationSeconds(for: url)
            let sceneDuration = (clipScenes[url] ?? []).map(\.endSeconds).max() ?? 0
            let clipDurationSeconds = max(loadedDuration.isFinite ? loadedDuration : 0, sceneDuration.isFinite ? sceneDuration : 0)
            let scenes = (clipScenes[url] ?? []).sorted { $0.startSeconds < $1.startSeconds }

            if scenes.isEmpty {
                let text = (clipDescriptions[url] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    out.append(
                        TimedScriptEntry(
                            index: cueIndex,
                            url: url,
                            text: text,
                            start: CMTime(seconds: currentOffsetSeconds, preferredTimescale: 600),
                            duration: CMTime(seconds: clipDurationSeconds, preferredTimescale: 600)
                        )
                    )
                    cueIndex += 1
                }
                currentOffsetSeconds += clipDurationSeconds
                continue
            }

            var emitted = false
            for scene in scenes {
                let raw = scene.caption.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { continue }
                let startSec = currentOffsetSeconds + max(scene.startSeconds, 0)
                let endSec = currentOffsetSeconds + min(max(scene.endSeconds, scene.startSeconds), clipDurationSeconds)
                let durSec = max(endSec - startSec, 0.1)
                guard startSec.isFinite, endSec.isFinite, durSec.isFinite else { continue }
                out.append(
                    TimedScriptEntry(
                        index: cueIndex,
                        url: url,
                        text: raw,
                        start: CMTime(seconds: startSec, preferredTimescale: 600),
                        duration: CMTime(seconds: durSec, preferredTimescale: 600)
                    )
                )
                cueIndex += 1
                emitted = true
            }

            if !emitted {
                let text = (clipDescriptions[url] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    out.append(
                        TimedScriptEntry(
                            index: cueIndex,
                            url: url,
                            text: text,
                            start: CMTime(seconds: currentOffsetSeconds, preferredTimescale: 600),
                            duration: CMTime(seconds: clipDurationSeconds, preferredTimescale: 600)
                        )
                    )
                    cueIndex += 1
                }
            }

            currentOffsetSeconds += clipDurationSeconds
        }
        return out
    }

    func importSRT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Import SRT"

        guard panel.runModal() == .OK, let url = panel.url else {
            statusMessage = "Import canceled."
            return
        }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let cues = SRTParser.parse(text: text)
            if cues.isEmpty {
                statusMessage = "No cues found in SRT."
                return
            }

            let dummyURL = URL(fileURLWithPath: url.path)
            importedSubtitleEntries = cues.enumerated().map { idx, cue in
                TimedScriptEntry(
                    index: idx + 1,
                    url: dummyURL,
                    text: cue.text,
                    start: cue.start,
                    duration: cue.duration
                )
            }
            importedSRTPath = url.path
            statusMessage = "Imported SRT (\(cues.count) cue(s)). Export/Preview will use it."
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    func prepareClaudeSubtitleComposer() {
        do {
            claudeSubtitlePrompt = try Self.loadFinalSubtitlePrompt()
            claudeSubtitleYAML = currentGeneratedYAML()
            claudeSubtitleSourceLabel = "Current generated YAML"
            if debugLoggingEnabled {
                appendLog("Claude | composer ready | source=\(claudeSubtitleSourceLabel) promptChars=\(claudeSubtitlePrompt.count) yamlChars=\(claudeSubtitleYAML.count)")
            }
            statusMessage = "Claude subtitle composer ready."
        } catch {
            if debugLoggingEnabled {
                appendLog("Claude | composer failed | error=\(error.localizedDescription)")
            }
            statusMessage = "Claude prompt load failed: \(error.localizedDescription)"
        }
    }

    func chooseClaudeSubtitleYAML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "yaml") ?? .text,
            UTType(filenameExtension: "yml") ?? .text,
            .text
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose YAML for Claude Subtitle Generation"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            claudeSubtitleYAML = try String(contentsOf: url, encoding: .utf8)
            claudeSubtitleSourceLabel = url.lastPathComponent
            if debugLoggingEnabled {
                appendLog("Claude | yaml loaded | source=\(claudeSubtitleSourceLabel) chars=\(claudeSubtitleYAML.count)")
            }
            statusMessage = "Loaded YAML: \(url.lastPathComponent)"
        } catch {
            if debugLoggingEnabled {
                appendLog("Claude | yaml load failed | path=\(url.path) error=\(error.localizedDescription)")
            }
            statusMessage = "YAML load failed: \(error.localizedDescription)"
        }
    }

    func resetClaudeSubtitleYAMLToCurrent() {
        claudeSubtitleYAML = currentGeneratedYAML()
        claudeSubtitleSourceLabel = "Current generated YAML"
        if debugLoggingEnabled {
            appendLog("Claude | yaml reset | source=\(claudeSubtitleSourceLabel) chars=\(claudeSubtitleYAML.count)")
        }
        statusMessage = "Reset Claude YAML to current generated content."
    }

    func generateClaudeSubtitleAndImport() {
        let prompt = claudeSubtitlePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let yaml = claudeSubtitleYAML.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !prompt.isEmpty else {
            statusMessage = "Claude prompt is empty."
            return
        }
        guard !yaml.isEmpty else {
            statusMessage = "Claude YAML input is empty."
            return
        }
        guard !isGeneratingClaudeSubtitle else { return }

        isGeneratingClaudeSubtitle = true
        statusMessage = "Generating subtitles with Claude..."
        statusDetail = "Sending prompt and YAML to Claude."
        if debugLoggingEnabled {
            appendLog("Claude | request start | source=\(claudeSubtitleSourceLabel) promptChars=\(prompt.count) yamlChars=\(yaml.count)")
        }

        Task {
            do {
                let srt = try await ClaudeSubtitleClient.generateSRT(prompt: prompt, yaml: yaml)
                let importedURL = try self.importGeneratedSRT(srt, sourceLabel: claudeSubtitleSourceLabel)
                await MainActor.run {
                    self.importedSRTPath = importedURL.path
                    if self.debugLoggingEnabled {
                        self.appendLog("Claude | import success | path=\(importedURL.path) srtChars=\(srt.count) cues=\(self.importedSubtitleEntries.count)")
                    }
                    self.isGeneratingClaudeSubtitle = false
                    self.statusDetail = nil
                    self.statusMessage = "Claude subtitles imported: \(importedURL.lastPathComponent)"
                }
            } catch {
                await MainActor.run {
                    if self.debugLoggingEnabled {
                        self.appendLog("Claude | request failed | error=\(error.localizedDescription)")
                    }
                    self.isGeneratingClaudeSubtitle = false
                    self.statusDetail = nil
                    self.statusMessage = "Claude subtitle generation failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func clearImportedSRT() {
        importedSubtitleEntries = []
        importedSRTPath = nil
        statusMessage = "Imported SRT cleared."
    }

    private func loadDurations(for urls: [URL]) {
        Task.detached(priority: .utility) {
            for url in urls {
                let asset = AVURLAsset(url: url)
                let duration = try? await asset.load(.duration)
                let raw = duration.map { CMTimeGetSeconds($0) } ?? 0
                let seconds = (raw.isFinite && !raw.isNaN) ? max(raw, 0) : 0
                await MainActor.run {
                    self.clipDurations[url] = seconds
                }
            }
        }
    }

    private func currentGeneratedYAML() -> String {
        RawDescriptionSidecarWriter.makeYAML(
            urls: selectedURLs,
            clipDescriptions: clipDescriptions,
            clipScenes: clipScenes,
            clipDurations: clipDurations,
            clipEngines: clipEngines,
            clipWarnings: clipWarnings
        )
    }

    @MainActor
    private func importGeneratedSRT(_ text: String, sourceLabel: String) throws -> URL {
        let cues = SRTParser.parse(text: text)
        guard !cues.isEmpty else {
            throw VideoMergeError.exportFailed("Claude returned invalid or empty SRT.")
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("vcat-generated-srt", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let sanitized = sourceLabel
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        let fileURL = tempDir.appendingPathComponent("claude_\(sanitized)_\(Self.timestampStamp()).srt")
        try text.write(to: fileURL, atomically: true, encoding: .utf8)

        importedSubtitleEntries = cues.enumerated().map { idx, cue in
            TimedScriptEntry(
                index: idx + 1,
                url: fileURL,
                text: cue.text,
                start: cue.start,
                duration: cue.duration
            )
        }
        return fileURL
    }

    private static func timestampStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private static func loadFinalSubtitlePrompt() throws -> String {
        guard let url = resolveFinalSubtitlePromptURL() else {
            throw VideoMergeError.exportFailed("Could not find prompts/final_subtitle.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func resolveFinalSubtitlePromptURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "final_subtitle", withExtension: nil) {
            return bundled
        }

        let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("prompts/final_subtitle")
        if FileManager.default.fileExists(atPath: cwdURL.path) {
            return cwdURL
        }

        if let scriptURL = ClipDescriptionBuilder.analyzerScriptURL() {
            let candidate = scriptURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("prompts/final_subtitle")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    func ensureKeyframes(for url: URL) {
        if clipKeyframes[url] != nil { return }
        if keyframeInFlight.contains(url) { return }
        keyframeInFlight.insert(url)
        AppLog.log("Keyframes | queued | url=\(url.lastPathComponent)")

        let count = min(max(previewKeyframeCount, 1), 8)
        let startedAt = Date()
        AppLog.log("Keyframes | start ensure | url=\(url.lastPathComponent) count=\(count)")
        Task.detached(priority: .utility) {
            let images = await Self.generateKeyframes(url: url, count: count, startedAt: startedAt)
            await MainActor.run {
                self.clipKeyframes[url] = images
                self.keyframeInFlight.remove(url)
                AppLog.log("Keyframes | completed ensure | url=\(url.lastPathComponent) generated=\(images.count)")
            }
        }
    }

    func invalidateKeyframes() {
        clipKeyframes.removeAll()
        keyframeInFlight.removeAll()
    }

    private static func generateKeyframes(url: URL, count: Int, startedAt: Date) async -> [NSImage] {
        AppLog.log("Keyframes | generate begin | url=\(url.lastPathComponent) requestedCount=\(count)")
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)) ?? .zero
        let seconds = max(CMTimeGetSeconds(duration), 0)
        guard seconds > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Thumbnails are small in the timeline; clamp to a modest size so decoding and layout
        // stay cheap even when many clips appear at once.
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let samples = max(1, min(count, 8))
        let percents: [Double] = samples == 1 ? [0.5] : (0..<samples).map { i in
            // Spread a bit away from edges to avoid black frames.
            let t = Double(i + 1) / Double(samples + 1)
            return min(max(t, 0.12), 0.88)
        }

        var result: [NSImage] = []
        for p in percents {
            let time = CMTime(seconds: seconds * p, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
            let size = NSSize(width: cgImage.width, height: cgImage.height)
            result.append(NSImage(cgImage: cgImage, size: size))
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        AppLog.log("Keyframes | generate end | url=\(url.lastPathComponent) frames=\(result.count) elapsedMs=\(Int(elapsed * 1000))")
        return result
    }

    private func totalDurationCMTime() -> CMTime {
        selectedURLs.reduce(.zero) { partial, url in
            partial + CMTime(seconds: clipDurations[url] ?? 0, preferredTimescale: 600)
        }
    }

    func durationText(for url: URL) -> String {
        let seconds = clipDurations[url] ?? 0
        return ClipDescriptionBuilder.formatDuration(seconds)
    }

    func timestampedDescription(for url: URL) -> String? {
        let scenes = clipScenes[url] ?? []
        let lines = scenes
            .sorted { $0.startSeconds < $1.startSeconds }
            .compactMap { scene -> String? in
                let text = scene.caption.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let start = ClipDescriptionBuilder.formatDuration(max(scene.startSeconds, 0))
                let end = ClipDescriptionBuilder.formatDuration(max(scene.endSeconds, scene.startSeconds))
                let normalized = text
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                let body = normalized
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "  " + String($0) }
                    .joined(separator: "\n")
                return "[\(start) - \(end)]\n\(body)"
            }
        if lines.isEmpty { return nil }
        return lines.joined(separator: "\n\n")
    }

    func formattedDescription(for url: URL) -> String? {
        guard let raw = clipDescriptions[url]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        var text = raw
            .replacingOccurrences(of: " Highlights: ", with: "\n\nHighlights:\n")
            .replacingOccurrences(of: "; ", with: "\n• ")
            .replacingOccurrences(of: "setting ", with: "setting: ")
            .replacingOccurrences(of: "people ", with: "people: ")
            .replacingOccurrences(of: "action ", with: "action: ")
            .replacingOccurrences(of: "motion ", with: "motion: ")
            .replacingOccurrences(of: "intent ", with: "intent: ")
            .replacingOccurrences(of: "mood ", with: "mood: ")
            .replacingOccurrences(of: "objects ", with: "objects: ")
            .replacingOccurrences(of: "text_in_frame ", with: "text_in_frame: ")
            .replacingOccurrences(of: "camera ", with: "camera: ")
            .replacingOccurrences(of: "lighting ", with: "lighting: ")
            .replacingOccurrences(of: "sound_context ", with: "sound_context: ")

        if text.contains("\n• ") {
            text = text.replacingOccurrences(of: "\n\nHighlights:\n", with: "\n\nHighlights:\n• ")
        }

        return text
    }

    func targetWordsText(for url: URL) -> String {
        let seconds = clipDurations[url] ?? 0
        let low = max(Int((seconds * 1.8).rounded(.down)), 1)
        let high = max(Int((seconds * 2.6).rounded(.up)), low)
        return "\(low)-\(high) words"
    }

    private func stylizeSubtitle(_ text: String) -> String {
        let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "" }
        switch subtitleTone {
        case .literal:
            return base
        case .humorTourGuide:
            if descriptionLanguage == .traditionalChinese {
                let openers = [
                    "各位旅客看這邊：",
                    "下一站：",
                    "左手邊請注意：",
                    "導遊小提醒：",
                ]
                let opener = openers[abs(base.hashValue) % openers.count]
                return "\(opener)\(base)"
            } else {
                let openers = [
                    "Folks, on your left:",
                    "Next stop:",
                    "Tour guide note:",
                    "Quick highlight:",
                ]
                let opener = openers[abs(base.hashValue) % openers.count]
                return "\(opener) \(base)"
            }
        }
    }

    private func buildTimedEntries() -> [TimedScriptEntry] {
        var current = CMTime.zero
        return selectedURLs.enumerated().map { index, url in
            let duration = CMTime(seconds: clipDurations[url] ?? 0, preferredTimescale: 600)
            let text = stylizeSubtitle(clipScripts[url]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            let entry = TimedScriptEntry(index: index + 1, url: url, text: text, start: current, duration: duration)
            current = current + duration
            return entry
        }
    }

    private func buildSceneTimedEntries() -> [TimedScriptEntry] {
        var currentOffsetSeconds: Double = 0
        var out: [TimedScriptEntry] = []
        var cueIndex = 1

        for (clipIndex, url) in selectedURLs.enumerated() {
            let clipDurationSeconds = clipDurations[url] ?? 0
            let scenes = clipScenes[url] ?? []

            if scenes.isEmpty {
                // Fallback: one cue for the whole clip.
                let text = stylizeSubtitle((clipScripts[url] ?? clipDescriptions[url] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                let start = CMTime(seconds: currentOffsetSeconds, preferredTimescale: 600)
                let dur = CMTime(seconds: clipDurationSeconds, preferredTimescale: 600)
                out.append(TimedScriptEntry(index: cueIndex, url: url, text: text, start: start, duration: dur))
                cueIndex += 1
                currentOffsetSeconds += clipDurationSeconds
                continue
            }

            var emittedAnyForClip = false
            for scene in scenes {
                let sceneText = stylizeSubtitle(scene.caption.trimmingCharacters(in: .whitespacesAndNewlines))
                guard !sceneText.isEmpty else { continue }
                let startSec = currentOffsetSeconds + max(scene.startSeconds, 0)
                let endSec = currentOffsetSeconds + min(max(scene.endSeconds, scene.startSeconds), clipDurationSeconds)
                let durSec = max(endSec - startSec, 0.1)

                out.append(
                    TimedScriptEntry(
                        index: cueIndex,
                        url: url,
                        text: sceneText,
                        start: CMTime(seconds: startSec, preferredTimescale: 600),
                        duration: CMTime(seconds: durSec, preferredTimescale: 600)
                    )
                )
                cueIndex += 1
                emittedAnyForClip = true
            }

            if !emittedAnyForClip {
                let text = stylizeSubtitle((clipScripts[url] ?? clipDescriptions[url] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                out.append(
                    TimedScriptEntry(
                        index: cueIndex,
                        url: url,
                        text: text,
                        start: CMTime(seconds: currentOffsetSeconds, preferredTimescale: 600),
                        duration: CMTime(seconds: clipDurationSeconds, preferredTimescale: 600)
                    )
                )
                cueIndex += 1
            }

            // Always advance by the clip duration so downstream clips land correctly.
            currentOffsetSeconds += clipDurationSeconds

            // Keep clip-level scripts seeded for narration planning if empty.
            if clipScripts[url, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let fallback = clipDescriptions[url] ?? "Clip \(clipIndex + 1)"
                clipScripts[url] = DraftScriptBuilder.draft(from: fallback, fallbackFilename: url.deletingPathExtension().lastPathComponent)
            }
        }

        return out
    }

    private func exportSidecars(for destination: URL, artifacts: ExportArtifacts) throws {
        let baseURL = destination.deletingPathExtension()

        if exportSRT {
            let srt = SubtitleSidecarWriter.makeSRT(entries: artifacts.timedEntries)
            try srt.write(to: baseURL.appendingPathExtension("srt"), atomically: true, encoding: .utf8)
        }

        if exportScriptDocument {
            // Narration planning is clip-level, not scene-level.
            let script = SubtitleSidecarWriter.makeNarrationDocument(entries: buildTimedEntries(), totalDuration: artifacts.totalDuration)
            try script.write(to: baseURL.appendingPathExtension("md"), atomically: true, encoding: .utf8)
        }

        let yaml = RawDescriptionSidecarWriter.makeYAML(
            urls: selectedURLs,
            clipDescriptions: clipDescriptions,
            clipScenes: clipScenes,
            clipDurations: clipDurations,
            clipEngines: clipEngines,
            clipWarnings: clipWarnings
        )
        try yaml.write(to: baseURL.appendingPathExtension("yaml"), atomically: true, encoding: .utf8)
    }

    private var currentSubtitleStyle: SubtitleStyle {
        SubtitleStyle(
            position: subtitlePosition,
            fontScale: subtitleFontScale,
            backgroundOpacity: subtitleBackgroundOpacity
        )
    }

    // Used by preview UI without exposing internal style details.
    func previewSubtitleStyle() -> SubtitleStyle { currentSubtitleStyle }
    func previewSceneTimedEntries() -> [TimedScriptEntry] { buildSceneTimedEntries() }
    func previewClipTimedEntries() -> [TimedScriptEntry] { buildTimedEntries() }
    func previewActiveEntries() -> [TimedScriptEntry] { activeSubtitleEntries() }

    private func resolvedPythonExec() -> String {
        let trimmed = pythonInterpreterPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeSystem = trimmed.isEmpty || trimmed == "python3" || trimmed == "python"

        if looksLikeSystem, let discovered = discoverVenvPythonNearApp() {
            // Persist so future runs are consistent.
            if pythonInterpreterPath != discovered {
                pythonInterpreterPath = discovered
                UserDefaults.standard.set(discovered, forKey: pythonPathDefaultsKey)
            }
            return discovered
        }

        if trimmed.isEmpty { return "python3" }
        return trimmed
    }

    func useDetectedVenvPython() {
        guard let discovered = discoverVenvPythonNearApp() else {
            statusMessage = "No .venv found near the app."
            return
        }
        pythonInterpreterPath = discovered
        UserDefaults.standard.set(discovered, forKey: pythonPathDefaultsKey)
        statusMessage = "Python set to: .venv"
    }

    func enableGPUMemoryBoost() {
        setGPUMemoryLimit(configuredGPUMemoryLimitMB)
    }

    func resetGPUMemoryBoost() {
        setGPUMemoryLimit(0)
    }

    private func setGPUMemoryLimit(_ megabytes: Int) {
        guard !isConfiguringGPULimit else { return }
        isConfiguringGPULimit = true
        statusMessage = megabytes > 0 ? "Enabling GPU boost..." : "Resetting GPU boost..."
        statusDetail = "A macOS admin dialog may appear."

        Task<Void, Never> {
            let result = await Self.runPrivilegedSysctl(iogpuWiredLimitMB: megabytes)
            await MainActor.run {
                self.isConfiguringGPULimit = false
                self.statusDetail = nil
                switch result {
                case .success:
                    self.statusMessage = megabytes > 0
                        ? "GPU boost enabled (\(megabytes) MB)."
                        : "GPU boost reset."
                    self.refreshCurrentGPUMemoryLimit()
                case .failure(let error):
                    self.statusMessage = "GPU boost change failed: \(error.localizedDescription)"
                    if self.debugLoggingEnabled {
                        self.appendLog("GPU boost failed: value=\(megabytes) error=\(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func refreshCurrentGPUMemoryLimit() {
        guard !isRefreshingGPULimit else { return }
        isRefreshingGPULimit = true

        Task<Void, Never> {
            let result = await Self.readCurrentGPUMemoryLimitMB()
            await MainActor.run {
                self.isRefreshingGPULimit = false
                switch result {
                case .success(let megabytes):
                    self.currentGPUMemoryLimitMB = megabytes
                    if megabytes > 0 {
                        self.currentGPUMemoryLimitDetail = "Current limit: \(megabytes) MB (\(String(format: "%.1f", Double(megabytes) / 1024.0)) GB). Reset restores it by writing 0."
                    } else {
                        self.currentGPUMemoryLimitDetail = "Current limit: default system behavior (0 MB override)."
                    }
                    if self.debugLoggingEnabled {
                        self.appendLog("GPU limit read: \(megabytes) MB")
                    }
                    self.clampConfiguredGPUMemoryLimitToSystemCeiling()
                case .failure(let error):
                    self.currentGPUMemoryLimitMB = nil
                    self.currentGPUMemoryLimitDetail = "Current limit unavailable. Use Refresh to retry or Reset GPU Boost to restore 0."
                    if self.debugLoggingEnabled {
                        self.appendLog("GPU limit read failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func clampConfiguredGPUMemoryLimitToSystemCeiling() {
        let upper = gpuMemoryLimitSystemUpperBoundMB
        if configuredGPUMemoryLimitMB > upper {
            configuredGPUMemoryLimitMB = upper
        }
    }

    private static func runPrivilegedSysctl(iogpuWiredLimitMB: Int) async -> Result<Void, Error> {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            let shellCommand = "/usr/sbin/sysctl iogpu.wired_limit_mb=\(iogpuWiredLimitMB)"
            let escaped = shellCommand
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            process.arguments = [
                "-e",
                "do shell script \"\(escaped)\" with administrator privileges"
            ]

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return .success(())
                }
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                    ?? String(data: outData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                    ?? "Administrator command exited with status \(process.terminationStatus)."
                return .failure(VideoMergeError.exportFailed(message))
            } catch {
                return .failure(error)
            }
        }.value
    }

    private static func readCurrentGPUMemoryLimitMB() async -> Result<Int, Error> {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
            process.arguments = ["-n", "iogpu.wired_limit_mb"]

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
                process.waitUntilExit()

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderr = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard process.terminationStatus == 0 else {
                    let message = stderr.nilIfEmpty ?? stdout.nilIfEmpty ?? "sysctl exited with status \(process.terminationStatus)."
                    return .failure(VideoMergeError.exportFailed(message))
                }

                guard let megabytes = Int(stdout) else {
                    return .failure(VideoMergeError.exportFailed("Unexpected sysctl output: \(stdout)"))
                }

                return .success(megabytes)
            } catch {
                return .failure(error)
            }
        }.value
    }

    private func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    func appendLog(_ line: String) {
        let prefix = "[\(timestamp())] "
        debugLog += prefix + line + "\n"
    }

    func clearLog() {
        debugLog = ""
    }

    var recentDebugLines: [String] {
        debugLog
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(20)
            .map(String.init)
    }

    func copyLogToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(debugLog, forType: .string)
        statusMessage = "Debug log copied."
    }

    var analyzerOutputDirectoryPath: String {
        ClipDescriptionBuilder.analyzerOutputDirectoryURL().path
    }

    func openAnalyzerOutputFolder() {
        let url = URL(fileURLWithPath: analyzerOutputDirectoryPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func saveLogToFile() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "vcat-debug-log.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try debugLog.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Saved log: \(url.lastPathComponent)"
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func logStartup() {
        guard debugLoggingEnabled else { return }
        appendLog("App started")
        appendLog("Bundle: \(Bundle.main.bundleURL.path)")
        appendLog("CWD: \(FileManager.default.currentDirectoryPath)")
        appendLog("Python setting: \(pythonInterpreterPath.isEmpty ? "python3" : pythonInterpreterPath)")
        if let script = ClipDescriptionBuilder.analyzerScriptURL() {
            appendLog("Analyzer script: \(script.path)")
        } else {
            appendLog("Analyzer script: missing")
        }
    }

    private func discoverVenvPythonNearApp() -> String? {
        // When launching from `dist/VideoCombiner.app`, the working directory is not the repo root.
        // Walk up from the app bundle location and look for `.venv/bin/python`.
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent(".venv/bin/python")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    func choosePythonInterpreter() {
        let panel = NSOpenPanel()
        panel.title = "Choose Python Interpreter"
        panel.message = "Select a Python executable (recommended: .venv/bin/python) to enable local Florence-2 and Whisper."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        // Don't over-filter here; python executables may not have a predictable UTType.
        panel.allowedContentTypes = []

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            statusMessage = "Selected file is not executable."
            return
        }

        pythonInterpreterPath = url.path
        UserDefaults.standard.set(url.path, forKey: pythonPathDefaultsKey)
        statusMessage = "Python set to: \(url.lastPathComponent)"
    }
}

enum VideoMergeError: LocalizedError {
    case noVideoTrack(URL)
    case exportSessionCreationFailed
    case incompatiblePreset(String)
    case unsupportedFileType
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack(let url):
            return "No video track found in \(url.lastPathComponent)."
        case .exportSessionCreationFailed:
            return "Unable to create export session."
        case .incompatiblePreset(let preset):
            return "Export preset is not compatible: \(preset)."
        case .unsupportedFileType:
            return "Selected output file type is not supported."
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum VideoCombiner {
    private struct Segment {
        let url: URL
        let timeRange: CMTimeRange
        let preferredTransform: CGAffineTransform
        let naturalSize: CGSize
        let nominalFrameRate: Float
    }

    static func merge(
        inputURLs: [URL],
        outputURL: URL,
        profile: ExportProfile,
        subtitles: [TimedScriptEntry],
        subtitleStyle: SubtitleStyle,
        presetOverride: String? = nil,
        targetFPS: Int? = nil,
        maxRenderSize: CGSize? = nil
    ) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoMergeError.exportSessionCreationFailed
        }

        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var currentTime = CMTime.zero
        var segments: [Segment] = []

        for url in inputURLs {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw VideoMergeError.noVideoTrack(url)
            }

            try compositionVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: videoTrack,
                at: currentTime
            )

            if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
               let compositionAudioTrack {
                try compositionAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: audioTrack,
                    at: currentTime
                )
            }

            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            segments.append(
                Segment(
                    url: url,
                    timeRange: CMTimeRange(start: currentTime, duration: duration),
                    preferredTransform: preferredTransform,
                    naturalSize: naturalSize,
                    nominalFrameRate: nominalFrameRate
                )
            )

            currentTime = currentTime + duration
        }

        let renderSize = makeRenderSize(for: segments)
        let videoComposition = makeVideoComposition(
            compositionTrack: compositionVideoTrack,
            segments: segments,
            renderSize: renderSize,
            subtitles: subtitles,
            subtitleStyle: subtitleStyle,
            targetFPS: targetFPS,
            maxRenderSize: maxRenderSize
        )

        let presetName = presetOverride ?? profile.presetName
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: presetName) else {
            throw VideoMergeError.incompatiblePreset(presetName)
        }

        exportSession.outputURL = outputURL
        let fileTypes = exportSession.supportedFileTypes
        if fileTypes.contains(profile.fileType) {
            exportSession.outputFileType = profile.fileType
        } else if let fallback = fileTypes.first {
            exportSession.outputFileType = fallback
        } else {
            throw VideoMergeError.unsupportedFileType
        }

        exportSession.shouldOptimizeForNetworkUse = false
        exportSession.videoComposition = videoComposition

        try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: VideoMergeError.exportFailed(exportSession.error?.localizedDescription ?? "Unknown error"))
                case .cancelled:
                    continuation.resume(throwing: VideoMergeError.exportFailed("Canceled"))
                default:
                    continuation.resume(throwing: VideoMergeError.exportFailed("Unexpected export status: \(exportSession.status.rawValue)"))
                }
            }
        }
    }

    /// Export a low-bitrate, low-FPS proxy without changing geometry (size/orientation) of the combined timeline.
    static func exportProxy(
        inputURLs: [URL],
        outputURL: URL,
        targetFPS: Int,
        videoBitrate: Int,
        audioBitrate: Int = 64_000
    ) async throws {
        AppLog.log("Proxy export: start | urls=\(inputURLs.count) targetFPS=\(targetFPS) vbr=\(videoBitrate) abr=\(audioBitrate)")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoMergeError.exportSessionCreationFailed
        }

        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var currentTime = CMTime.zero
        var segments: [Segment] = []

        for url in inputURLs {
            AppLog.log("Proxy export: append asset | \(url.lastPathComponent)")
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw VideoMergeError.noVideoTrack(url)
            }

            try compositionVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: videoTrack,
                at: currentTime
            )

            if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
               let compositionAudioTrack {
                try compositionAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: audioTrack,
                    at: currentTime
                )
            }

            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            segments.append(
                Segment(
                    url: url,
                    timeRange: CMTimeRange(start: currentTime, duration: duration),
                    preferredTransform: preferredTransform,
                    naturalSize: naturalSize,
                    nominalFrameRate: nominalFrameRate
                )
            )

            currentTime = currentTime + duration
        }

        let renderSize = makeRenderSize(for: segments)
        AppLog.log("Proxy export: renderSize=\(Int(renderSize.width))x\(Int(renderSize.height)) totalDuration=\(String(format: "%.3f", CMTimeGetSeconds(currentTime)))")
        let videoComposition = makeVideoComposition(
            compositionTrack: compositionVideoTrack,
            segments: segments,
            renderSize: renderSize,
            subtitles: [],
            subtitleStyle: .default,
            targetFPS: max(targetFPS, 1),
            maxRenderSize: nil
        )

        let reader = try AVAssetReader(asset: composition)

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [compositionVideoTrack],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoMergeError.exportSessionCreationFailed }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput? = nil
        if let compositionAudioTrack {
            let out = AVAssetReaderAudioMixOutput(audioTracks: [compositionAudioTrack], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2
            ])
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                audioOutput = out
            }
        }
        AppLog.log("Proxy export: reader outputs | video=on audio=\(audioOutput == nil ? "off" : "on")")

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let compressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: max(videoBitrate, 100_000),
            AVVideoMaxKeyFrameIntervalKey: max(targetFPS * 2, 12),
            AVVideoAllowFrameReorderingKey: false
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: compressionProps
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw VideoMergeError.exportSessionCreationFailed }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput? = nil
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: max(audioBitrate, 16_000)
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }
        AppLog.log("Proxy export: writer inputs | video=on audio=\(audioInput == nil ? "off" : "on")")

        guard writer.startWriting() else {
            throw VideoMergeError.exportFailed(writer.error?.localizedDescription ?? "writer start failed")
        }
        guard reader.startReading() else {
            throw VideoMergeError.exportFailed(reader.error?.localizedDescription ?? "reader start failed")
        }
        writer.startSession(atSourceTime: .zero)
        AppLog.log("Proxy export: reading/writing started | reader=\(reader.status.rawValue) writer=\(writer.status.rawValue)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            let videoQueue = DispatchQueue(label: "vcat.proxy.video")
            let audioQueue = DispatchQueue(label: "vcat.proxy.audio")
            let lock = NSLock()
            var finished = false
            var videoSamples = 0
            var audioSamples = 0

            func finishIfDone() {
                lock.lock()
                if finished {
                    lock.unlock()
                    return
                }
                finished = true
                lock.unlock()

                if reader.status == .failed {
                    writer.cancelWriting()
                    continuation.resume(throwing: VideoMergeError.exportFailed(reader.error?.localizedDescription ?? "reader failed"))
                    return
                }
                if writer.status == .failed {
                    continuation.resume(throwing: VideoMergeError.exportFailed(writer.error?.localizedDescription ?? "writer failed"))
                    return
                }
                writer.finishWriting {
                    if writer.status == .completed {
                        // Sanity-check: avoid silent 0-byte outputs.
                        let size = ((try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue) ?? 0
                        AppLog.log("Proxy export: finished | videoSamples=\(videoSamples) audioSamples=\(audioSamples) fileBytes=\(size)")
                        if size <= 0 || videoSamples == 0 {
                            continuation.resume(throwing: VideoMergeError.exportFailed("proxy output empty (bytes=\(size), videoSamples=\(videoSamples), audioSamples=\(audioSamples))"))
                        } else {
                            continuation.resume()
                        }
                    } else {
                        continuation.resume(throwing: VideoMergeError.exportFailed(writer.error?.localizedDescription ?? "writer finish failed"))
                    }
                }
            }

            group.enter()
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                var loggedFirst = false
                while videoInput.isReadyForMoreMediaData {
                    if reader.status != .reading { break }
                    guard let sample = videoOutput.copyNextSampleBuffer() else {
                        AppLog.log("Proxy export: videoOutput EOF | status=\(reader.status.rawValue)")
                        videoInput.markAsFinished()
                        group.leave()
                        break
                    }
                    if !videoInput.append(sample) {
                        AppLog.log("Proxy export: videoInput append failed | \(writer.error?.localizedDescription ?? "unknown")")
                        reader.cancelReading()
                        videoInput.markAsFinished()
                        group.leave()
                        break
                    }
                    videoSamples += 1
                    if !loggedFirst {
                        loggedFirst = true
                        AppLog.log("Proxy export: first video sample appended")
                    }
                    if videoSamples % 120 == 0 {
                        AppLog.log("Proxy export: videoSamples=\(videoSamples)")
                    }
                }
            }

            if let audioOutput, let audioInput {
                group.enter()
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    var loggedFirst = false
                    while audioInput.isReadyForMoreMediaData {
                        if reader.status != .reading { break }
                        guard let sample = audioOutput.copyNextSampleBuffer() else {
                            AppLog.log("Proxy export: audioOutput EOF | status=\(reader.status.rawValue)")
                            audioInput.markAsFinished()
                            group.leave()
                            break
                        }
                        if !audioInput.append(sample) {
                            AppLog.log("Proxy export: audioInput append failed | \(writer.error?.localizedDescription ?? "unknown")")
                            reader.cancelReading()
                            audioInput.markAsFinished()
                            group.leave()
                            break
                        }
                        audioSamples += 1
                        if !loggedFirst {
                            loggedFirst = true
                            AppLog.log("Proxy export: first audio sample appended")
                        }
                        if audioSamples % 240 == 0 {
                            AppLog.log("Proxy export: audioSamples=\(audioSamples)")
                        }
                    }
                }
            }

            group.notify(queue: .global(qos: .userInitiated)) {
                AppLog.log("Proxy export: streams finished | reader=\(reader.status.rawValue) writer=\(writer.status.rawValue)")
                finishIfDone()
            }
        }
    }

    /// Proxy export that preserves geometry and avoids AVAssetWriter encoder issues on large frames (e.g. 4K).
    /// Low FPS is enforced via `videoComposition.frameDuration`; low quality via `fileLengthLimit`.
    static func exportProxyViaExportSession(
        inputURLs: [URL],
        outputURL: URL,
        targetFPS: Int,
        targetTotalBitrate: Int
    ) async throws {
        AppLog.log("Proxy export (exportSession): start | urls=\(inputURLs.count) targetFPS=\(targetFPS) totalBitrate=\(targetTotalBitrate)")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoMergeError.exportSessionCreationFailed
        }

        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var currentTime = CMTime.zero
        var segments: [Segment] = []

        for url in inputURLs {
            AppLog.log("Proxy export (exportSession): append asset | \(url.lastPathComponent)")
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw VideoMergeError.noVideoTrack(url)
            }

            try compositionVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: videoTrack,
                at: currentTime
            )

            if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
               let compositionAudioTrack {
                try compositionAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: audioTrack,
                    at: currentTime
                )
            }

            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            segments.append(
                Segment(
                    url: url,
                    timeRange: CMTimeRange(start: currentTime, duration: duration),
                    preferredTransform: preferredTransform,
                    naturalSize: naturalSize,
                    nominalFrameRate: nominalFrameRate
                )
            )

            currentTime = currentTime + duration
        }

        let durationSeconds = max(CMTimeGetSeconds(currentTime), 0.0)
        let renderSize = makeRenderSize(for: segments)
        AppLog.log("Proxy export (exportSession): renderSize=\(Int(renderSize.width))x\(Int(renderSize.height)) totalDuration=\(String(format: "%.3f", durationSeconds))")

        let videoComposition = makeVideoComposition(
            compositionTrack: compositionVideoTrack,
            segments: segments,
            renderSize: renderSize,
            subtitles: [],
            subtitleStyle: .default,
            targetFPS: max(targetFPS, 1),
            maxRenderSize: nil
        )

        let preset = AVAssetExportPresetHighestQuality
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw VideoMergeError.incompatiblePreset(preset)
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.videoComposition = videoComposition

        let bytes = Int64(max(Double(targetTotalBitrate) / 8.0 * durationSeconds, 256_000))
        exportSession.fileLengthLimit = bytes
        AppLog.log("Proxy export (exportSession): fileLengthLimit=\(bytes) bytes")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    let size = ((try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue) ?? 0
                    AppLog.log("Proxy export (exportSession): completed | fileBytes=\(size)")
                    if size <= 0 {
                        continuation.resume(throwing: VideoMergeError.exportFailed("proxy output empty (bytes=\(size))"))
                    } else {
                        continuation.resume()
                    }
                case .failed:
                    AppLog.log("Proxy export (exportSession): failed | \(exportSession.error?.localizedDescription ?? "Unknown error")")
                    continuation.resume(throwing: VideoMergeError.exportFailed(exportSession.error?.localizedDescription ?? "Unknown error"))
                case .cancelled:
                    AppLog.log("Proxy export (exportSession): cancelled")
                    continuation.resume(throwing: VideoMergeError.exportFailed("Canceled"))
                default:
                    AppLog.log("Proxy export (exportSession): unexpected status \(exportSession.status.rawValue)")
                    continuation.resume(throwing: VideoMergeError.exportFailed("Unexpected export status: \(exportSession.status.rawValue)"))
                }
            }
        }
    }

    @MainActor
    static func makePreviewPlayerItem(
        inputURLs: [URL],
        subtitleStyle: SubtitleStyle
    ) async throws -> AVPlayerItem {
        AppLog.log("Preview | build start | clipCount=\(inputURLs.count)")
        let startedAt = Date()
        let (composition, videoComposition) = try await buildPreviewComposition(inputURLs: inputURLs, subtitleStyle: subtitleStyle)
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        let elapsed = Date().timeIntervalSince(startedAt)
        AppLog.log("Preview | build end | clipCount=\(inputURLs.count) elapsedMs=\(Int(elapsed * 1000))")
        return item
    }

    private nonisolated static func buildPreviewComposition(
        inputURLs: [URL],
        subtitleStyle: SubtitleStyle
    ) async throws -> (composition: AVMutableComposition, videoComposition: AVMutableVideoComposition) {
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoMergeError.exportSessionCreationFailed
        }

        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var currentTime = CMTime.zero
        var segments: [Segment] = []

        for url in inputURLs {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw VideoMergeError.noVideoTrack(url)
            }

            try compositionVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: videoTrack,
                at: currentTime
            )

            if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
               let compositionAudioTrack {
                try compositionAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: audioTrack,
                    at: currentTime
                )
            }

            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
            segments.append(
                Segment(
                    url: url,
                    timeRange: CMTimeRange(start: currentTime, duration: duration),
                    preferredTransform: preferredTransform,
                    naturalSize: naturalSize,
                    nominalFrameRate: nominalFrameRate
                )
            )

            currentTime = currentTime + duration
        }

        let renderSize = makeRenderSize(for: segments)
        let videoComposition = makeVideoComposition(
            compositionTrack: compositionVideoTrack,
            segments: segments,
            renderSize: renderSize,
            // Subtitles are shown as a live overlay during preview.
            subtitles: [],
            subtitleStyle: subtitleStyle
        )
        return (composition, videoComposition)
    }

    private static func makeRenderSize(for segments: [Segment]) -> CGSize {
        var maxWidth: CGFloat = 1280
        var maxHeight: CGFloat = 720

        for segment in segments {
            let rect = CGRect(origin: .zero, size: segment.naturalSize).applying(segment.preferredTransform)
            maxWidth = max(maxWidth, abs(rect.width))
            maxHeight = max(maxHeight, abs(rect.height))
        }

        return CGSize(width: ceil(maxWidth / 2) * 2, height: ceil(maxHeight / 2) * 2)
    }

    private static func makeVideoComposition(
        compositionTrack: AVMutableCompositionTrack,
        segments: [Segment],
        renderSize: CGSize,
        subtitles: [TimedScriptEntry],
        subtitleStyle: SubtitleStyle,
        targetFPS: Int? = nil,
        maxRenderSize: CGSize? = nil
    ) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        if let targetFPS, targetFPS > 0 {
            videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        } else {
            let maxFPS = segments.map(\.nominalFrameRate).filter { $0 > 0 }.max() ?? 30
            videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(30, Int32(maxFPS.rounded()))))
        }

        if let maxRenderSize {
            videoComposition.renderSize = CGSize(
                width: min(renderSize.width, maxRenderSize.width),
                height: min(renderSize.height, maxRenderSize.height)
            )
        } else {
            videoComposition.renderSize = renderSize
        }

        // Use the final render size for all transforms/overlays. (Proxy export may cap render size.)
        let finalRenderSize = videoComposition.renderSize
        videoComposition.instructions = segments.map { segment in
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = segment.timeRange

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
            let transform = normalizedTransform(
                preferredTransform: segment.preferredTransform,
                naturalSize: segment.naturalSize,
                renderSize: finalRenderSize
            )
            layerInstruction.setTransform(transform, at: segment.timeRange.start)
            instruction.layerInstructions = [layerInstruction]
            return instruction
        }

        if !subtitles.isEmpty {
            let parentLayer = CALayer()
            parentLayer.frame = CGRect(origin: .zero, size: finalRenderSize)
            parentLayer.isGeometryFlipped = true

            let videoLayer = CALayer()
            videoLayer.frame = parentLayer.frame
            parentLayer.addSublayer(videoLayer)

            for entry in subtitles where !entry.text.isEmpty {
                let overlay = makeSubtitleLayer(
                    text: entry.text,
                    renderSize: finalRenderSize,
                    start: entry.start,
                    duration: entry.duration,
                    style: subtitleStyle
                )
                parentLayer.addSublayer(overlay)
            }

            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer,
                in: parentLayer
            )
        }

        return videoComposition
    }

    private static func normalizedTransform(
        preferredTransform: CGAffineTransform,
        naturalSize: CGSize,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let fitted = preferredTransform.translatedBy(x: -rect.origin.x, y: -rect.origin.y)
        let centeredX = (renderSize.width - abs(rect.width)) / 2
        let centeredY = (renderSize.height - abs(rect.height)) / 2
        return fitted.translatedBy(x: centeredX, y: centeredY)
    }

    private static func makeSubtitleLayer(
        text: String,
        renderSize: CGSize,
        start: CMTime,
        duration: CMTime,
        style: SubtitleStyle
    ) -> CALayer {
        let fontSize = max(min(renderSize.width, renderSize.height) * 0.043 * style.fontScale, 18)
        let horizontalInset = renderSize.width * 0.08
        let containerWidth = renderSize.width - (horizontalInset * 2)
        let estimatedHeight = max(fontSize * 3.6, renderSize.height * 0.13)
        let originY = max(renderSize.height * style.position.verticalRatio - (estimatedHeight / 2), 20)

        let container = CALayer()
        container.frame = CGRect(
            x: horizontalInset,
            y: min(originY, renderSize.height - estimatedHeight - 20),
            width: containerWidth,
            height: estimatedHeight
        )
        container.opacity = 0

        let background = CALayer()
        background.frame = container.bounds
        background.backgroundColor = NSColor.black.withAlphaComponent(style.backgroundOpacity).cgColor
        background.cornerRadius = 18
        container.addSublayer(background)

        let textLayer = CATextLayer()
        textLayer.frame = container.bounds.insetBy(dx: 18, dy: 14)
        textLayer.string = text
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        textLayer.fontSize = fontSize
        textLayer.alignmentMode = .center
        textLayer.isWrapped = true
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        container.addSublayer(textLayer)

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 1, 1, 0]
        animation.keyTimes = [0, 0.08, 0.92, 1]
        animation.beginTime = AVCoreAnimationBeginTimeAtZero + CMTimeGetSeconds(start)
        animation.duration = max(CMTimeGetSeconds(duration), 0.1)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        container.add(animation, forKey: "subtitleOpacity")

        return container
    }
}

enum DraftScriptBuilder {
    static func draft(from description: String, fallbackFilename: String) -> String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return fallbackPhrase(from: fallbackFilename)
        }

        let sentences = trimmed
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let preferred = sentences.first {
            let lower = $0.lowercased()
            return !lower.contains("encoded as")
                && !lower.contains("running at")
                && !lower.contains("source file")
                && !lower.contains("ready to be sequenced")
                && !lower.contains("clip at")
        } ?? sentences.first ?? ""

        let cleaned = preferred
            .replacingOccurrences(of: #"^[^ ]+\.(mp4|mov|m4v)\s+is\s+a\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"On-device scene analysis suggests\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"Local scene captioning indicates:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty {
            return fallbackPhrase(from: fallbackFilename)
        }

        return limitWords(cleaned.prefix(1).uppercased() + cleaned.dropFirst(), maxWords: 14)
    }

    private static func fallbackPhrase(from filename: String) -> String {
        let cleaned = filename
            .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Add your subtitle or voiceover line here." : limitWords(cleaned, maxWords: 10)
    }

    private static func limitWords(_ text: String, maxWords: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.count <= maxWords { return text }
        return words.prefix(maxWords).joined(separator: " ")
    }
}

enum SubtitleSidecarWriter {
    static func makeSRT(entries: [TimedScriptEntry]) -> String {
        let spokenEntries = entries.filter { !$0.text.isEmpty && CMTimeCompare($0.duration, .zero) > 0 }
        return spokenEntries.enumerated().map { offset, entry in
            [
                "\(offset + 1)",
                "\(srtTimestamp(for: entry.start)) --> \(srtTimestamp(for: entry.start + entry.duration))",
                entry.text
            ].joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func makeNarrationDocument(entries: [TimedScriptEntry], totalDuration: CMTime) -> String {
        var lines: [String] = []
        lines.append("# Narration Plan")
        lines.append("")
        lines.append("- Total duration: \(ClipDescriptionBuilder.formatDuration(max(CMTimeGetSeconds(totalDuration), 0)))")
        lines.append("- Clips: \(entries.count)")
        lines.append("")

        for entry in entries {
            lines.append("## \(entry.index). \(entry.url.lastPathComponent)")
            lines.append("- Time: \(scriptTimestamp(for: entry.start)) -> \(scriptTimestamp(for: entry.start + entry.duration))")
            lines.append("- Clip duration: \(ClipDescriptionBuilder.formatDuration(max(CMTimeGetSeconds(entry.duration), 0)))")
            lines.append("- Recommended narration length: \(entry.targetWordRange.lowerBound)-\(entry.targetWordRange.upperBound) words")
            lines.append("- Script: \(entry.text.isEmpty ? "[empty]" : entry.text)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func srtTimestamp(for time: CMTime) -> String {
        let totalMilliseconds = max(Int((CMTimeGetSeconds(time) * 1000).rounded()), 0)
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1000
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }

    private static func scriptTimestamp(for time: CMTime) -> String {
        let totalSeconds = max(Int(CMTimeGetSeconds(time).rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

enum RawDescriptionSidecarWriter {
    private static let analyzerMaxEdge = 512
    private static let analyzerJPEGQuality = 65

    static func makeYAML(
        urls: [URL],
        clipDescriptions: [URL: String],
        clipScenes: [URL: [ClipSceneCaption]],
        clipDurations: [URL: Double],
        clipEngines: [URL: String],
        clipWarnings: [URL: [String]]
    ) -> String {
        var lines: [String] = ["clips:"]
        var globalOffset: Double = 0

        for url in urls {
            let filename = url.lastPathComponent
            let duration = max(clipDurations[url] ?? 0, 0)
            let scenes = (clipScenes[url] ?? []).sorted { $0.startSeconds < $1.startSeconds }
            let engine = clipEngines[url]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let warnings = (clipWarnings[url] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            lines.append("  \(yamlKey(filename)):")
            lines.append("    source_path: \(yamlString(url.path))")
            lines.append("    global_start_time: \(decimal(globalOffset))")
            lines.append("    duration: \(decimal(duration))")
            if !engine.isEmpty {
                lines.append("    engine: \(yamlString(engine))")
            }
            if warnings.isEmpty {
                lines.append("    warnings: []")
            } else {
                lines.append("    warnings:")
                for warning in warnings {
                    lines.append("    - \(yamlString(warning))")
                }
            }
            lines.append("    frames_analyzed: \(scenes.count)")
            lines.append("    frame_resolution: \(yamlString("max_edge=\(analyzerMaxEdge)px"))")
            lines.append("    jpeg_quality: \(analyzerJPEGQuality)")

            if scenes.isEmpty {
                lines.append("    visual_logs: []")
            } else {
                lines.append("    visual_logs:")
                for scene in scenes {
                    let globalSceneStart = globalOffset + max(scene.startSeconds, 0)
                    lines.append("    - timestamp: \(srtTimestamp(seconds: globalSceneStart))")
                    lines.append("      local_start_time: \(decimal(max(scene.startSeconds, 0)))")
                    lines.append("      global_start_time: \(decimal(globalSceneStart))")
                    lines.append("      description: |-")
                    lines.append(contentsOf: blockLines(scene.caption.trimmingCharacters(in: .whitespacesAndNewlines), indent: "        "))
                }
            }

            globalOffset += duration
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func blockLines(_ text: String, indent: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: " | ", with: "\n")
        return normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let content = String(line)
                return content.isEmpty ? indent : indent + content
            }
    }

    private static func yamlKey(_ value: String) -> String {
        if value.range(of: #"^[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil {
            return value
        }
        return yamlString(value)
    }

    private static func yamlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func decimal(_ value: Double) -> String {
        if value.isNaN || !value.isFinite { return "0.0" }
        let rounded = (value * 1000).rounded() / 1000
        if rounded == floor(rounded) {
            return String(format: "%.1f", rounded)
        }
        if rounded * 10 == floor(rounded * 10) {
            return String(format: "%.1f", rounded)
        }
        if rounded * 100 == floor(rounded * 100) {
            return String(format: "%.2f", rounded)
        }
        return String(format: "%.3f", rounded)
    }

    private static func srtTimestamp(seconds: Double) -> String {
        let totalMilliseconds = max(Int((seconds * 1000).rounded()), 0)
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let secs = (totalMilliseconds % 60_000) / 1000
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, milliseconds)
    }
}

enum ClaudeSubtitleClient {
    private static let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-sonnet-4-20250514"
    private static let anthropicVersion = "2023-06-01"

    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let max_tokens: Int
        let temperature: Double
        let messages: [Message]
    }

    private struct ResponseBody: Decodable {
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }

        struct APIError: Decodable {
            let message: String
        }

        let content: [ContentBlock]?
        let error: APIError?
    }

    static func generateSRT(prompt: String, yaml: String) async throws -> String {
        let key = try loadAPIKey()
        AppLog.log("Claude API | key loaded | promptChars=\(prompt.count) yamlChars=\(yaml.count)")
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let message = """
\(prompt)

YAML input:
```yaml
\(yaml)
```
"""
        let body = RequestBody(
            model: model,
            max_tokens: 4096,
            temperature: 0.5,
            messages: [.init(role: "user", content: message)]
        )
        request.httpBody = try JSONEncoder().encode(body)
        AppLog.log("Claude API | request | model=\(model) bodyBytes=\(request.httpBody?.count ?? 0)")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            AppLog.log("Claude API | invalid response | non-http")
            throw VideoMergeError.exportFailed("Claude response was not HTTP.")
        }
        AppLog.log("Claude API | response | status=\(http.statusCode) bytes=\(data.count)")

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard (200...299).contains(http.statusCode) else {
            AppLog.log("Claude API | error | status=\(http.statusCode) message=\(decoded.error?.message ?? "unknown")")
            throw VideoMergeError.exportFailed(decoded.error?.message ?? "Claude API returned HTTP \(http.statusCode).")
        }

        let text = (decoded.content ?? [])
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            AppLog.log("Claude API | error | empty text response")
            throw VideoMergeError.exportFailed("Claude returned empty text.")
        }
        AppLog.log("Claude API | success | textChars=\(text.count)")
        return text
    }

    private static func loadAPIKey() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".credentails/claude/api-key-vcat.txt"),
            home.appendingPathComponent(".credentials/claude/api-key-vcat.txt")
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            let key = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                AppLog.log("Claude API | key path found | path=\(url.path)")
                return key
            }
        }
        AppLog.log("Claude API | key missing")
        throw VideoMergeError.exportFailed("Claude API key file not found.")
    }
}

enum ClipDescriptionBuilder {
    private struct ExternalVisualLog: Decodable {
        let timestamp: String?
        let timestamp_seconds: Double?
        let description: String?
    }

    private struct ExternalScene: Decodable {
        let index: Int?
        let start_sec: Double?
        let end_sec: Double?
        let mid_sec: Double?
        let caption: String?
    }

    private struct ExternalResult: Decodable {
        let input_path: String?
        let global_start_time: Double?
        let duration: Double?
        let description: String?
        let engine: String?
        let scene_count: Int?
        let scenes: [ExternalScene]?
        let warnings: [String]?
        let frames_analyzed: Int?
        let frame_resolution: String?
        let jpeg_quality: Int?
        let visual_logs: [ExternalVisualLog]?
        let error: String?
    }

    private struct ExternalBatchResult: Decodable {
        let clips: [String: ExternalResult]?
        let error: String?
        let warnings: [String]?
    }

    private struct ExternalRun {
        let launcher: String
        let scriptPath: String
        let inputPaths: [String]
        let maxWords: Int
        let lang: String
        let segmentSeconds: Double
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let decoded: ExternalResult?
        let decodedBatch: ExternalBatchResult?
    }

    struct DescribeResult {
        let description: String
        let engine: String
        let warnings: [String]
        let scenes: [ClipSceneCaption]
        let debugLines: [String]
    }

    private struct VisualSummary {
        let tags: [String]
        let activity: String
        let palette: String
    }

    private static func decodeJSONPayload<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        if let decoded = try? JSONDecoder().decode(T.self, from: data) {
            return decoded
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidates: [Character] = ["{", "["]
        var bestRange: Range<String.Index>?
        for marker in candidates {
            guard let start = trimmed.firstIndex(of: marker) else { continue }
            let candidate = trimmed[start...]
            if let _ = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) {
                bestRange = start..<trimmed.endIndex
                break
            }
        }

        guard let range = bestRange else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(trimmed[range].utf8))
    }

    private static func externalDebugLines(for run: ExternalRun) -> [String] {
        var debugLines: [String] = []
        debugLines.append("Analyzer cmd: \(run.launcher) \(run.scriptPath) --input \(run.inputPaths.joined(separator: " ")) --max-words \(run.maxWords) --lang \(run.lang) --segment-sec \(String(format: "%.3f", run.segmentSeconds))")
        debugLines.append("Analyzer exitCode: \(run.exitCode)")
        if !run.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            debugLines.append("Analyzer stderr:\n\(run.stderr)")
        }
        if !run.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            debugLines.append("Analyzer stdout:\n\(run.stdout)")
        }
        return debugLines
    }

    enum EngineId: String, CaseIterable, Identifiable {
        case auto = "Auto (best available)"
        case llamafile = "Local llamafile / LLaVA"
        case florence = "Florence-2 + local tools"

        var id: String { rawValue }
    }

    static func describe(
        url: URL,
        pythonExec: String,
        maxWords: Int,
        language: DescriptionLanguage,
        segmentSeconds: Double,
        engine: EngineId
    ) async throws -> DescribeResult {
        let maxWords = min(max(maxWords, 60), 300)
        var fallbackDebugLines: [String] = []
        if let run = await externalDescription(url: url, maxWords: maxWords, pythonExec: pythonExec, language: language, segmentSeconds: segmentSeconds, engine: engine) {
            let debugLines = externalDebugLines(for: run)
            fallbackDebugLines = debugLines

            if let item = run.decodedBatch?.clips?[url.lastPathComponent] {
                switch decodeExternalResult(item, debugLines: debugLines) {
                case .success(let result):
                    return result
                case .failure:
                    break
                }
            }

            if let description = run.decoded?.description, !description.isEmpty {
                let scenes: [ClipSceneCaption] = (run.decoded?.scenes ?? []).compactMap { scene in
                    guard let start = scene.start_sec, let end = scene.end_sec else { return nil }
                    let idx = scene.index ?? 0
                    let caption = (scene.caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return ClipSceneCaption(index: idx, startSeconds: start, endSeconds: end, caption: caption)
                }
                .sorted { $0.index < $1.index }
                return DescribeResult(
                    description: description,
                    engine: run.decoded?.engine ?? "external_python",
                    warnings: run.decoded?.warnings ?? [],
                    scenes: scenes,
                    debugLines: debugLines
                )
            }
        }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = max(CMTimeGetSeconds(duration), 0)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            return DescribeResult(
                description: limitWords("Clip \(url.lastPathComponent) contains no video track.", maxWords: maxWords),
                engine: "on_device_vision",
                warnings: [],
                scenes: [],
                debugLines: fallbackDebugLines
            )
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let adjustedSize = naturalSize.applying(transform)
        let width = Int(abs(adjustedSize.width).rounded())
        let height = Int(abs(adjustedSize.height).rounded())
        let fps = try await track.load(.nominalFrameRate)
        let codec = try await codecName(for: track)

        let fileValues = try? url.resourceValues(forKeys: [.fileSizeKey])
        let fileSizeText = formatFileSize(fileValues?.fileSize)
        let durationText = formatDuration(seconds)
        let fpsText = fps > 0 ? String(format: "%.1f fps", fps) : "variable frame rate"
        let visualSummary = analyzeVisualContent(asset: asset, durationSeconds: seconds)
        let tagText = visualSummary.tags.isEmpty ? "no strong object labels detected" : visualSummary.tags.joined(separator: ", ")

        let text = """
        \(url.lastPathComponent) is a \(durationText) clip at \(width)x\(height), encoded as \(codec), and running at \(fpsText). On-device scene analysis suggests \(visualSummary.activity) with a \(visualSummary.palette) color palette. Likely visual themes: \(tagText). The source file is about \(fileSizeText), and this clip is ready to be sequenced into your combined export.
        """
        return DescribeResult(
            description: limitWords(text, maxWords: maxWords),
            engine: "on_device_vision",
            warnings: [],
            scenes: [],
            debugLines: fallbackDebugLines
        )
    }

    static func describeAll(
        urls: [URL],
        pythonExec: String,
        maxWords: Int,
        language: DescriptionLanguage,
        segmentSeconds: Double,
        engine: EngineId
    ) async -> [(URL, Result<DescribeResult, Error>)] {
        let maxWords = min(max(maxWords, 60), 300)
        guard !urls.isEmpty else { return [] }
        guard let run = await externalDescription(urls: urls, maxWords: maxWords, pythonExec: pythonExec, language: language, segmentSeconds: segmentSeconds, engine: engine) else {
            return await fallbackDescribeAll(urls: urls, pythonExec: pythonExec, maxWords: maxWords, language: language, segmentSeconds: segmentSeconds, engine: engine)
        }

        let debugLines = externalDebugLines(for: run)

        if let clips = run.decodedBatch?.clips, !clips.isEmpty {
            return urls.map { url in
                if let item = clips[url.lastPathComponent] {
                    return (url, decodeExternalResult(item, debugLines: debugLines))
                }
                return (url, .failure(VideoMergeError.exportFailed("No description result returned for \(url.lastPathComponent)")))
            }
        }

        if let single = run.decoded {
            return urls.map { url in
                if url.path == single.input_path || urls.count == 1 {
                    return (url, decodeExternalResult(single, debugLines: debugLines))
                }
                return (url, .failure(VideoMergeError.exportFailed("No description result returned for \(url.lastPathComponent)")))
            }
        }

        return await fallbackDescribeAll(urls: urls, pythonExec: pythonExec, maxWords: maxWords, language: language, segmentSeconds: segmentSeconds, engine: engine)
    }

    private static func externalDescription(
        url: URL,
        maxWords: Int,
        pythonExec: String,
        language: DescriptionLanguage,
        segmentSeconds: Double,
        engine: EngineId
    ) async -> ExternalRun? {
        await externalDescription(urls: [url], maxWords: maxWords, pythonExec: pythonExec, language: language, segmentSeconds: segmentSeconds, engine: engine)
    }

    private static func externalDescription(
        urls: [URL],
        maxWords: Int,
        pythonExec: String,
        language: DescriptionLanguage,
        segmentSeconds: Double,
        engine: EngineId
    ) async -> ExternalRun? {
        guard let scriptURL = resolveAnalyzerScriptURL() else { return nil }
        let outputURL = analyzerOutputDirectoryURL()

        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            let isShellLauncher = scriptURL.pathExtension == "sh"
            if isShellLauncher {
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            }
            var args: [String] = isShellLauncher ? [
                scriptURL.path
            ] : [
                pythonExec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "python3" : pythonExec,
                scriptURL.path
            ]
            if scriptURL.lastPathComponent == "run.sh" || scriptURL.lastPathComponent == "descriptiongen_run.sh" || scriptURL.lastPathComponent == "descriptiongen_process_vlog.py" || scriptURL.path.contains("/tools/descriptiongen/") {
                args.append("--json-output")
            }
            args.append("--input")
            args.append(contentsOf: urls.map(\.path))
            args.append(contentsOf: [
                "--max-words", String(maxWords),
                "--lang", language.analyzerArg,
                "--segment-sec", String(format: "%.3f", segmentSeconds)
            ])
            switch engine {
            case .auto:
                break
            case .llamafile:
                args.append(contentsOf: ["--engine", "llamafile"])
            case .florence:
                args.append(contentsOf: ["--engine", "florence"])
            }
            process.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["VCAT_OUTPUT_DIR"] = outputURL.path
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let ioLock = NSLock()
            var outData = Data()
            var errData = Data()

            func appendChunk(_ data: Data, to target: inout Data, label: String) {
                guard !data.isEmpty else { return }
                target.append(data)
                if let text = String(data: data, encoding: .utf8) {
                    let trimmed = text.trimmingCharacters(in: .newlines)
                    if !trimmed.isEmpty {
                        AppLog.log("\(label): \(trimmed)")
                    }
                }
            }

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                ioLock.lock()
                appendChunk(chunk, to: &outData, label: "Analyzer stdout")
                ioLock.unlock()
            }

            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                ioLock.lock()
                appendChunk(chunk, to: &errData, label: "Analyzer stderr")
                ioLock.unlock()
            }

            AppLog.log("Analyzer started: \(isShellLauncher ? "/bin/bash" : (pythonExec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "python3" : pythonExec)) \(args.joined(separator: " "))")

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                return nil
            }

            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            let remainingOut = outPipe.fileHandleForReading.readDataToEndOfFile()
            let remainingErr = errPipe.fileHandleForReading.readDataToEndOfFile()
            ioLock.lock()
            outData.append(remainingOut)
            errData.append(remainingErr)
            ioLock.unlock()

            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            let decoded = decodeJSONPayload(ExternalResult.self, from: outData)
            let decodedBatch = decodeJSONPayload(ExternalBatchResult.self, from: outData)
            return ExternalRun(
                launcher: isShellLauncher ? "/bin/bash" : (pythonExec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "python3" : pythonExec),
                scriptPath: scriptURL.path,
                inputPaths: urls.map(\.path),
                maxWords: maxWords,
                lang: language.analyzerArg,
                segmentSeconds: segmentSeconds,
                exitCode: process.terminationStatus,
                stdout: stdout,
                stderr: stderr,
                decoded: decoded,
                decodedBatch: decodedBatch
            )
        }.value
    }

    private static func resolveAnalyzerScriptURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "descriptiongen_run", withExtension: "sh") {
            return bundled
        }

        let descriptiongen = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tools/descriptiongen/run.sh")
        if FileManager.default.fileExists(atPath: descriptiongen.path) {
            return descriptiongen
        }

        return nil
    }

    static func analyzerScriptURL() -> URL? {
        resolveAnalyzerScriptURL()
    }

    static func analyzerOutputDirectoryURL() -> URL {
        let fileManager = FileManager.default
        guard let script = resolveAnalyzerScriptURL() else {
            if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                return appSupport.appendingPathComponent("VideoCombiner/output", isDirectory: true)
            }
            return URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("tools/descriptiongen/output", isDirectory: true)
        }

        let bundleResources = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .path
        if script.path.contains(bundleResources) {
            if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                return appSupport.appendingPathComponent("VideoCombiner/output", isDirectory: true)
            }
        }

        return script.deletingLastPathComponent()
            .appendingPathComponent("output", isDirectory: true)
    }

    private static func decodeExternalResult(_ item: ExternalResult, debugLines: [String]) -> Result<DescribeResult, Error> {
        let derivedScenes: [ClipSceneCaption] = (item.visual_logs ?? []).enumerated().compactMap { offset, log in
            let caption = (log.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !caption.isEmpty else { return nil }
            let fallback = Double(offset)
            let start = log.timestamp_seconds ?? (log.timestamp.flatMap(parseSrtTimestamp) ?? fallback)
            let end = start + 1.0
            return ClipSceneCaption(index: offset, startSeconds: start, endSeconds: end, caption: caption)
        }
        let scenesFromStructured: [ClipSceneCaption] = (item.scenes ?? []).compactMap { scene in
            guard let start = scene.start_sec, let end = scene.end_sec else { return nil }
            let idx = scene.index ?? 0
            let caption = (scene.caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ClipSceneCaption(index: idx, startSeconds: start, endSeconds: end, caption: caption)
        }
        .sorted { $0.index < $1.index }
        let scenes = scenesFromStructured.isEmpty ? derivedScenes : scenesFromStructured

        if let description = item.description, !description.isEmpty {
            return .success(
                DescribeResult(
                    description: description,
                    engine: item.engine ?? "external_python",
                    warnings: item.warnings ?? [],
                    scenes: scenes,
                    debugLines: debugLines
                )
            )
        }

        if !scenes.isEmpty {
            return .success(
                DescribeResult(
                    description: derivedDescription(from: scenes),
                    engine: item.engine ?? "external_python",
                    warnings: item.warnings ?? [],
                    scenes: scenes,
                    debugLines: debugLines
                )
            )
        }

        let message = item.error ?? (item.warnings?.first ?? "Description generation failed.")
        return .failure(VideoMergeError.exportFailed(message))
    }

    private static func fallbackDescribeAll(
        urls: [URL],
        pythonExec: String,
        maxWords: Int,
        language: DescriptionLanguage,
        segmentSeconds: Double,
        engine: EngineId
    ) async -> [(URL, Result<DescribeResult, Error>)] {
        var output: [(URL, Result<DescribeResult, Error>)] = []
        for url in urls {
            do {
                let result = try await describe(
                    url: url,
                    pythonExec: pythonExec,
                    maxWords: maxWords,
                    language: language,
                    segmentSeconds: segmentSeconds,
                    engine: engine
                )
                output.append((url, .success(result)))
            } catch {
                output.append((url, .failure(error)))
            }
        }
        return output
    }

    private static func derivedDescription(from scenes: [ClipSceneCaption]) -> String {
        let captions = scenes
            .map { $0.caption.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !captions.isEmpty else { return "" }

        let preview = captions.prefix(4)
        return preview.joined(separator: "\n\n")
    }

    private static func codecName(for track: AVAssetTrack) async throws -> String {
        let descriptions = try await track.load(.formatDescriptions)
        guard let first = descriptions.first else { return "unknown codec" }
        let mediaSubType = CMFormatDescriptionGetMediaSubType(first)

        switch mediaSubType {
        case kCMVideoCodecType_H264:
            return "H.264"
        case kCMVideoCodecType_HEVC:
            return "HEVC"
        case kCMVideoCodecType_AppleProRes422:
            return "Apple ProRes 422"
        default:
            return fourCC(mediaSubType)
        }
    }

    private static func parseSrtTimestamp(_ timestamp: String) -> Double? {
        let parts = timestamp.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let hours = Double(parts[0]) ?? 0
        let minutes = Double(parts[1]) ?? 0
        let secondsParts = parts[2].split(separator: ",", omittingEmptySubsequences: false)
        guard let secPart = secondsParts.first else { return nil }
        let seconds = Double(secPart) ?? 0
        let milliseconds = secondsParts.count > 1 ? Double(secondsParts[1]) ?? 0 : 0
        return hours * 3600 + minutes * 60 + seconds + (milliseconds / 1000.0)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    private static func formatFileSize(_ bytes: Int?) -> String {
        guard let bytes, bytes > 0 else { return "unknown size" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let n = code.bigEndian
        let chars: [UnicodeScalar] = [
            UnicodeScalar((n >> 24) & 255),
            UnicodeScalar((n >> 16) & 255),
            UnicodeScalar((n >> 8) & 255),
            UnicodeScalar(n & 255)
        ].compactMap { $0 }
        let text = String(String.UnicodeScalarView(chars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "codec \(code)" : text
    }

    private static func analyzeVisualContent(asset: AVURLAsset, durationSeconds: Double) -> VisualSummary {
        let sampleImages = sampleFrames(asset: asset, durationSeconds: durationSeconds, maxSamples: 6)
        guard !sampleImages.isEmpty else {
            return VisualSummary(tags: [], activity: "limited visual variation", palette: "balanced")
        }

        var tagScores: [String: Float] = [:]
        var averageColors: [SIMD3<Double>] = []

        for image in sampleImages {
            let tags = classifyImage(cgImage: image)
            for (tag, confidence) in tags {
                tagScores[tag, default: 0] += confidence
            }

            if let color = meanColor(cgImage: image) {
                averageColors.append(color)
            }
        }

        let topTags = tagScores.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        let activity = activityLabel(from: averageColors)
        let palette = paletteLabel(from: averageColors)
        return VisualSummary(tags: topTags, activity: activity, palette: palette)
    }

    private static func sampleFrames(asset: AVURLAsset, durationSeconds: Double, maxSamples: Int) -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let frameCount = max(2, min(maxSamples, Int(durationSeconds.rounded(.up))))
        var images: [CGImage] = []

        for index in 0..<frameCount {
            let percent = Double(index + 1) / Double(frameCount + 1)
            let second = max(durationSeconds * percent, 0)
            let time = CMTime(seconds: second, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                images.append(cgImage)
            }
        }
        return images
    }

    private static func classifyImage(cgImage: CGImage) -> [(String, Float)] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
            guard let results = request.results else { return [] }
            return results
                .filter { $0.confidence >= 0.2 }
                .prefix(4)
                .map { observation in
                    let cleaned = observation.identifier.replacingOccurrences(of: "_", with: " ")
                    return (cleaned, observation.confidence)
                }
        } catch {
            return []
        }
    }

    private static func meanColor(cgImage: CGImage) -> SIMD3<Double>? {
        let ciImage = CIImage(cgImage: cgImage)
        guard !ciImage.extent.isEmpty else { return nil }

        let context = CIContext(options: [.cacheIntermediates: false])
        let filter = CIFilter.areaAverage()
        filter.inputImage = ciImage
        filter.extent = ciImage.extent

        guard let outputImage = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return SIMD3(
            Double(bitmap[0]) / 255.0,
            Double(bitmap[1]) / 255.0,
            Double(bitmap[2]) / 255.0
        )
    }

    private static func activityLabel(from colors: [SIMD3<Double>]) -> String {
        guard colors.count > 1 else { return "limited visual variation" }
        var totalDelta = 0.0

        for index in 1..<colors.count {
            let prev = colors[index - 1]
            let current = colors[index]
            let dr = current.x - prev.x
            let dg = current.y - prev.y
            let db = current.z - prev.z
            totalDelta += sqrt((dr * dr) + (dg * dg) + (db * db))
        }

        let averageDelta = totalDelta / Double(colors.count - 1)
        switch averageDelta {
        case ..<0.06:
            return "mostly static scenes"
        case ..<0.14:
            return "moderate scene changes"
        default:
            return "high visual motion"
        }
    }

    private static func paletteLabel(from colors: [SIMD3<Double>]) -> String {
        guard !colors.isEmpty else { return "balanced" }
        let sum = colors.reduce(SIMD3<Double>(0, 0, 0), +)
        let mean = sum / Double(colors.count)

        let maxChannel = max(mean.x, max(mean.y, mean.z))
        let minChannel = min(mean.x, min(mean.y, mean.z))
        let saturation = maxChannel - minChannel

        if saturation < 0.08 {
            return mean.x < 0.35 ? "dark neutral" : "neutral"
        }
        if mean.x >= mean.y && mean.x >= mean.z { return "warm" }
        if mean.y >= mean.x && mean.y >= mean.z { return "green-leaning" }
        return "cool"
    }

    private static func limitWords(_ text: String, maxWords: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.count <= maxWords { return text }
        return words.prefix(maxWords).joined(separator: " ") + "..."
    }
}

struct ContentView: View {
    @StateObject private var vm = VideoMergeViewModel()
    @State private var isShowingPreview = false
    @State private var isShowingClaudeSubtitleSheet = false
    @State private var expandedDescriptionURLs: Set<URL> = []

    var body: some View {
        VStack(spacing: 16) {
            headerView
                .layoutPriority(2)

            HStack(spacing: 14) {
                sidebarView
                clipListView
            }
            .frame(maxHeight: .infinity)
            .layoutPriority(0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footerView
                .padding(20)
                .shadow(color: Color.black.opacity(0.08), radius: 18, x: 0, y: 10)
        }
        .animation(.easeInOut(duration: 0.18), value: vm.selectedURLs.count)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.97, blue: 1.0),
                    Color(red: 0.9, green: 0.93, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .onChange(of: vm.previewKeyframeCount) { _ in
            vm.invalidateKeyframes()
        }
    }

    private var headerView: some View {
        ViewThatFits(in: .horizontal) {
            headerWide
            headerNarrow
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var headerChips: some View {
        HStack(spacing: 8) {
            Label("\(vm.selectedURLs.count) Clips", systemImage: "film.stack")
                .font(.custom("Avenir Next Medium", size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())

            Label(vm.totalDurationText, systemImage: "clock")
                .font(.custom("Avenir Next Medium", size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())

            Label(vm.selectedProfile.fileExtension.uppercased(), systemImage: "square.and.arrow.down.on.square")
                .font(.custom("Avenir Next Medium", size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var headerWide: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Video Combiner")
                    // System font avoids a SwiftUI clipping bug seen with some custom fonts.
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .allowsTightening(true)
                Text("Build a rough cut, draft narration, and export subtitles with your merged vlog.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .allowsTightening(true)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            headerChips
                .layoutPriority(0)
        }
    }

    private var headerNarrow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Video Combiner")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .allowsTightening(true)
            Text("Build a rough cut, draft narration, and export subtitles with your merged vlog.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            headerChips
        }
    }

    private var sidebarView: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
            Text("Export Setup")
                .font(.custom("Avenir Next Demi Bold", size: 18))

            Picker("Codec", selection: $vm.selectedProfile) {
                ForEach(ExportProfile.allCases) { profile in
                    Text(profile.rawValue).tag(profile)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            Text(vm.selectedProfile.detail)
                .font(.custom("Avenir Next Regular", size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Preview frames")
                    .font(.custom("Avenir Next Regular", size: 12))
                Spacer()
                Text("\(vm.previewKeyframeCount)")
                    .font(.custom("Avenir Next Regular", size: 12))
                    .foregroundStyle(.secondary)
            }

            Stepper(value: $vm.previewKeyframeCount, in: 1...12, step: 1) {
                Text(" ")
            }
            .labelsHidden()

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button(action: vm.addVideos) {
                    Label("Add Videos", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                    Button(action: { vm.generateDescriptionsForAll() }) {
                        Label(vm.isGeneratingDescriptions ? "Generating..." : "Generate Descriptions", systemImage: "text.bubble")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.selectedURLs.isEmpty || vm.isGeneratingDescriptions || vm.isExporting)

                    Button(action: vm.regenerateDescriptionsForAll) {
                        Label(vm.isGeneratingDescriptions ? "Generating..." : "Regenerate Descriptions", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.selectedURLs.isEmpty || vm.isGeneratingDescriptions || vm.isExporting)

                    Button(action: vm.clearAll) {
                        Label("Remove All Clips", systemImage: "trash.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.selectedURLs.isEmpty || vm.isExporting || vm.isGeneratingDescriptions)

                HStack(spacing: 8) {
                    Button("Export Desc SRT…", action: vm.exportDescriptionSRT)
                        .frame(maxWidth: .infinity)
                    Button("Copy Desc Text", action: vm.copyTimestampedDescriptionTextToClipboard)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(vm.selectedURLs.isEmpty || vm.isGeneratingDescriptions || vm.isExporting)

                Button("Export Combined Description…", action: vm.exportCombinedDescription)
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
                    .disabled(vm.selectedURLs.isEmpty || vm.isGeneratingDescriptions || vm.isExporting)

                HStack(spacing: 8) {
                    Button("Copy Desc SRT", action: vm.copyDescriptionSRTToClipboard)
                        .frame(maxWidth: .infinity)
                    Button("Import SRT…", action: vm.importSRT)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(vm.selectedURLs.isEmpty || vm.isGeneratingDescriptions || vm.isExporting)

                Button(action: {
                    vm.prepareClaudeSubtitleComposer()
                    isShowingClaudeSubtitleSheet = true
                }) {
                    Label("Claude Final SRT", systemImage: "sparkles.rectangle.stack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(vm.selectedURLs.isEmpty || vm.isGeneratingDescriptions || vm.isExporting)

                if let path = vm.importedSRTPath {
                    Text("Using imported SRT: \(URL(fileURLWithPath: path).lastPathComponent)")
                        .font(.custom("Avenir Next Regular", size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }

                Button(action: vm.generateDraftScriptsForAll) {
                    Label("Draft Subtitles", systemImage: "captions.bubble")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(vm.selectedURLs.isEmpty || vm.isGeneratingDescriptions || vm.isExporting)

                Button(action: vm.clearAll) {
                    Label("Clear All", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(vm.selectedURLs.isEmpty || vm.isExporting || vm.isGeneratingDescriptions)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Narration Planning")
                    .font(.custom("Avenir Next Demi Bold", size: 15))

                metricRow(label: "Timeline", value: vm.totalDurationText)
                metricRow(label: "Suggested voiceover", value: vm.recommendedNarrationRangeText)

                Picker("Subtitle timing", selection: $vm.subtitleTimingMode) {
                    ForEach(SubtitleTimingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Picker("Subtitle tone", selection: $vm.subtitleTone) {
                    ForEach(SubtitleTone.allCases) { tone in
                        Text(tone.rawValue).tag(tone)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Burn subtitles into video", isOn: $vm.burnInSubtitles)
                Toggle("Export SRT sidecar", isOn: $vm.exportSRT)
                Toggle("Export narration notes", isOn: $vm.exportScriptDocument)
            }
            .font(.custom("Avenir Next Regular", size: 13))

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Local AI")
                    .font(.custom("Avenir Next Demi Bold", size: 15))

                Text("Python: \(vm.pythonInterpreterPath.isEmpty ? "python3" : vm.pythonInterpreterPath)")
                    .font(.custom("Avenir Next Regular", size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Analyzer output folder")
                        .font(.custom("Avenir Next Demi Bold", size: 11))
                        .foregroundStyle(.secondary)
                    Text(vm.analyzerOutputDirectoryPath)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Output Folder", action: vm.openAnalyzerOutputFolder)
                        .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Description length")
                        Spacer()
                        Text("\(vm.descriptionMaxWords) words")
                            .foregroundStyle(.secondary)
                    }
                    .font(.custom("Avenir Next Regular", size: 12))

                    Stepper(value: $vm.descriptionMaxWords, in: 60...300, step: 10) {
                        Text(" ")
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Description interval")
                        Spacer()
                        Text(String(format: "%.0fs", vm.analysisSegmentSeconds))
                            .foregroundStyle(.secondary)
                    }
                    .font(.custom("Avenir Next Regular", size: 12))
                    Slider(value: $vm.analysisSegmentSeconds, in: 1...10, step: 1)
                }

                Picker("Description language", selection: $vm.descriptionLanguage) {
                    ForEach(DescriptionLanguage.allCases) { lang in
                        Text(lang.rawValue).tag(lang)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Description engine", selection: $vm.descriptionEngine) {
                    ForEach(ClipDescriptionBuilder.EngineId.allCases) { engine in
                        Text(engine.rawValue).tag(engine)
                    }
                }

                // SRT export/import lives in the top "Export Setup" section to avoid duplicate actions.

                Button(action: vm.useDetectedVenvPython) {
                    Label("Use Detected .venv", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(vm.isExporting || vm.isGeneratingDescriptions)

                Button(action: vm.choosePythonInterpreter) {
                    Label("Choose Python...", systemImage: "terminal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(vm.isExporting || vm.isGeneratingDescriptions)

                HStack(spacing: 8) {
                    Button(action: vm.enableGPUMemoryBoost) {
                        Label("Enable GPU Boost", systemImage: "lock.open")
                            .frame(maxWidth: .infinity)
                    }
                    Button(action: vm.resetGPUMemoryBoost) {
                        Label("Reset GPU Boost", systemImage: "lock.rotation")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(vm.isExporting || vm.isGeneratingDescriptions || vm.isConfiguringGPULimit)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Target limit")
                        Spacer()
                        Text("\(vm.configuredGPUMemoryLimitMB) MB")
                            .foregroundStyle(.secondary)
                    }
                    .font(.custom("Avenir Next Regular", size: 12))

                    Stepper(value: $vm.configuredGPUMemoryLimitMB, in: vm.gpuMemoryLimitRangeMB, step: 1024) {
                        Text("Adjust GPU limit")
                    }
                    .labelsHidden()
                    .disabled(vm.isExporting || vm.isGeneratingDescriptions || vm.isConfiguringGPULimit)

                    Text("Upper bound \(vm.gpuMemoryLimitRangeMB.upperBound) MB (matches current OS limit or physical RAM).")
                        .font(.custom("Avenir Next Regular", size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Current GPU memory limit")
                        Spacer()
                        if vm.isRefreshingGPULimit {
                            ProgressView()
                                .controlSize(.small)
                        } else if let current = vm.currentGPUMemoryLimitMB {
                            Text(current > 0 ? "\(current) MB" : "Default (0)")
                                .foregroundStyle(current > 0 ? .primary : .secondary)
                        } else {
                            Text("Unknown")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.custom("Avenir Next Regular", size: 12))

                    Text(vm.currentGPUMemoryLimitDetail)
                        .font(.custom("Avenir Next Regular", size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Restore: click Reset GPU Boost. That writes `iogpu.wired_limit_mb=0`.")
                        .font(.custom("Avenir Next Regular", size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: vm.refreshCurrentGPUMemoryLimit) {
                        Label("Refresh Current Limit", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.isExporting || vm.isGeneratingDescriptions || vm.isConfiguringGPULimit || vm.isRefreshingGPULimit)
                }
            }
            .font(.custom("Avenir Next Regular", size: 13))

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Debug")
                    .font(.custom("Avenir Next Demi Bold", size: 15))

                Toggle("Enable debug log", isOn: $vm.debugLoggingEnabled)

                HStack(spacing: 8) {
                    Button("Copy Log", action: vm.copyLogToClipboard)
                        .frame(maxWidth: .infinity)
                    Button("Save Log…", action: vm.saveLogToFile)
                        .frame(maxWidth: .infinity)
                }
                .disabled(vm.debugLog.isEmpty)

                Button("Clear Log", action: vm.clearLog)
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
                    .disabled(vm.debugLog.isEmpty)
            }
            .font(.custom("Avenir Next Regular", size: 13))

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Subtitle Style")
                    .font(.custom("Avenir Next Demi Bold", size: 15))

                Picker("Position", selection: $vm.subtitlePosition) {
                    ForEach(SubtitlePosition.allCases) { position in
                        Text(position.rawValue).tag(position)
                    }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 4) {
                    metricRow(label: "Text size", value: String(format: "%.2fx", vm.subtitleFontScale))
                    Slider(value: $vm.subtitleFontScale, in: 0.85...1.6, step: 0.05)
                }

                VStack(alignment: .leading, spacing: 4) {
                    metricRow(label: "Background", value: String(format: "%.0f%%", vm.subtitleBackgroundOpacity * 100))
                    Slider(value: $vm.subtitleBackgroundOpacity, in: 0.2...0.9, step: 0.05)
                }
            }
            .font(.custom("Avenir Next Regular", size: 13))

            Text("Tip: for silent vlog clips, keep each line to one idea and use Lower Third first. Move to Bottom Safe if the frame already has text-heavy detail.")
                .font(.custom("Avenir Next Regular", size: 12))
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 280, maxWidth: 280, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private var clipListView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Clip Timeline")
                    .font(.custom("Avenir Next Demi Bold", size: 18))
                Spacer()
            }
            .padding(14)

            Divider()

            if vm.selectedURLs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text("No clips selected")
                        .font(.custom("Avenir Next Medium", size: 15))
                    Text("Click Add Videos to start building your sequence.")
                        .font(.custom("Avenir Next Regular", size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(vm.selectedURLs.enumerated()), id: \.element) { index, url in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(.custom("Avenir Next Demi Bold", size: 13))
                                        .frame(width: 28, height: 28)
                                        .background(Color.accentColor.opacity(0.14), in: Circle())

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(url.lastPathComponent)
                                            .font(.custom("Avenir Next Medium", size: 14))
                                            .lineLimit(1)
                                            .textSelection(.enabled)
                                        HStack(spacing: 10) {
                                            Text(vm.durationText(for: url))
                                            Text(vm.targetWordsText(for: url))
                                        }
                                        .font(.custom("Avenir Next Regular", size: 11))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)

                                        keyframesView(for: url)

                                        let sceneNotes = vm.timestampedDescription(for: url)
                                        let isExpanded = expandedDescriptionURLs.contains(url)
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(alignment: .top) {
                                                Text("Scene Notes")
                                                    .font(.custom("Avenir Next Demi Bold", size: 11))
                                                    .foregroundStyle(.primary)
                                                Spacer()
                                                clipGenerateDescriptionButton(for: url)
                                            }
                                            if let timed = sceneNotes {
                                                Text(timed)
                                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                                    .lineSpacing(3)
                                                    .multilineTextAlignment(.leading)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .lineLimit(isExpanded ? nil : 10)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                    .textSelection(.enabled)
                                                Button(action: {
                                                    if isExpanded {
                                                        expandedDescriptionURLs.remove(url)
                                                    } else {
                                                        expandedDescriptionURLs.insert(url)
                                                    }
                                                }) {
                                                    Text(isExpanded ? "Show Less" : "Show More")
                                                        .font(.custom("Avenir Next Demi Bold", size: 11))
                                                }
                                                .buttonStyle(.plain)
                                                .foregroundStyle(.tint)
                                            } else {
                                                Text("No scene notes yet. Generate descriptions to analyze this clip.")
                                                    .font(.custom("Avenir Next Regular", size: 12))
                                                    .foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                    .textSelection(.enabled)
                                            }
                                        }
                                        .padding(10)
                                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                                        if let engine = vm.clipEngines[url] {
                                            Text("Engine: \(engine)")
                                                .font(.custom("Avenir Next Regular", size: 11))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .textSelection(.enabled)
                                        }
                                        if let warnings = vm.clipWarnings[url], let first = warnings.first, !first.isEmpty {
                                            Text("Note: \(first)")
                                                .font(.custom("Avenir Next Regular", size: 11))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                                .textSelection(.enabled)
                                        }
                                    }
                                    .task(id: url) {
                                        vm.ensureKeyframes(for: url)
                                    }

                                    Spacer()

                                    VStack(spacing: 10) {
                                        Button(action: { vm.moveUp(index: index) }) {
                                            Image(systemName: "arrow.up")
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(index == 0 || vm.isExporting || vm.isGeneratingDescriptions)

                                        Button(action: { vm.moveDown(index: index) }) {
                                            Image(systemName: "arrow.down")
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(index == vm.selectedURLs.count - 1 || vm.isExporting || vm.isGeneratingDescriptions)

                                        Button(role: .destructive, action: { vm.removeClip(at: index) }) {
                                            Image(systemName: "xmark.circle.fill")
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(vm.isExporting || vm.isGeneratingDescriptions)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Subtitle / voiceover line")
                                        .font(.custom("Avenir Next Demi Bold", size: 12))
                                    TextEditor(text: Binding(
                                        get: { vm.clipScripts[url] ?? "" },
                                        set: { vm.clipScripts[url] = $0 }
                                    ))
                                    .font(.custom("Avenir Next Regular", size: 13))
                                    .frame(minHeight: 64)
                                    .padding(6)
                                    .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                            .padding(14)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
                    }
                    .padding(14)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func clipGenerateDescriptionButton(for url: URL) -> some View {
        Button(action: { vm.generateDescription(for: url) }) {
            Label("Generate description", systemImage: "text.magnifyingglass")
                .font(.custom("Avenir Next Regular", size: 11))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(vm.isExporting || vm.isGeneratingDescriptions)
    }

    @ViewBuilder
    private func keyframesView(for url: URL) -> some View {
        KeyframesStripView(
            frames: vm.clipKeyframes[url] ?? [],
            placeholderCount: vm.previewKeyframeCount
        )
        .padding(.top, 2)
    }

    private struct KeyframesStripView: View {
        let frames: [NSImage]
        let placeholderCount: Int

        @State private var selectedIndex: Int? = nil
        @State private var zoom: Double = 1.0

        var body: some View {
            if frames.isEmpty {
                HStack(spacing: 8) {
                    ForEach(0..<max(1, min(placeholderCount, 6)), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(0.06))
                            .frame(width: 88, height: 52)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
                            )
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(frames.prefix(6).enumerated()), id: \.offset) { index, image in
                        Button {
                            selectedIndex = index
                            zoom = 1.0
                        } label: {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 88, height: 52)
                                .clipped()
                                .background(Color.black.opacity(0.06))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.black.opacity(0.12), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .popover(
                    isPresented: Binding(
                        get: { selectedIndex != nil },
                        set: { if !$0 { selectedIndex = nil } }
                    ),
                    arrowEdge: .bottom
                ) {
                    if let idx = selectedIndex, frames.indices.contains(idx) {
                        KeyframeZoomView(
                            frames: frames,
                            index: idx,
                            setIndex: { selectedIndex = $0 },
                            zoom: $zoom
                        )
                        .padding(12)
                    }
                }
            }
        }
    }

    private struct KeyframeZoomView: View {
        let frames: [NSImage]
        let index: Int
        let setIndex: (Int) -> Void
        @Binding var zoom: Double

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button("Prev") {
                        setIndex(max(0, index - 1))
                    }
                    .disabled(index == 0)

                    Button("Next") {
                        setIndex(min(frames.count - 1, index + 1))
                    }
                    .disabled(index >= frames.count - 1)

                    Spacer()

                    Text("\(index + 1)/\(frames.count)")
                        .foregroundStyle(.secondary)
                }
                .font(.custom("Avenir Next Regular", size: 12))

                ScrollView([.vertical, .horizontal]) {
                    Image(nsImage: frames[index])
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(zoom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(10)
                }
                .frame(width: 560, height: 360)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 10) {
                    Text("Zoom")
                        .font(.custom("Avenir Next Regular", size: 12))
                    Slider(value: $zoom, in: 0.8...4.0, step: 0.1)
                    Text(String(format: "%.1fx", zoom))
                        .font(.custom("Avenir Next Regular", size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
            }
        }
    }

    private var footerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Label(vm.statusMessage, systemImage: (vm.isExporting || vm.isGeneratingDescriptions) ? "clock.arrow.circlepath" : "checkmark.seal")
                    .font(.custom("Avenir Next Regular", size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Button(action: { isShowingPreview = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.circle")
                        Text("Preview")
                            .font(.custom("Avenir Next Demi Bold", size: 14))
                    }
                    .frame(minWidth: 140)
                }
                .buttonStyle(.bordered)
                .disabled(vm.selectedURLs.isEmpty || vm.isExporting || vm.isGeneratingDescriptions)

                Button(action: vm.exportMergedVideo) {
                    HStack(spacing: 8) {
                        if vm.isExporting {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                        Text(vm.isExporting ? "Exporting..." : "Export Vlog Package")
                            .font(.custom("Avenir Next Demi Bold", size: 14))
                    }
                    .frame(minWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.selectedURLs.isEmpty || vm.isExporting || vm.isGeneratingDescriptions)

                Button(action: vm.exportProxyVideoForAI) {
                    HStack(spacing: 8) {
                        Image(systemName: "paperplane")
                        Text("Export Proxy")
                            .font(.custom("Avenir Next Demi Bold", size: 14))
                    }
                    .frame(minWidth: 160)
                }
                .buttonStyle(.bordered)
                .disabled(vm.selectedURLs.isEmpty || vm.isExporting || vm.isGeneratingDescriptions)
            }

            if vm.isGeneratingDescriptions || vm.isConfiguringGPULimit || !vm.recentDebugLines.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if let detail = vm.statusDetail, !detail.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(detail)
                                .font(.custom("Avenir Next Regular", size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !vm.recentDebugLines.isEmpty {
                        Text(vm.isGeneratingDescriptions || vm.isConfiguringGPULimit ? "Live Analyzer Output" : "Recent Analyzer Output")
                            .font(.custom("Avenir Next Demi Bold", size: 11))
                            .foregroundStyle(.secondary)
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(vm.recentDebugLines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 112)
                        .padding(10)
                        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sheet(isPresented: $isShowingPreview) {
            PreviewPlayerSheet(
                inputURLs: vm.selectedURLs,
                subtitleEntries: vm.previewActiveEntries(),
                subtitleStyle: vm.previewSubtitleStyle()
            )
        }
        .sheet(isPresented: $isShowingClaudeSubtitleSheet) {
            ClaudeSubtitleComposerSheet(vm: vm)
        }
    }
}

struct ClaudeSubtitleComposerSheet: View {
    @ObservedObject var vm: VideoMergeViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude Final Subtitle")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Preview the prompt and YAML input before generating the final SRT.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
            }

            HStack(spacing: 8) {
                Button("Use Current YAML", action: vm.resetClaudeSubtitleYAMLToCurrent)
                Button("Choose YAML…", action: vm.chooseClaudeSubtitleYAML)
                Spacer()
                Text("Source: \(vm.claudeSubtitleSourceLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .buttonStyle(.bordered)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt")
                        .font(.custom("Avenir Next Demi Bold", size: 12))
                    TextEditor(text: $vm.claudeSubtitlePrompt)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .frame(minHeight: 220)
                        .padding(8)
                        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("YAML Input")
                        .font(.custom("Avenir Next Demi Bold", size: 12))
                    TextEditor(text: $vm.claudeSubtitleYAML)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .frame(minHeight: 220)
                        .padding(8)
                        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)

                Button(action: {
                    vm.generateClaudeSubtitleAndImport()
                }) {
                    HStack(spacing: 8) {
                        if vm.isGeneratingClaudeSubtitle {
                            ProgressView().scaleEffect(0.7)
                        }
                        Text(vm.isGeneratingClaudeSubtitle ? "Generating..." : "Generate")
                    }
                    .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isGeneratingClaudeSubtitle || vm.claudeSubtitlePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.claudeSubtitleYAML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 980, minHeight: 620)
    }
}

struct PreviewPlayerSheet: View {
    let inputURLs: [URL]
    let subtitleEntries: [TimedScriptEntry]
    let subtitleStyle: SubtitleStyle

    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var showSubtitles = true
    @State private var activeSubtitle = ""
    @State private var timeObserverToken: Any? = nil

    private var sortedEntries: [TimedScriptEntry] {
        subtitleEntries.sorted { CMTimeCompare($0.start, $1.start) < 0 }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("Preview")
                    .font(.custom("Avenir Next Demi Bold", size: 16))
                Spacer()
                Toggle("Show subtitles", isOn: $showSubtitles)
                    .toggleStyle(.switch)
                    .font(.custom("Avenir Next Regular", size: 12))
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            Divider()

            ZStack {
                PlayerViewRepresentable(player: player)
                    .frame(minHeight: 480)

                if showSubtitles, !activeSubtitle.isEmpty {
                    GeometryReader { proxy in
                        subtitleOverlay(text: activeSubtitle, size: proxy.size)
                    }
                    .allowsHitTesting(false)
                }

                if isLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Building preview…")
                            .font(.custom("Avenir Next Regular", size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(14)

            if let errorMessage {
                Text(errorMessage)
                    .font(.custom("Avenir Next Regular", size: 12))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
        .frame(minWidth: 880, minHeight: 620)
        .onAppear {
            startPreview()
        }
        .onDisappear {
            stopPreview()
        }
    }

    private func startPreview() {
        isLoading = true
        errorMessage = nil
        activeSubtitle = ""

        Task {
            do {
                let item = try await VideoCombiner.makePreviewPlayerItem(
                    inputURLs: inputURLs,
                    subtitleStyle: subtitleStyle
                )
                await MainActor.run {
                    player.replaceCurrentItem(with: item)
                    player.play()
                    attachTimeObserver()
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Preview failed: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func stopPreview() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func attachTimeObserver() {
        if timeObserverToken != nil { return }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            activeSubtitle = subtitleText(at: time)
        }
    }

    private func subtitleText(at time: CMTime) -> String {
        let t = CMTimeGetSeconds(time)
        if t.isNaN || t.isInfinite { return "" }
        for entry in sortedEntries {
            let start = CMTimeGetSeconds(entry.start)
            let end = CMTimeGetSeconds(entry.start + entry.duration)
            if t >= start && t <= end {
                return entry.text
            }
        }
        return ""
    }

    @ViewBuilder
    private func subtitleOverlay(text: String, size: CGSize) -> some View {
        let fontSize = max(min(size.width, size.height) * 0.03 * subtitleStyle.fontScale, 16)
        let horizontalInset = size.width * 0.08
        let containerWidth = size.width - (horizontalInset * 2)
        let estimatedHeight = max(fontSize * 3.2, size.height * 0.12)
        let originY = max(size.height * subtitleStyle.position.verticalRatio - (estimatedHeight / 2), 12)

        VStack {
            Text(text)
                .font(.system(size: fontSize, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(width: containerWidth)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(subtitleStyle.backgroundOpacity))
                )
            Spacer()
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .padding(.top, originY)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.12), value: text)
    }
}

private struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = player
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
