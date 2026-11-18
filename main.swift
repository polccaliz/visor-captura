// Visor Captura — mostra una entrada de vídeo (capturadora) a pantalla completa.
// La configuració es fa des de la barra de menús: Entrada, Format, Àudio, Visualització.

import Cocoa
import AVFoundation
import CoreMedia

let appName = "Visor Captura"

// MARK: - Formats

struct FormatOption {
    let format: AVCaptureDevice.Format
    let range: AVFrameRateRange
    let width: Int32
    let height: Int32
    let fps: Double
    let codec: String

    var fpsText: String {
        abs(fps - fps.rounded()) < 0.01 ? String(format: "%.0f", fps) : String(format: "%.2f", fps)
    }
    var resolution: String { "\(width) × \(height)" }
    var detail: String { "\(fpsText) fps · \(codec)" }
    var key: String { "\(width)x\(height)@\(fpsText)/\(codec)" }
}

func codecName(_ c: FourCharCode) -> String {
    let bytes: [UInt8] = [UInt8((c >> 24) & 0xff), UInt8((c >> 16) & 0xff), UInt8((c >> 8) & 0xff), UInt8(c & 0xff)]
    let s = String(bytes: bytes, encoding: .ascii) ?? "?"
    switch s {
    case "420v", "420f": return "YUV 4:2:0"
    case "2vuy", "yuvs": return "YUV 4:2:2"
    case "dmb1", "jpeg": return "MJPEG"
    case "BGRA": return "RGB"
    default: return s.trimmingCharacters(in: .whitespaces)
    }
}

func formatOptions(for d: AVCaptureDevice) -> [FormatOption] {
    var seen = Set<String>()
    var result: [FormatOption] = []
    for f in d.formats {
        let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let codec = codecName(CMFormatDescriptionGetMediaSubType(f.formatDescription))
        for r in f.videoSupportedFrameRateRanges {
            let o = FormatOption(format: f, range: r, width: dim.width, height: dim.height, fps: r.maxFrameRate, codec: codec)
            if seen.insert(o.key).inserted { result.append(o) }
        }
    }
    return result.sorted { a, b in
        let pa = Int(a.width) * Int(a.height), pb = Int(b.width) * Int(b.height)
        if pa != pb { return pa > pb }
        if a.fps != b.fps { return a.fps > b.fps }
        return a.codec < b.codec
    }
}

// MARK: - Dispositius

func videoDevices() -> [AVCaptureDevice] {
    var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
    if #available(macOS 14.0, *) { types.append(.external) } else { types.append(.externalUnknown) }
    return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
}

func audioDevices() -> [AVCaptureDevice] {
    var types: [AVCaptureDevice.DeviceType]
    if #available(macOS 14.0, *) { types = [.microphone, .external] } else { types = [.builtInMicrophone, .externalUnknown] }
    return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
}

// MARK: - Vistes

final class PreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        wantsLayer = true
        previewLayer.backgroundColor = NSColor.black.cgColor
        previewLayer.frame = bounds
        root.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}

final class ContainerView: NSView {
    weak var owner: AppDelegate?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) { owner?.bumpCursor() }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var window: NSWindow!
    var preview: PreviewView!
    var statusLabel: NSTextField!
    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "visor.session")
    let audioOut = AVCaptureAudioPreviewOutput()
    var videoInput: AVCaptureDeviceInput?
    var audioInput: AVCaptureDeviceInput?
    var activity: NSObjectProtocol?
    var cursorTimer: Timer?
    var pendingScreen: NSScreen?
    let defaults = UserDefaults.standard

    let inputMenu = NSMenu(title: "Entrada")
    let formatMenu = NSMenu(title: "Format")
    let audioMenu = NSMenu(title: "Àudio")
    let viewMenu = NSMenu(title: "Visualització")
    let screenMenu = NSMenu(title: "Pantalla")

    // MARK: Arrencada

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        buildMenus()

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
            reason: "Reproduint entrada de vídeo")

        audioOut.volume = defaults.bool(forKey: "muted") ? 0 : 1
        if session.canAddOutput(audioOut) { session.addOutput(audioOut) }
        preview.previewLayer.session = session
        applyGravity()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(deviceConnected(_:)), name: .AVCaptureDeviceWasConnected, object: nil)
        nc.addObserver(self, selector: #selector(deviceDisconnected(_:)), name: .AVCaptureDeviceWasDisconnected, object: nil)
        nc.addObserver(self, selector: #selector(sessionError(_:)), name: .AVCaptureSessionRuntimeError, object: session)

        bumpCursor()
        setStatus("Buscant entrades…")

        AVCaptureDevice.requestAccess(for: .video) { @Sendable ok in
            Task { @MainActor in self.accessResult(ok) }
        }
    }

    func accessResult(_ ok: Bool) {
        if ok {
            selectInitialDevices()
        } else {
            setStatus("Cal permís de càmera per veure la capturadora.\nConfiguració del Sistema › Privadesa i seguretat › Càmera")
        }
    }

    func selectInitialDevices() {
        let devs = videoDevices()
        let saved = defaults.string(forKey: "videoID")
        if let d = devs.first(where: { $0.uniqueID == saved }) {
            selectVideo(d)
        } else if let d = devs.first(where: { $0.deviceType != .builtInWideAngleCamera }) ?? devs.first {
            selectVideo(d, remember: saved == nil)
        } else {
            setStatus("Cap entrada de vídeo detectada.\nConnecta la capturadora.")
        }
        if let a = defaults.string(forKey: "audioID"), let ad = audioDevices().first(where: { $0.uniqueID == a }) {
            selectAudio(ad)
        }
        refreshInputMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        session.stopRunning()
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
    }

    // MARK: Finestra

    func buildWindow() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        window = NSWindow(contentRect: screen.frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = appName
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.delegate = self

        let container = ContainerView(frame: window.contentRect(forFrameRect: window.frame))
        container.owner = self
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        preview = PreviewView(frame: container.bounds)
        preview.autoresizingMask = [.width, .height]
        container.addSubview(preview)

        statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = .systemFont(ofSize: 22, weight: .medium)
        statusLabel.textColor = NSColor(white: 0.9, alpha: 1)
        statusLabel.alignment = .center
        statusLabel.drawsBackground = true
        statusLabel.backgroundColor = NSColor(white: 0, alpha: 0.6)
        statusLabel.preferredMaxLayoutWidth = 900
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, multiplier: 0.8),
        ])

        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.window.toggleFullScreen(nil) }
    }

    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    func windowDidExitFullScreen(_ notification: Notification) {
        if let s = pendingScreen {
            pendingScreen = nil
            place(on: s)
        }
    }

    func place(on screen: NSScreen) {
        window.setFrame(screen.frame, display: true)
        DispatchQueue.main.async { if !self.isFullScreen { self.window.toggleFullScreen(nil) } }
    }

    // MARK: Missatges en pantalla

    func setStatus(_ text: String?, flash: Bool = false) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideStatus), object: nil)
        statusLabel.stringValue = text.map { "  \($0)  " } ?? ""
        statusLabel.isHidden = (text == nil)
        if flash { perform(#selector(hideStatus), with: nil, afterDelay: 2.5) }
    }

    @objc func hideStatus() { statusLabel.isHidden = true }

    // MARK: Punter

    func bumpCursor() {
        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(timeInterval: 2.5, target: self, selector: #selector(hideCursor),
                                           userInfo: nil, repeats: false)
    }

    @objc func hideCursor() { NSCursor.setHiddenUntilMouseMoves(true) }

    // MARK: Sessió

    func startSession() {
        let s = session
        sessionQueue.async { if !s.isRunning { s.startRunning() } }
    }

    func selectVideo(_ device: AVCaptureDevice, remember: Bool = true) {
        session.beginConfiguration()
        if let old = videoInput { session.removeInput(old); videoInput = nil }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
            }
        } catch {
            setStatus("No s'ha pogut obrir \(device.localizedName)")
        }
        if videoInput != nil {
            applySavedFormat(device)
        }
        session.commitConfiguration()
        if remember { defaults.set(device.uniqueID, forKey: "videoID") }
        if videoInput != nil { setStatus(device.localizedName + "  ·  " + currentFormatText(device), flash: true) }
        startSession()
    }

    func removeVideo(message: String) {
        guard let old = videoInput else { return }
        session.beginConfiguration()
        session.removeInput(old)
        session.commitConfiguration()
        videoInput = nil
        setStatus(message)
    }

    func selectAudio(_ device: AVCaptureDevice?) {
        guard let device else {
            setAudioInput(nil)
            defaults.removeObject(forKey: "audioID")
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { @Sendable ok in
            Task { @MainActor in
                guard ok else {
                    self.setStatus("Cal permís de micròfon per escoltar l'àudio.\nConfiguració del Sistema › Privadesa i seguretat › Micròfon", flash: true)
                    return
                }
                self.setAudioInput(device)
                self.defaults.set(device.uniqueID, forKey: "audioID")
            }
        }
    }

    func setAudioInput(_ device: AVCaptureDevice?) {
        session.beginConfiguration()
        if let old = audioInput { session.removeInput(old); audioInput = nil }
        if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }
        session.commitConfiguration()
        startSession()
    }

    func currentFormatText(_ d: AVCaptureDevice) -> String {
        let dim = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
        let secs = CMTimeGetSeconds(d.activeVideoMinFrameDuration)
        let fps = secs > 0 ? 1 / secs : 0
        let fpsText = abs(fps - fps.rounded()) < 0.01 ? String(format: "%.0f", fps) : String(format: "%.2f", fps)
        return "\(dim.width) × \(dim.height) · \(fpsText) fps"
    }

    func isActive(_ o: FormatOption, on d: AVCaptureDevice) -> Bool {
        guard d.activeFormat == o.format else { return false }
        let secs = CMTimeGetSeconds(d.activeVideoMinFrameDuration)
        return secs > 0 && abs(1 / secs - o.fps) < 0.05
    }

    func apply(_ o: FormatOption, to d: AVCaptureDevice) {
        session.beginConfiguration()
        do {
            try d.lockForConfiguration()
            d.activeFormat = o.format
            d.activeVideoMinFrameDuration = o.range.minFrameDuration
            d.unlockForConfiguration()
        } catch {
            setStatus("No s'ha pogut canviar el format", flash: true)
        }
        session.commitConfiguration()
    }

    func applySavedFormat(_ d: AVCaptureDevice) {
        guard let key = defaults.string(forKey: "fmt." + d.uniqueID),
              let o = formatOptions(for: d).first(where: { $0.key == key }) else { return }
        apply(o, to: d)
    }

    // MARK: Connexió / desconnexió en calent

    @objc nonisolated func deviceConnected(_ n: Notification) {
        guard let d = n.object as? AVCaptureDevice else { return }
        let id = d.uniqueID
        Task { @MainActor in self.handleConnected(id) }
    }

    @objc nonisolated func deviceDisconnected(_ n: Notification) {
        guard let d = n.object as? AVCaptureDevice else { return }
        let id = d.uniqueID, name = d.localizedName
        Task { @MainActor in self.handleDisconnected(id, name: name) }
    }

    @objc nonisolated func sessionError(_ n: Notification) {
        Task { @MainActor in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.startSession() }
        }
    }

    func handleConnected(_ id: String) {
        guard let d = AVCaptureDevice(uniqueID: id) else { return }
        let savedVideo = defaults.string(forKey: "videoID")
        if d.hasMediaType(.video) {
            if id == savedVideo && videoInput?.device.uniqueID != id {
                selectVideo(d)
            } else if videoInput == nil {
                selectVideo(d, remember: savedVideo == nil)
            }
        }
        if d.hasMediaType(.audio), id == defaults.string(forKey: "audioID"), audioInput == nil {
            selectAudio(d)
        }
        refreshInputMenu()
    }

    func handleDisconnected(_ id: String, name: String) {
        if videoInput?.device.uniqueID == id {
            removeVideo(message: "S'ha desconnectat \(name)\nEs reprendrà automàticament quan es torni a connectar.")
        }
        if audioInput?.device.uniqueID == id { setAudioInput(nil) }
        refreshInputMenu()
    }

    // MARK: Menús

    func buildMenus() {
        let main = NSMenu()
        func top(_ m: NSMenu) {
            let i = NSMenuItem()
            i.submenu = m
            main.addItem(i)
        }

        let appMenu = NSMenu(title: appName)
        appMenu.addItem(withTitle: "Quant a \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Amaga \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Surt de \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        top(appMenu)

        for m in [inputMenu, formatMenu, audioMenu, viewMenu, screenMenu] {
            m.delegate = self
            m.autoenablesItems = false
        }
        top(inputMenu)
        top(formatMenu)
        top(audioMenu)
        top(viewMenu)
        NSApp.mainMenu = main
        refreshInputMenu()
        menuNeedsUpdate(viewMenu)
    }

    func refreshInputMenu() { menuNeedsUpdate(inputMenu) }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector?, key: String = "",
             mods: NSEvent.ModifierFlags = [.command], obj: Any? = nil, on: Bool = false,
             enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        i.representedObject = obj
        i.state = on ? .on : .off
        i.isEnabled = enabled && action != nil
        menu.addItem(i)
        return i
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === inputMenu { fillInputMenu(menu) }
        else if menu === formatMenu { fillFormatMenu(menu) }
        else if menu === audioMenu { fillAudioMenu(menu) }
        else if menu === viewMenu { fillViewMenu(menu) }
        else if menu === screenMenu { fillScreenMenu(menu) }
    }

    func fillInputMenu(_ m: NSMenu) {
        let devs = videoDevices()
        if devs.isEmpty { add(m, "Cap entrada detectada", nil) }
        for (n, d) in devs.enumerated() {
            add(m, d.localizedName, #selector(pickVideo(_:)), key: n < 9 ? "\(n + 1)" : "",
                obj: d, on: d.uniqueID == videoInput?.device.uniqueID)
        }
    }

    func fillFormatMenu(_ m: NSMenu) {
        guard let d = videoInput?.device else {
            add(m, "Tria primer una entrada", nil)
            return
        }
        add(m, "Actual: " + currentFormatText(d), nil)
        m.addItem(.separator())
        var groups: [(String, [FormatOption])] = []
        for o in formatOptions(for: d) {
            if let idx = groups.firstIndex(where: { $0.0 == o.resolution }) { groups[idx].1.append(o) }
            else { groups.append((o.resolution, [o])) }
        }
        for (res, opts) in groups {
            let parent = add(m, res, #selector(noop), on: opts.contains { isActive($0, on: d) })
            let sub = NSMenu(title: res)
            sub.autoenablesItems = false
            for o in opts { add(sub, o.detail, #selector(pickFormat(_:)), obj: o, on: isActive(o, on: d)) }
            parent.submenu = sub
        }
    }

    func fillAudioMenu(_ m: NSMenu) {
        add(m, "Sense àudio", #selector(pickAudio(_:)), obj: nil, on: audioInput == nil)
        m.addItem(.separator())
        for d in audioDevices() {
            add(m, d.localizedName, #selector(pickAudio(_:)), obj: d, on: d.uniqueID == audioInput?.device.uniqueID)
        }
        m.addItem(.separator())
        add(m, "Silencia", #selector(toggleMute), key: "m", mods: [.command, .option], on: audioOut.volume == 0)
    }

    func fillViewMenu(_ m: NSMenu) {
        add(m, "Pantalla completa", #selector(toggleFS), key: "f", mods: [.command, .control], on: isFullScreen)
        m.addItem(.separator())
        let g = defaults.string(forKey: "gravity") ?? "fit"
        add(m, "Ajusta (mantén proporció)", #selector(pickGravity(_:)), key: "1", mods: [.command, .option], obj: "fit", on: g == "fit")
        add(m, "Omple (retalla vores)", #selector(pickGravity(_:)), key: "2", mods: [.command, .option], obj: "fill", on: g == "fill")
        add(m, "Estira", #selector(pickGravity(_:)), key: "3", mods: [.command, .option], obj: "stretch", on: g == "stretch")
        m.addItem(.separator())
        let screens = add(m, "Mou a la pantalla", #selector(noop))
        screens.submenu = screenMenu
    }

    func fillScreenMenu(_ m: NSMenu) {
        for s in NSScreen.screens {
            add(m, s.localizedName, #selector(moveToScreen(_:)), obj: s, on: window?.screen == s)
        }
    }

    // MARK: Accions

    @objc func noop() {}

    @objc func pickVideo(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? AVCaptureDevice else { return }
        selectVideo(d)
    }

    @objc func pickFormat(_ sender: NSMenuItem) {
        guard let o = sender.representedObject as? FormatOption, let d = videoInput?.device else { return }
        apply(o, to: d)
        defaults.set(o.key, forKey: "fmt." + d.uniqueID)
        setStatus(o.resolution + "  ·  " + o.detail, flash: true)
    }

    @objc func pickAudio(_ sender: NSMenuItem) {
        selectAudio(sender.representedObject as? AVCaptureDevice)
    }

    @objc func toggleMute() {
        let muted = audioOut.volume > 0
        audioOut.volume = muted ? 0 : 1
        defaults.set(muted, forKey: "muted")
        setStatus(muted ? "Àudio silenciat" : "Àudio activat", flash: true)
    }

    @objc func toggleFS() { window.toggleFullScreen(nil) }

    @objc func pickGravity(_ sender: NSMenuItem) {
        guard let g = sender.representedObject as? String else { return }
        defaults.set(g, forKey: "gravity")
        applyGravity()
    }

    func applyGravity() {
        switch defaults.string(forKey: "gravity") ?? "fit" {
        case "fill": preview.previewLayer.videoGravity = .resizeAspectFill
        case "stretch": preview.previewLayer.videoGravity = .resize
        default: preview.previewLayer.videoGravity = .resizeAspect
        }
    }

    @objc func moveToScreen(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? NSScreen, s != window?.screen else { return }
        if isFullScreen {
            pendingScreen = s
            window.toggleFullScreen(nil)
        } else {
            place(on: s)
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
