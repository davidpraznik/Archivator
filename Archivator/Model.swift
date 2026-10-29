import SwiftUI
import Combine

enum ArchiveFormat: String, CaseIterable, Identifiable {
    case zip = "ZIP", sevenZ = "7Z", tarGz = "TAR.GZ"
    var id: String { rawValue }

    var ext: String {
        switch self {
        case .zip: return "zip"
        case .sevenZ: return "7z"
        case .tarGz: return "tar.gz"
        }
    }
}

// Tipka, ki jo držiš med vlečenjem. Shift in Command pripadata Konverterju.
enum TriggerKey: String, CaseIterable, Identifiable {
    case option, control, controlOption
    var id: String { rawValue }

    static let storageKey = "triggerKey"

    var label: String {
        switch self {
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .controlOption: return "⌃⌥ Control + Option"
        }
    }

    static var current: TriggerKey {
        TriggerKey(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .option
    }

    func matches(_ flags: NSEvent.ModifierFlags) -> Bool {
        if flags.contains(.shift) || flags.contains(.command) { return false }
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        switch self {
        case .option: return option && !control
        case .control: return control && !option
        case .controlOption: return option && control
        }
    }
}

enum WheelStyle: String, CaseIterable, Identifiable {
    case glass, solid
    static let storageKey = "wheelStyle"
    var id: String { rawValue }
    var label: String { self == .glass ? "Glass" : "Solid" }
}

enum CompressionLevel: String, CaseIterable, Identifiable {
    case fast, balanced, best
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ResultMode: String, CaseIterable, Identifiable {
    case nextToOriginal, ask
    var id: String { rawValue }
    var label: String { self == .nextToOriginal ? "Save next to original" : "Ask where to save" }
}

// Nastavitve stiskanja (shranjene v UserDefaults, berejo se ob vsakem poslu)
enum CompressionSettings {
    static let levelKey = "compressionLevel"
    static let storeKey = "storeCompressed"
    static let crossZipKey = "crossPlatformZip"
    static let resultKey = "compressionResult"

    nonisolated static var level: CompressionLevel {
        CompressionLevel(rawValue: UserDefaults.standard.string(forKey: levelKey) ?? "") ?? .balanced
    }
    nonisolated static var storeCompressed: Bool {
        UserDefaults.standard.object(forKey: storeKey) as? Bool ?? true
    }
    nonisolated static var crossPlatformZip: Bool {
        UserDefaults.standard.object(forKey: crossZipKey) as? Bool ?? true
    }
    nonisolated static var result: ResultMode {
        ResultMode(rawValue: UserDefaults.standard.string(forKey: resultKey) ?? "") ?? .nextToOriginal
    }
}

enum Target: Hashable {
    case compress(ArchiveFormat)
    case extractHere
    case extractTo

    var label: String {
        switch self {
        case .compress(let f): return f.rawValue
        case .extractHere: return "EXTRACT HERE"
        case .extractTo: return "EXTRACT TO…"
        }
    }

    // oznaka za sredino kolesa (dvovrstična, da stane v krog)
    var shortLabel: String {
        switch self {
        case .extractHere: return "EXTRACT\nHERE"
        case .extractTo: return "EXTRACT\nTO…"
        default: return label
        }
    }
}

enum WheelKind {
    case compress, extract

    var targets: [Target] {
        switch self {
        case .compress: return ArchiveFormat.allCases.map { Target.compress($0) }
        case .extract: return [.extractHere, .extractTo]
        }
    }
}

final class WheelModel: ObservableObject {
    @Published var message = ""
    @Published var kind: WheelKind = .compress
    @Published var busy = false
    @Published var chosen: Target? = nil
    @Published var progress: Double = 0
    @Published var total = 0
    // nastavi AppDelegate: pokaže izbirnik mape, vrne nil ob preklicu
    var chooseFolder: ((_ forExtract: Bool) -> URL?)? = nil
}
