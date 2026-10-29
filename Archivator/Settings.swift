import SwiftUI
import Combine
import AppKit
import ServiceManagement

// MARK: - Posodobitve

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    let repo = "davidpraznik/Archivator"
    private let defaults = UserDefaults.standard
    private var timer: Timer?

    @Published var autoCheck: Bool {
        didSet {
            defaults.set(autoCheck, forKey: "autoCheckUpdates")
            if autoCheck { checkIfDue() }
        }
    }
    @Published var available: String? = nil
    @Published var releaseURL: URL? = nil
    @Published var status = ""
    @Published var checking = false

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private init() {
        autoCheck = defaults.object(forKey: "autoCheckUpdates") as? Bool ?? true
        // Najdena posodobitev ostane vidna tudi po ponovnem zagonu, dokler ni nameščena
        if let v = defaults.string(forKey: "availableVersion"), UpdateChecker.isNewer(v, than: version) {
            available = v
            if let s = defaults.string(forKey: "availableURL") { releaseURL = URL(string: s) }
            status = "Update \(v) available"
        }
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // Ob zagonu in nato največ enkrat na dan
    func start() {
        checkIfDue()
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkIfDue() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func checkIfDue() {
        guard autoCheck, !checking else { return }
        let last = defaults.double(forKey: "lastUpdateCheck")
        if Date().timeIntervalSince1970 - last >= 86_400 {
            check(manual: false)
        }
    }

    func check(manual: Bool) {
        guard !checking else { return }
        checking = true
        if manual { status = "" }
        defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        Task {
            defer { checking = false }
            guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 {
                    if manual { status = "No releases published yet." }
                    return
                }
                guard code == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String
                else {
                    if manual { status = "Could not check for updates." }
                    return
                }
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if UpdateChecker.isNewer(latest, than: version) {
                    available = latest
                    let page = json["html_url"] as? String
                    releaseURL = page.flatMap { URL(string: $0) }
                    status = "Update \(latest) available"
                    defaults.set(latest, forKey: "availableVersion")
                    defaults.set(page, forKey: "availableURL")
                } else {
                    available = nil
                    releaseURL = nil
                    defaults.removeObject(forKey: "availableVersion")
                    defaults.removeObject(forKey: "availableURL")
                    if manual { status = "You are up to date (\(version))." }
                }
            } catch {
                if manual { status = "Could not check for updates." }
            }
        }
    }

    // Ikona menijske vrstice s koralno piko
    static func badgedIcon() -> NSImage {
        guard let base = NSImage(named: "MenuIcon") else { return NSImage() }
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            let tinted = NSImage(size: size, flipped: false) { r in
                base.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: rect)
            NSColor(red: 0.988, green: 0.318, blue: 0.349, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 7, height: 7)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Settings

@MainActor
final class SettingsModel: ObservableObject {
    @Published var launchAtLogin = (SMAppService.mainApp.status == .enabled)

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // stanje se spodaj osveži glede na dejansko stanje
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    @ObservedObject private var updates = UpdateChecker.shared
    @AppStorage(TriggerKey.storageKey) private var triggerKey = TriggerKey.option.rawValue
    @AppStorage(WheelStyle.storageKey) private var wheelStyle = WheelStyle.glass.rawValue
    @AppStorage(CompressionSettings.levelKey) private var level = CompressionLevel.balanced.rawValue
    @AppStorage(CompressionSettings.storeKey) private var storeCompressed = true
    @AppStorage(CompressionSettings.crossZipKey) private var crossZip = true
    @AppStorage(CompressionSettings.resultKey) private var result = ResultMode.nextToOriginal.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))

            Toggle("Check for updates automatically", isOn: $updates.autoCheck)

            VStack(alignment: .leading, spacing: 6) {
                Picker("Trigger key", selection: $triggerKey) {
                    ForEach(TriggerKey.allCases) { key in
                        Text(key.label).tag(key.rawValue)
                    }
                }
                .fixedSize()
                Text("Hold it while dragging files to show the wheel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("APPEARANCE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline) {
                    Text("Style").frame(width: 72, alignment: .leading)
                    Picker("Style", selection: $wheelStyle) {
                        ForEach(WheelStyle.allCases) { st in
                            Text(st.label).tag(st.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("COMPRESSION")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline) {
                    Text("Level").frame(width: 72, alignment: .leading)
                    Picker("Level", selection: $level) {
                        ForEach(CompressionLevel.allCases) { l in
                            Text(l.label).tag(l.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                Text("7Z, TAR.GZ and cross-platform ZIP. Best is smallest but slowest.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 80)

                Toggle("Store already compressed files", isOn: $storeCompressed)
                Text("Video, photos, music and archives are not squeezed again. Much faster.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)

                Toggle("Cross-platform ZIP", isOn: $crossZip)
                Text("Leaves out __MACOSX and .DS_Store, so the ZIP opens cleanly on Windows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)

                HStack(alignment: .firstTextBaseline) {
                    Text("Result").frame(width: 72, alignment: .leading)
                    Picker("Result", selection: $result) {
                        ForEach(ResultMode.allCases) { r in
                            Text(r.label).tag(r.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text("Or choose Ask where to save to pick a folder each time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 80)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Check for updates") { updates.check(manual: true) }
                        .disabled(updates.checking)
                    if updates.checking { ProgressView().controlSize(.small) }
                }
                if !updates.status.isEmpty {
                    Text(updates.status)
                        .font(.callout)
                        .foregroundStyle(updates.available != nil ? Color(hex: 0xFC5159) : Color.secondary)
                }
                if let url = updates.releaseURL {
                    Link("Open download page", destination: url)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Archivator \(updates.version)")
                    .font(.headline)
                Text("© 2026 David Praznik")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Link("github.com/davidpraznik/Archivator",
                     destination: URL(string: "https://github.com/davidpraznik/Archivator")!)
                    .font(.callout)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
