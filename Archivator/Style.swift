import SwiftUI
import CoreText

// MARK: - Oblika: barve, pisava (prevzeto iz Konverterja, accent je koralen)

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct Palette {
    let disk: Color
    let wedge: Color
    let wedgeDim: Color
    let text: Color
    let textDim: Color
    let track: Color
    let progress: Color
    let accent = Color(hex: 0xFC5159)
    let ink = Color.white

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            disk = Color(hex: 0x23262D)
            wedge = Color(hex: 0x353A44)
            wedgeDim = Color(hex: 0x2B2F37)
            text = Color(hex: 0xE9ECF1)
            textDim = Color(hex: 0x9AA3AF)
            track = Color(hex: 0x454A55)
            progress = Color(hex: 0xFC5159)
        } else {
            disk = Color(hex: 0xDEE3E7)
            wedge = Color(hex: 0xFFFFFF)
            wedgeDim = Color(hex: 0xF1F3F5)
            text = Color(hex: 0x16202A)
            textDim = Color(hex: 0x55606B)
            track = Color(hex: 0xC3CBD2)
            progress = Color(hex: 0xFC5159)
        }
    }
}

func registerFonts() {
    if let url = Bundle.main.url(forResource: "Inter-SemiBold", withExtension: "ttf") {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

func inter(_ size: CGFloat) -> Font {
    Font.custom("Inter-SemiBold", size: size)
}
