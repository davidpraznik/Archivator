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
    var chooseFolder: (() -> URL?)? = nil
}
