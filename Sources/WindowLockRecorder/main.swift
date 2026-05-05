import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

struct RecordableWindow: Hashable {
    let id: UInt32
    let title: String
    let appName: String
    let pid: pid_t
    let frame: CGRect
    let window: SCWindow

    var displayName: String {
        let titleText = title.isEmpty ? "Untitled" : title
        return "\(appName) - \(titleText) (\(Int(frame.width))x\(Int(frame.height)))"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let windowPicker = NSPopUpButton()
    private let refreshButton = NSButton(title: "Refresh Windows", target: nil, action: nil)
    private let chooseOutputButton = NSButton(title: "Choose Output...", target: nil, action: nil)
    private let outputField = NSTextField()
    private let durationField = NSTextField()
    private let fpsField = NSTextField()
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Ready.")
    private var windows: [RecordableWindow] = []
    private var recorder: WindowRecorder?
    private var stopTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        Task { await refreshWindows() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        chooseOutputButton.target = self
        chooseOutputButton.action = #selector(chooseOutputClicked)
        recordButton.target = self
        recordButton.action = #selector(recordClicked)
        recordButton.bezelColor = .systemBlue

        outputField.stringValue = defaultOutputPath()
        outputField.placeholderString = "Output .mov path"
        durationField.placeholderString = "blank = until Stop"
        fpsField.stringValue = "60"

        let form = NSGridView(views: [
            [label("Window"), windowPicker, refreshButton],
            [label("Output"), outputField, chooseOutputButton],
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

    private func defaultOutputPath() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return "\(NSHomeDirectory())/Desktop/window-lock-\(formatter.string(from: Date())).mov"
    }

    @objc private func refreshClicked() {
        Task { await refreshWindows() }
    }

    @objc private func chooseOutputClicked() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = URL(fileURLWithPath: outputField.stringValue).lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        if panel.runModal() == .OK, let url = panel.url {
            outputField.stringValue = url.path
        }
    }

    @objc private func recordClicked() {
        if recorder != nil {
            Task { await stopRecording() }
            return
        }
        Task { await startRecording() }
    }

    private func refreshWindows() async {
        do {
            statusLabel.stringValue = "Loading windows..."
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let appPID = ProcessInfo.processInfo.processIdentifier
            windows = content.windows
                .filter { candidate in
                    candidate.windowLayer == 0
                    && candidate.frame.width >= 80
                    && candidate.frame.height >= 80
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
                        window: candidate
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.appName == rhs.appName {
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
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
        let outputURL = URL(fileURLWithPath: outputField.stringValue)
        let fps = max(1, min(Int(fpsField.stringValue) ?? 60, 120))
        let duration = TimeInterval(durationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))

        do {
            let recorder = WindowRecorder()
            self.recorder = recorder
            setRecordingUI(true)
            statusLabel.stringValue = "Recording \(selected.appName)..."
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
        outputField.isEnabled = !isRecording
        chooseOutputButton.isEnabled = !isRecording
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
        let width = max(2, Int((window.frame.width * scale).rounded(.up)))
        let height = max(2, Int((window.frame.height * scale).rounded(.up)))

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
        configuration.showsCursor = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.queueDepth = 6
        if #available(macOS 14.0, *) {
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
