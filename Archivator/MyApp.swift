import SwiftUI
import AppKit

@main
struct ArchivatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @ObservedObject private var updates = UpdateChecker.shared

    var body: some Scene {
        MenuBarExtra {
            if let v = updates.available, let url = updates.releaseURL {
                Button("Update available: \(v)…") {
                    NSWorkspace.shared.open(url)
                }
                Divider()
            }
            Button("Settings…") {
                appDelegate.showSettings()
            }
            .keyboardShortcut(",")
            Divider()
            Button("Quit Archivator") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            if updates.available != nil {
                Image(nsImage: UpdateChecker.badgedIcon())
            } else {
                Image("MenuIcon")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var alwaysPolling = false
    private var panel: NSPanel?
    private let model = WheelModel()
    private var baselineCount = NSPasteboard(name: .drag).changeCount
    private var wheelVisible = false
    private var hideWork: DispatchWorkItem?
    private let wheelSize: CGFloat = 360
    private let panelSize: CGFloat = 420
    private var settingsWindow: NSWindow?

    @MainActor
    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Archivator Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerFonts()
        Task { @MainActor in UpdateChecker.shared.start() }
        model.chooseFolder = { [weak self] in self?.chooseFolder() }
        // Časovnik teče samo, dokler je levi gumb miške pritisnjen (ali dokler kolo dela).
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.startPolling()
        }
        // Če monitor ni na voljo, ostane stalno spraševanje.
        if mouseMonitor == nil {
            alwaysPolling = true
            startPolling()
        }
    }

    private func startPolling() {
        guard timer == nil else { return }
        baselineCount = NSPasteboard(name: .drag).changeCount
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = 0.01
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // Esc med delom prekliče posel (stanje tipke, brez posebnih dovoljenj)
        if model.busy, CGEventSource.keyState(.combinedSessionState, key: 0x35) {
            Archiver.cancel()
        }
        let pb = NSPasteboard(name: .drag)
        let pressed = (NSEvent.pressedMouseButtons & 1) != 0

        if !pressed {
            baselineCount = pb.changeCount
            if wheelVisible {
                scheduleHide()
            } else if !alwaysPolling {
                stopPolling()
            }
            return
        }

        if wheelVisible { return }

        // Izbrana tipka (privzeto Option) + vleci. Shift in Command pripadata Konverterju.
        guard pb.changeCount != baselineCount,
              TriggerKey.current.matches(NSEvent.modifierFlags) else { return }

        let urls = (pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []

        guard !urls.isEmpty else { return }
        showWheel(kind: Archiver.kind(of: urls))
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelSize, height: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let root = WheelView(model: model, size: wheelSize)
            .frame(width: panelSize, height: panelSize)
        p.contentView = NSHostingView(rootView: root)
        return p
    }

    private func showWheel(kind: WheelKind) {
        hideWork?.cancel()
        hideWork = nil
        model.kind = kind
        model.message = ""
        model.chosen = nil
        model.progress = 0
        model.total = 0
        if panel == nil { panel = makePanel() }

        let m = NSEvent.mouseLocation
        var origin = NSPoint(x: m.x - panelSize / 2, y: m.y - panelSize / 2)
        if let s = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) {
            let f = s.visibleFrame
            origin.x = min(max(origin.x, f.minX), f.maxX - panelSize)
            origin.y = min(max(origin.y, f.minY), f.maxY - panelSize)
        }
        panel?.setFrameOrigin(origin)
        panel?.orderFrontRegardless()
        wheelVisible = true
    }

    // "Extract to…": kolo se umakne, odpre se izbirnik mape
    private func chooseFolder() -> URL? {
        panel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = true
        open.allowsMultipleSelection = false
        open.prompt = "Extract"
        open.message = "Choose where to extract"
        let result = open.runModal()
        NSApp.hide(nil)
        panel?.orderFrontRegardless()
        return result == .OK ? open.url : nil
    }

    private func scheduleHide() {
        if hideWork != nil { return }
        let work = DispatchWorkItem { [weak self] in
            self?.finishHide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func finishHide() {
        if model.busy {
            let work = DispatchWorkItem { [weak self] in
                self?.finishHide()
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            return
        }
        if model.message.isEmpty {
            hideWheel()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.hideWheel()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func hideWheel() {
        panel?.orderOut(nil)
        wheelVisible = false
        hideWork = nil
    }
}
