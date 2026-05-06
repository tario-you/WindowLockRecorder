import AppKit
@preconcurrency import AVFoundation
import Carbon
import CoreGraphics
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Darwin
import Foundation
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
        let name = appName.isEmpty ? titleText : "\(appName) - \(titleText)"
        if name.count <= 64 {
            return name
        }
        return "\(name.prefix(30))...\(name.suffix(30))"
    }
}

@MainActor
final class RoundedPanelView: NSView {
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.045, alpha: 0.98).cgColor
        layer?.cornerRadius = 18
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        layer?.borderWidth = 1
        layer?.masksToBounds = true
    }
}

final class FloatingOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private let windowPicker = NSPopUpButton()
    private let refreshButton = NSButton(title: "", target: nil, action: nil)
    private let durationField = NSTextField()
    private let fpsField = NSTextField()
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)
    private let permissionsButton = NSButton(title: "Permissions", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Ready.")
    private let windowSectionLabel = NSTextField(labelWithString: "Window: loading...")
    private let durationSectionLabel = NSTextField(labelWithString: "Duration (sec, blank = until stop)")
    private let fpsSectionLabel = NSTextField(labelWithString: "FPS (1-120)")
    private var windows: [RecordableWindow] = []
    private var recorder: WindowRecorder?
    private var stopTask: Task<Void, Never>?
    private var hotKey: GlobalHotKey?
    private var statusItem: NSStatusItem?
    private var windowVisibilityItem: NSMenuItem?
    private var singleInstanceLockFileDescriptor: Int32 = -1
    private var didArmRelaunchAfterTermination = false
    private var relaunchJobLabel: String?
    private var relaunchArmDate: Date?
    private let relaunchArmTimeoutSeconds = 120

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireSingleInstanceLock() else {
            NSApp.terminate(nil)
            return
        }

        cleanupStaleRelaunchJobs()
        installMainMenu()
        installStatusItem()
        buildWindow()
        installHotKey()
        Task { await refreshWindows() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.invalidate()
        if singleInstanceLockFileDescriptor >= 0 {
            flock(singleInstanceLockFileDescriptor, LOCK_UN)
            close(singleInstanceLockFileDescriptor)
            singleInstanceLockFileDescriptor = -1
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.hide(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if window?.isVisible == false {
            showWindow()
        }
    }

    private func acquireSingleInstanceLock() -> Bool {
        let lockURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dev.local.WindowLockRecorder.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return true
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            singleInstanceLockFileDescriptor = descriptor
            return true
        }

        close(descriptor)
        NSWorkspace.shared.open(Bundle.main.bundleURL)
        return false
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        mainMenu.addItem(windowMenuItem)

        let appMenu = NSMenu(title: "WindowLockRecorder")
        appMenu.addItem(withTitle: "Hide WindowLockRecorder", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.items.last?.target = NSApp
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit WindowLockRecorder", action: #selector(quitApp), keyEquivalent: "q")
        appMenu.items.last?.target = self
        appMenuItem.submenu = appMenu

        let windowMenu = NSMenu(title: "Window")
        let closeItem = NSMenuItem(title: "Close Window", action: #selector(closeWindow), keyEquivalent: "w")
        closeItem.target = self
        windowMenu.addItem(closeItem)
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func closeWindow() {
        NSApp.hide(nil)
    }

    @objc private func quitApp() {
        cancelRelaunchAfterTermination()
        NSApp.terminate(nil)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = menuBarIcon()
            button.title = button.image == nil ? "WLR" : ""
            button.toolTip = "WindowLockRecorder"
        }

        let menu = NSMenu()
        menu.delegate = self

        let visibilityItem = NSMenuItem(title: "Show Window", action: #selector(toggleWindowFromMenu), keyEquivalent: "")
        visibilityItem.target = self
        menu.addItem(visibilityItem)
        windowVisibilityItem = visibilityItem

        menu.addItem(.separator())

        let permissionItem = NSMenuItem(title: "Request Permissions", action: #selector(permissionsClicked), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        let refreshItem = NSMenuItem(title: "Refresh Windows", action: #selector(refreshClicked), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit WindowLockRecorder", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        updateStatusMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateStatusMenu()
    }

    @objc private func toggleWindowFromMenu() {
        toggleWindowVisibility()
    }

    private func updateStatusMenu() {
        let isShown = window?.isVisible == true && !NSApp.isHidden
        windowVisibilityItem?.title = isShown ? "Hide Window" : "Show Window"
    }

    private func menuBarIcon() -> NSImage? {
        guard let iconURL = Bundle.main.url(forResource: "ScreenshotMonitor", withExtension: "svg"),
              let image = NSImage(contentsOf: iconURL) else {
            return nil
        }

        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    private func buildWindow() {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        recordButton.target = self
        recordButton.action = #selector(recordClicked)
        permissionsButton.target = self
        permissionsButton.action = #selector(permissionsClicked)

        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh Windows")
        refreshButton.imagePosition = .imageOnly
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.toolTip = "Refresh Windows"

        windowPicker.addItem(withTitle: "Select a window")
        windowPicker.font = .systemFont(ofSize: 13, weight: .regular)
        windowPicker.controlSize = .regular
        windowPicker.cell?.lineBreakMode = .byTruncatingMiddle
        windowPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        durationField.placeholderString = "∞"
        fpsField.stringValue = "120"
        for field in [durationField, fpsField] {
            field.font = .systemFont(ofSize: 16, weight: .regular)
            field.controlSize = .regular
            field.bezelStyle = .roundedBezel
        }

        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.font = .systemFont(ofSize: 10, weight: .regular)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2

        for label in [windowSectionLabel, durationSectionLabel, fpsSectionLabel] {
            styleSectionLabel(label)
        }

        recordButton.bezelStyle = .rounded
        recordButton.font = .systemFont(ofSize: 13, weight: .regular)
        recordButton.controlSize = .regular
        permissionsButton.bezelStyle = .rounded
        permissionsButton.font = .systemFont(ofSize: 13, weight: .regular)
        permissionsButton.controlSize = .regular

        let panel = RoundedPanelView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(panel)

        let windowHeader = NSStackView(views: [windowSectionLabel, flexibleSpacer(), refreshButton])
        windowHeader.orientation = .horizontal
        windowHeader.alignment = .centerY
        windowHeader.spacing = 8

        let windowStack = NSStackView(views: [windowHeader, windowPicker])
        windowStack.orientation = .vertical
        windowStack.alignment = .leading
        windowStack.spacing = 7

        let durationStack = NSStackView(views: [
            durationSectionLabel,
            durationField
        ])
        durationStack.orientation = .vertical
        durationStack.alignment = .leading
        durationStack.spacing = 7

        let fpsStack = NSStackView(views: [
            fpsSectionLabel,
            fpsField
        ])
        fpsStack.orientation = .vertical
        fpsStack.alignment = .leading
        fpsStack.spacing = 7

        let fieldRow = NSStackView(views: [durationStack, fpsStack])
        fieldRow.orientation = .horizontal
        fieldRow.alignment = .top
        fieldRow.distribution = .fillEqually
        fieldRow.spacing = 16

        let controlRow = NSStackView(views: [recordButton, permissionsButton])
        controlRow.orientation = .horizontal
        controlRow.alignment = .centerY
        controlRow.distribution = .fillProportionally
        controlRow.spacing = 8

        let stack = NSStackView(views: [windowStack, fieldRow, controlRow, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)

        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            panel.topAnchor.constraint(equalTo: content.topAnchor),
            panel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: panel.bottomAnchor, constant: -20),
            windowHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            windowPicker.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fieldRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            controlRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 40),
            refreshButton.heightAnchor.constraint(equalToConstant: 32),
            durationField.heightAnchor.constraint(equalToConstant: 32),
            fpsField.heightAnchor.constraint(equalToConstant: 32),
            durationField.widthAnchor.constraint(equalTo: durationStack.widthAnchor),
            fpsField.widthAnchor.constraint(equalTo: fpsStack.widthAnchor),
            recordButton.heightAnchor.constraint(equalToConstant: 34),
            permissionsButton.heightAnchor.constraint(equalToConstant: 34),
            permissionsButton.widthAnchor.constraint(equalToConstant: 112),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        window = FloatingOverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 370, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "WindowLockRecorder"
        window.delegate = self
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentMinSize = NSSize(width: 370, height: 240)
        window.contentMaxSize = NSSize(width: 370, height: 240)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func styleSectionLabel(_ field: NSTextField) {
        field.textColor = .tertiaryLabelColor
        field.font = .systemFont(ofSize: 10, weight: .regular)
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func setStatus(_ message: String, isError: Bool = false) {
        statusLabel.textColor = isError ? .systemRed : .tertiaryLabelColor
        statusLabel.stringValue = message
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

    @objc private func permissionsClicked() {
        requestScreenRecordingPermission()
    }

    private func toggleWindowVisibility() {
        if NSApp.isHidden || !window.isVisible || !NSApp.isActive {
            showWindow()
        } else {
            NSApp.hide(nil)
        }
    }

    private func showWindow() {
        NSApp.unhide(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func toggleRecording() {
        if recorder != nil {
            Task { await stopRecording() }
            return
        }
        Task { await startRecording() }
    }

    private func requestScreenRecordingPermission() {
        if CGPreflightScreenCaptureAccess() {
            setStatus("Screen Recording permission already granted.")
            Task { await refreshWindows() }
            return
        }

        armRelaunchAfterTerminationIfNeeded()

        if CGRequestScreenCaptureAccess() {
            setStatus("Screen Recording permission granted. Refreshing windows...")
            Task { await refreshWindows() }
            return
        }

        setStatus("Screen Recording permission not granted. Opened System Settings.", isError: true)
        openScreenRecordingSettings()
    }

    private func openScreenRecordingSettings() {
        armRelaunchAfterTerminationIfNeeded()

        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func armRelaunchAfterTerminationIfNeeded() {
        if didArmRelaunchAfterTermination {
            if let relaunchArmDate,
               Date().timeIntervalSince(relaunchArmDate) < TimeInterval(relaunchArmTimeoutSeconds) {
                return
            }
            cancelRelaunchAfterTermination()
        }

        let processID = ProcessInfo.processInfo.processIdentifier
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let bundlePath = bundleURL.path.removingPercentEncoding ?? bundleURL.path
        let installedBundlePath = "/Applications/WindowLockRecorder.app"
        let relaunchBundlePath = FileManager.default.fileExists(atPath: installedBundlePath)
            ? installedBundlePath
            : bundlePath
        let executableName = Bundle.main.executableURL?.lastPathComponent ?? "WindowLockRecorder"

        guard bundlePath.hasSuffix(".app") else {
            return
        }

        didArmRelaunchAfterTermination = true
        relaunchArmDate = Date()

        let label = "dev.local.WindowLockRecorder.relaunch.\(processID)"
        let escapedRelaunchBundlePath = shellQuoted(relaunchBundlePath)
        let escapedExecutableName = shellQuoted(executableName)
        let script = """
        trap '' HUP TERM
        log=/tmp/dev.local.WindowLockRecorder.relaunch.log
        echo "$(date '+%Y-%m-%d %H:%M:%S') launchd armed pid \(processID) bundle \(escapedRelaunchBundlePath)" >> "$log"
        deadline=$(( $(date +%s) + \(relaunchArmTimeoutSeconds) ))
        while kill -0 \(processID) 2>/dev/null; do
          if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') relaunch expired; app never quit" >> "$log"
            exit 0
          fi
          sleep 0.2
        done
        sleep 1.5
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
          if /usr/bin/pgrep -x \(escapedExecutableName) >/dev/null 2>&1; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') relaunched" >> "$log"
            exit 0
          fi
          echo "$(date '+%Y-%m-%d %H:%M:%S') relaunch attempt $attempt" >> "$log"
          /usr/bin/open -n -F \(escapedRelaunchBundlePath) >> "$log" 2>&1
          sleep 0.75
        done
        """

        if submitLaunchdRelauncher(script: script, label: label) {
            relaunchJobLabel = label
            return
        }

        writeRelaunchLog("launchctl submit failed; relaunch not armed")
        didArmRelaunchAfterTermination = false
        relaunchArmDate = nil
    }

    private func submitLaunchdRelauncher(script: String, label: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "submit",
            "-l", label,
            "-o", "/tmp/dev.local.WindowLockRecorder.relaunch.log",
            "-e", "/tmp/dev.local.WindowLockRecorder.relaunch.log",
            "--",
            "/bin/sh",
            "-c",
            script
        ]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            writeRelaunchLog("launchctl submit error: \(error.localizedDescription)")
            return false
        }
    }

    private func cancelRelaunchAfterTermination() {
        if let relaunchJobLabel {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["remove", relaunchJobLabel]
            if (try? process.run()) != nil {
                process.waitUntilExit()
            }
            writeRelaunchLog("cancelled relaunch job \(relaunchJobLabel)")
        }

        relaunchJobLabel = nil
        relaunchArmDate = nil
        didArmRelaunchAfterTermination = false
    }

    private func cleanupStaleRelaunchJobs() {
        let script = """
        launchctl list | awk '/dev\\.local\\.WindowLockRecorder\\.(relaunch|launchctl-test)/ { print $3 }' | while read -r label; do
          [ -n "$label" ] && launchctl remove "$label" 2>/dev/null || true
        done
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        if (try? process.run()) != nil {
            process.waitUntilExit()
        }
    }

    private func writeRelaunchLog(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/dev.local.WindowLockRecorder.relaunch.log")
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func shellQuoted(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
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
            setStatus("Hotkey unavailable: \(error.localizedDescription)", isError: true)
        }
    }

    private func refreshWindows() async {
        do {
            windowSectionLabel.stringValue = "Window: loading..."
            setStatus("Loading windows...")
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
            if windows.isEmpty {
                windowPicker.addItem(withTitle: "Select a window")
            } else {
                for item in windows {
                    windowPicker.addItem(withTitle: item.displayName)
                }
            }
            if windows.isEmpty {
                windowSectionLabel.stringValue = "Window: none found"
                setStatus("No recordable windows found.")
            } else {
                windowSectionLabel.stringValue = "Window: found \(windows.count)"
                setStatus("")
            }
        } catch {
            windowPicker.removeAllItems()
            windowPicker.addItem(withTitle: "Select a window")
            windowSectionLabel.stringValue = "Window: permission needed"
            setStatus(windowListErrorMessage(for: error), isError: true)
        }
    }

    private func windowListErrorMessage(for error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("TCC") || message.localizedCaseInsensitiveContains("declined") {
            return "Screen Recording permission is required. Click Permissions, then Refresh."
        }
        return "Window list failed: \(message)"
    }

    private func startRecording() async {
        guard windowPicker.indexOfSelectedItem >= 0, windowPicker.indexOfSelectedItem < windows.count else {
            setStatus("Pick a window first.", isError: true)
            return
        }
        let selected = windows[windowPicker.indexOfSelectedItem]
        let outputURL = outputURL(for: selected)
        let fps = max(1, min(Int(fpsField.stringValue) ?? 120, 120))
        let duration = TimeInterval(durationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))

        do {
            let recorder = WindowRecorder()
            self.recorder = recorder
            setRecordingUI(true)
            setStatus("Recording \(selected.appName) to \(outputURL.lastPathComponent)...")
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
            setStatus("Record failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func stopRecording() async {
        stopTask?.cancel()
        stopTask = nil
        guard let recorder else { return }
        self.recorder = nil
        setStatus("Stopping...")
        do {
            let url = try await recorder.stop()
            setRecordingUI(false)
            setStatus("Saved \(url.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            setRecordingUI(false)
            setStatus("Stop failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func setRecordingUI(_ isRecording: Bool) {
        recordButton.title = isRecording ? "Stop" : "Record"
        refreshButton.isEnabled = !isRecording
        permissionsButton.isEnabled = !isRecording
        windowPicker.isEnabled = !isRecording
        durationField.isEnabled = !isRecording
        fpsField.isEnabled = !isRecording
    }
}

final class WindowRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "WindowLockRecorder.capture")
    private let backgroundColor = CGColor(gray: 0.25, alpha: 1.0)
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

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = Self.display(containing: window, in: content.displays) else {
            throw RecorderError.displayNotFound
        }

        let filter = SCContentFilter(display: display, including: [window])
        let width = max(2, Int(CGDisplayPixelsWide(display.displayID)))
        let height = max(2, Int(CGDisplayPixelsHigh(display.displayID)))

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
        configuration.backgroundColor = backgroundColor
        configuration.scalesToFit = false
        configuration.showsCursor = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.queueDepth = 6
        if #available(macOS 14.0, *) {
            configuration.preservesAspectRatio = true
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
    case displayNotFound
    case notRecording
    case noFrames
    case finishFailed

    var errorDescription: String? {
        switch self {
        case .writerInputRejected:
            return "AVAssetWriter rejected the video input settings."
        case .displayNotFound:
            return "Could not resolve the display containing the selected window."
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
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
