import AppKit
@preconcurrency import AVFoundation
import Carbon
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import ScreenCaptureKit

private func fourCharacterCode(_ string: String) -> OSType {
    string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
}

@MainActor
private enum HotKeyDispatcher {
    static var action: (@MainActor () -> Void)?

    static func trigger() {
        action?()
    }
}

@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) throws {
        HotKeyDispatcher.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                Task { @MainActor in
                    HotKeyDispatcher.trigger()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )
        guard installStatus == noErr else {
            throw HotKeyError.installFailed(installStatus)
        }

        let hotKeyID = EventHotKeyID(signature: fourCharacterCode("WLR6"), id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            throw HotKeyError.registerFailed(registerStatus)
        }
    }

    func invalidate() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        HotKeyDispatcher.action = nil
    }
}

enum HotKeyError: Error, LocalizedError {
    case installFailed(OSStatus)
    case registerFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .installFailed(let status):
            return "Could not install hotkey handler: \(status)"
        case .registerFailed(let status):
            return "Could not register Cmd-Shift-6: \(status)"
        }
    }
}

struct RecordableWindow: Hashable {
    let id: UInt32
    let title: String
    let appName: String
    let pid: pid_t
    let frame: CGRect
    let layer: Int
    let window: SCWindow

    var displayName: String {
        let titleText = title.isEmpty ? "Untitled" : title
        return "\(appName) - \(titleText) (\(Int(frame.width))x\(Int(frame.height)), layer \(layer), id \(id))"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let windowPicker = NSPopUpButton()
    private let refreshButton = NSButton(title: "Refresh Windows", target: nil, action: nil)
    private let durationField = NSTextField()
    private let fpsField = NSTextField()
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Ready.")
    private var windows: [RecordableWindow] = []
    private var recorder: WindowRecorder?
    private var stopTask: Task<Void, Never>?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        installHotKey()
        Task { await refreshWindows() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.invalidate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.hide(nil)
        return false
    }

    private func buildWindow() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Window Lock Recorder")
        title.font = .boldSystemFont(ofSize: 20)

        let subtitle = NSTextField(labelWithString: "Record a specific macOS window using ScreenCaptureKit.")
        subtitle.textColor = .secondaryLabelColor

        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        recordButton.target = self
        recordButton.action = #selector(recordClicked)
        recordButton.bezelColor = .systemBlue

        durationField.placeholderString = "blank = until Stop"
        fpsField.stringValue = "60"

        let form = NSGridView(views: [
            [label("Window"), windowPicker, refreshButton],
            [label("Duration"), durationField, label("seconds")],
            [label("FPS"), fpsField, label("1-120")]
        ])
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 520
        form.rowSpacing = 10
        form.columnSpacing = 10

        let controls = NSStackView(views: [recordButton, statusLabel])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 12

        let stack = NSStackView(views: [title, subtitle, form, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 260),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WindowLockRecorder"
        window.delegate = self
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func outputURL(for selected: RecordableWindow) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let app = sanitizedFilenameComponent(selected.appName)
        let title = sanitizedFilenameComponent(selected.title.isEmpty ? "untitled" : selected.title)
        let name = "window-lock-\(formatter.string(from: Date()))-\(app)-\(title)-\(selected.id).mov"
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop")
            .appendingPathComponent(name)
    }

    private func sanitizedFilenameComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if collapsed.isEmpty {
            return "window"
        }
        return String(collapsed.prefix(48))
    }

    @objc private func refreshClicked() {
        Task { await refreshWindows() }
    }

    @objc private func recordClicked() {
        toggleRecording()
    }

    private func toggleWindowVisibility() {
        if NSApp.isHidden || !window.isVisible {
            NSApp.unhide(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.hide(nil)
        }
    }

    private func toggleRecording() {
        if recorder != nil {
            Task { await stopRecording() }
            return
        }
        Task { await startRecording() }
    }

    private func installHotKey() {
        do {
            hotKey = try GlobalHotKey(
                keyCode: UInt32(kVK_ANSI_6),
                modifiers: UInt32(cmdKey | shiftKey)
            ) { [weak self] in
                self?.toggleWindowVisibility()
            }
        } catch {
            statusLabel.stringValue = "Hotkey unavailable: \(error.localizedDescription)"
        }
    }

    private func refreshWindows() async {
        do {
            statusLabel.stringValue = "Loading windows..."
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let appPID = ProcessInfo.processInfo.processIdentifier
            windows = content.windows
                .filter { candidate in
                    candidate.frame.width >= 24
                    && candidate.frame.height >= 24
                    && candidate.owningApplication?.processID != appPID
                    && candidate.owningApplication != nil
                }
                .map { candidate in
                    RecordableWindow(
                        id: candidate.windowID,
                        title: candidate.title ?? "",
                        appName: candidate.owningApplication?.applicationName ?? "Unknown",
                        pid: candidate.owningApplication?.processID ?? 0,
                        frame: candidate.frame,
                        layer: candidate.windowLayer,
                        window: candidate
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.appName == rhs.appName && lhs.layer == rhs.layer {
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    }
                    if lhs.appName == rhs.appName {
                        return lhs.layer < rhs.layer
                    }
                    return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
                }

            windowPicker.removeAllItems()
            for item in windows {
                windowPicker.addItem(withTitle: item.displayName)
            }
            statusLabel.stringValue = windows.isEmpty ? "No recordable windows found." : "Found \(windows.count) windows."
        } catch {
            statusLabel.stringValue = "Window list failed: \(error.localizedDescription)"
        }
    }

    private func startRecording() async {
        guard windowPicker.indexOfSelectedItem >= 0, windowPicker.indexOfSelectedItem < windows.count else {
            statusLabel.stringValue = "Pick a window first."
            return
        }
        let selected = windows[windowPicker.indexOfSelectedItem]
        let outputURL = outputURL(for: selected)
        let fps = max(1, min(Int(fpsField.stringValue) ?? 60, 120))
        let duration = TimeInterval(durationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))

        do {
            let recorder = WindowRecorder()
            self.recorder = recorder
            setRecordingUI(true)
            statusLabel.stringValue = "Recording \(selected.appName) to \(outputURL.lastPathComponent)..."
            try await recorder.start(window: selected.window, outputURL: outputURL, fps: fps)

            if let duration, duration > 0 {
                stopTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(duration))
                    await self?.stopRecording()
                }
            }
        } catch {
            self.recorder = nil
            setRecordingUI(false)
            statusLabel.stringValue = "Record failed: \(error.localizedDescription)"
        }
    }

    private func stopRecording() async {
        stopTask?.cancel()
        stopTask = nil
        guard let recorder else { return }
        self.recorder = nil
        statusLabel.stringValue = "Stopping..."
        do {
            let url = try await recorder.stop()
            setRecordingUI(false)
            statusLabel.stringValue = "Saved \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            setRecordingUI(false)
            statusLabel.stringValue = "Stop failed: \(error.localizedDescription)"
        }
    }

    private func setRecordingUI(_ isRecording: Bool) {
        recordButton.title = isRecording ? "Stop" : "Record"
        refreshButton.isEnabled = !isRecording
        windowPicker.isEnabled = !isRecording
        durationField.isEnabled = !isRecording
        fpsField.isEnabled = !isRecording
    }
}

final class WindowRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "WindowLockRecorder.capture")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstPTS: CMTime?
    private var outputURL: URL?
    private var finishContinuation: CheckedContinuation<URL, Error>?
    private var didAppendFrame = false

    @MainActor
    func start(window: SCWindow, outputURL: URL, fps: Int) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = max(Double(filter.pointPixelScale), 1.0)
        let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let canvas = Self.nonScalingCanvas(for: window, scale: scale, content: content)
        let width = canvas.width
        let height = canvas.height

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 8
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else {
            throw RecorderError.writerInputRejected
        }
        writer.add(input)

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = false
        configuration.showsCursor = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.queueDepth = 6
        if #available(macOS 14.0, *) {
            configuration.preservesAspectRatio = true
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreGlobalClipSingleWindow = true
            configuration.captureResolution = .best
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        self.stream = stream
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.firstPTS = nil
        self.outputURL = outputURL
        self.didAppendFrame = false

        try await stream.startCapture()
    }

    private static func nonScalingCanvas(
        for window: SCWindow,
        scale: Double,
        content: SCShareableContent?
    ) -> (width: Int, height: Int) {
        let initialWidth = max(2, Int((window.frame.width * scale).rounded(.up)))
        let initialHeight = max(2, Int((window.frame.height * scale).rounded(.up)))

        guard let display = display(containing: window, in: content?.displays ?? []) else {
            return (initialWidth, initialHeight)
        }

        let displayPixelWidth = Int(CGDisplayPixelsWide(display.displayID))
        let displayPixelHeight = Int(CGDisplayPixelsHigh(display.displayID))
        let fallbackWidth = Int((display.frame.width * scale).rounded(.up))
        let fallbackHeight = Int((display.frame.height * scale).rounded(.up))
        let canvasWidth = max(displayPixelWidth, fallbackWidth, initialWidth, 2)
        let canvasHeight = max(displayPixelHeight, fallbackHeight, initialHeight, 2)

        return (canvasWidth, canvasHeight)
    }

    private static func display(containing window: SCWindow, in displays: [SCDisplay]) -> SCDisplay? {
        let frame = window.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let display = displays.first(where: { $0.frame.contains(center) }) {
            return display
        }

        return displays.max { lhs, rhs in
            intersectionArea(lhs.frame, frame) < intersectionArea(rhs.frame, frame)
        }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    func stop() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.finishContinuation = continuation
                let stream = self.stream
                self.stream = nil
                Task {
                    if let stream {
                        try? await stream.stopCapture()
                    }
                    self.queue.async {
                        self.finishWriting()
                    }
                }
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        queue.async {
            self.append(sampleBuffer)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            self.finishContinuation?.resume(throwing: error)
            self.finishContinuation = nil
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer) {
        guard let writer, let input, let adaptor else { return }
        guard CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstPTS == nil {
            firstPTS = pts
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: .zero)
        }
        guard let firstPTS, input.isReadyForMoreMediaData else { return }
        let relativePTS = CMTimeSubtract(pts, firstPTS)
        if adaptor.append(pixelBuffer, withPresentationTime: relativePTS) {
            didAppendFrame = true
        }
    }

    private func finishWriting() {
        guard let writer, let input, let outputURL else {
            finishContinuation?.resume(throwing: RecorderError.notRecording)
            finishContinuation = nil
            return
        }

        self.writer = nil
        self.input = nil
        self.adaptor = nil
        self.firstPTS = nil
        self.outputURL = nil

        if !didAppendFrame {
            finishContinuation?.resume(throwing: RecorderError.noFrames)
            finishContinuation = nil
            return
        }

        input.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            self.queue.async {
                if writer.status == .completed {
                    self.finishContinuation?.resume(returning: outputURL)
                } else {
                    self.finishContinuation?.resume(throwing: writer.error ?? RecorderError.finishFailed)
                }
                self.finishContinuation = nil
            }
        }
    }
}

enum RecorderError: Error, LocalizedError {
    case writerInputRejected
    case notRecording
    case noFrames
    case finishFailed

    var errorDescription: String? {
        switch self {
        case .writerInputRejected:
            return "AVAssetWriter rejected the video input settings."
        case .notRecording:
            return "No recording is active."
        case .noFrames:
            return "No frames were captured. Check Screen Recording permission and keep the target window visible."
        case .finishFailed:
            return "AVAssetWriter failed to finish the movie."
        }
    }
}

@main
struct WindowLockRecorderApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
