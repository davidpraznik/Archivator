import SwiftUI
import UniformTypeIdentifiers

struct Wedge: Shape {
    var center: CGFloat
    var slice: CGFloat
    var outer: CGFloat
    var inner: CGFloat
    var gap: CGFloat
    var corner: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let d = gap / 2 + corner
        let R = outer - corner
        let r = inner + corner
        let b0 = center - slice / 2
        let b1 = center + slice / 2

        func pt(_ theta: CGFloat, _ t: CGFloat, _ p: CGFloat) -> CGPoint {
            CGPoint(x: c.x + t * cos(theta) - p * sin(theta),
                    y: c.y + t * sin(theta) + p * cos(theta))
        }
        func ang(_ p: CGPoint) -> CGFloat { atan2(p.y - c.y, p.x - c.x) }

        let tO = (R * R - d * d).squareRoot()
        let tI = (r * r - d * d).squareRoot()
        let so = pt(b0, tO, d)
        let eo = pt(b1, tO, -d)
        let ei = pt(b1, tI, -d)
        let si = pt(b0, tI, d)

        let a0 = ang(so)
        var a1 = ang(eo)
        if a1 < a0 { a1 += 2 * CGFloat.pi }
        let i0 = ang(si)
        var i1 = ang(ei)
        if i1 < i0 { i1 += 2 * CGFloat.pi }

        let steps = 40
        var p = Path()
        for i in 0...steps {
            let a = a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)
            let q = CGPoint(x: c.x + R * cos(a), y: c.y + R * sin(a))
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        for i in 0...steps {
            let a = i1 - (i1 - i0) * CGFloat(i) / CGFloat(steps)
            p.addLine(to: CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
        }
        p.closeSubpath()
        return p
    }
}

struct WheelDropDelegate: DropDelegate {
    let size: CGFloat
    let inner: CGFloat
    let gapHalf: CGFloat
    let targets: [Target]
    @Binding var targeted: Target?
    @Binding var overCenter: Bool
    let onDrop: ([URL], Target) -> Void

    func target(at p: CGPoint) -> Target? {
        let n = targets.count
        guard n > 0 else { return nil }
        let slice = 2 * CGFloat.pi / CGFloat(n)
        let dx = p.x - size / 2
        let dy = p.y - size / 2
        let dist = (dx * dx + dy * dy).squareRoot()
        guard dist >= inner - 4, dist <= size / 2 else { return nil }
        var a = atan2(dy, dx) + CGFloat.pi / 2
        if a < 0 { a += 2 * CGFloat.pi }
        let shifted = a + slice / 2
        let index = Int(shifted / slice) % n
        // razmik med kraki ni veljaven cilj
        let local = shifted.truncatingRemainder(dividingBy: slice)
        let toBoundary = min(local, slice - local)
        if dist * sin(toBoundary) < gapHalf { return nil }
        return targets[index]
    }

    func isCenter(at p: CGPoint) -> Bool {
        let dx = p.x - size / 2
        let dy = p.y - size / 2
        return (dx * dx + dy * dy).squareRoot() < inner - 4
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        targeted = target(at: info.location)
        overCenter = isCenter(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let t = target(at: info.location)
        targeted = t
        overCenter = isCenter(at: info.location)
        return DropProposal(operation: t == nil ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) {
        targeted = nil
        overCenter = false
    }

    func performDrop(info: DropInfo) -> Bool {
        let chosen = target(at: info.location)
        targeted = nil
        overCenter = false
        guard let chosenTarget = chosen else { return false }

        let providers = info.itemProviders(for: [.fileURL])
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url = url {
                        urls.append(url)
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            onDrop(urls, chosenTarget)
        }
        return true
    }
}

struct VisualEffectDisk: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.material = .popover
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct WheelView: View {
    @ObservedObject var model: WheelModel
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    @AppStorage(WheelStyle.storageKey) private var style = WheelStyle.glass.rawValue
    @State private var targeted: Target? = nil
    @State private var overCenter = false

    var body: some View {
        let p = Palette(scheme)
        let u = size / 360
        let targets = model.kind.targets
        let hint: String? = model.message.isEmpty && targeted == nil
            ? (overCenter ? "NOT HERE!" : "DROP ON…")
            : nil
        let centerText = hint ?? (model.message.isEmpty ? (targeted?.shortLabel ?? "") : model.message)

        ZStack {
            disk(p: p, u: u)

            ForEach(Array(targets.enumerated()), id: \.offset) { index, target in
                segment(index: index, count: targets.count, target: target, p: p, u: u)
            }

            if model.busy && model.total > 1 {
                Circle()
                    .stroke(p.track, lineWidth: 3 * u)
                    .frame(width: 118 * u, height: 118 * u)
                Circle()
                    .trim(from: 0, to: CGFloat(model.progress))
                    .stroke(p.progress, style: StrokeStyle(lineWidth: 3 * u, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 118 * u, height: 118 * u)
            } else if model.busy {
                // en sam posel: odstotka ne poznamo, zato se lok vrti
                Circle()
                    .stroke(p.track, lineWidth: 3 * u)
                    .frame(width: 118 * u, height: 118 * u)
                SpinnerArc(color: p.progress, width: 3 * u, diameter: 118 * u)
            }

            Circle()
                .fill(p.wedge.opacity(style == WheelStyle.glass.rawValue ? 0.88 : 1))
                .frame(width: 112 * u, height: 112 * u)
            VStack(spacing: 4 * u) {
                Text(centerText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(1 * u)
                    .font(inter(hint == nil ? 14 * u : 11 * u))
                    .tracking(hint == nil ? 0 : 0.88 * u)
                    .foregroundStyle(hint == nil ? p.text : p.textDim)
                if model.busy && model.chosen != nil {
                    Text("ESC TO CANCEL")
                        .font(inter(9 * u))
                        .tracking(0.64 * u)
                        .foregroundStyle(p.textDim)
                }
            }
        }
        .frame(width: size, height: size)
        .onDrop(of: [.fileURL], delegate: WheelDropDelegate(
            size: size,
            inner: 62 * u,
            gapHalf: 3 * u,
            targets: targets,
            targeted: $targeted,
            overCenter: $overCenter,
            onDrop: { urls, target in
                run(urls, target)
            }
        ))
    }

    private static let cheers = [
        "LIKE A BOSS!", "NAILED IT!", "SMOOTH!", "DONE!", "BOOM!",
        "EASY!", "CRISP!", "NICE ONE!", "SORTED!", "FLAWLESS!",
        "TOO EASY!", "CLEAN!"
    ]

    // Nosilec kolesa: Solid je polna barva, Glass je zamegljeno ozadje z barvno tinto in svetlim robom
    @ViewBuilder
    private func disk(p: Palette, u: CGFloat) -> some View {
        let shadow = Color.black.opacity(scheme == .dark ? 0.5 : 0.22)
        if style == WheelStyle.glass.rawValue {
            ZStack {
                VisualEffectDisk()
                Circle().fill(p.disk.opacity(0.25))
                Circle().fill(LinearGradient(
                    colors: [Color.white.opacity(scheme == .dark ? 0.10 : 0.45), Color.white.opacity(0.0), Color.white.opacity(scheme == .dark ? 0.06 : 0.25)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                Circle().strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(scheme == .dark ? 0.35 : 0.9), Color.white.opacity(0.15), Color.white.opacity(scheme == .dark ? 0.2 : 0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.2 * u)
            )
            .shadow(color: shadow, radius: 16 * u, x: 0, y: 10 * u)
        } else {
            Circle()
                .fill(p.disk)
                .shadow(color: shadow, radius: 16 * u, x: 0, y: 10 * u)
        }
    }

    private func run(_ urls: [URL], _ target: Target) {
        guard !urls.isEmpty else { return }
        var isCompress = false
        if case .compress = target { isCompress = true }
        model.chosen = target
        model.busy = true
        // stiskanje je en sam posel, razpakiranje en posel na arhiv
        model.total = isCompress ? 1 : urls.count
        model.progress = 0
        model.message = "…"

        if case .extractTo = target {
            // izbirnik mape po kratkem zamiku, da se vlečenje najprej konča
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if let folder = model.chooseFolder?() {
                    start(urls, target, folder)
                } else {
                    model.message = "CANCELED"
                    model.busy = false
                }
            }
        } else {
            start(urls, target, nil)
        }
    }

    private func start(_ urls: [URL], _ target: Target, _ folder: URL?) {
        Archiver.beginJob()
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = 0
            var jobs = 0
            switch target {
            case .compress(let format):
                jobs = 1
                do {
                    try Archiver.compress(urls, as: format)
                    ok = 1
                } catch {
                    Archiver.log(error)
                }
            case .extractHere, .extractTo:
                jobs = urls.count
                for (i, url) in urls.enumerated() {
                    if Archiver.wasCancelled { break }
                    do {
                        try Archiver.extract(url, into: folder)
                        ok += 1
                    } catch {
                        Archiver.log(error)
                    }
                    let done = i + 1
                    DispatchQueue.main.async {
                        model.progress = Double(done) / Double(urls.count)
                        if done < urls.count {
                            model.message = "\(done)/\(urls.count)"
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                if Archiver.wasCancelled {
                    model.message = "CANCELED"
                } else if ok == jobs {
                    model.message = Self.cheers.randomElement() ?? "DONE!"
                } else if ok == 0 {
                    model.message = "FAILED"
                } else {
                    model.message = "⚠︎ \(ok)/\(jobs)"
                }
                model.busy = false
            }
        }
    }

    private func segment(index: Int, count: Int, target: Target, p: Palette, u: CGFloat) -> some View {
        let slice = 2 * CGFloat.pi / CGFloat(count)
        let center = CGFloat(index) * slice - CGFloat.pi / 2
        let outer = 174 * u
        let inner = 62 * u
        let active = targeted == target || model.chosen == target
        let dimmed = model.busy && model.chosen != target

        let fill: Color = active ? p.accent : (dimmed ? p.wedgeDim : p.wedge)
        let labelColor: Color = active ? p.ink : (dimmed ? p.textDim : p.text)

        let shape = Wedge(center: center, slice: slice, outer: outer, inner: inner, gap: 6 * u, corner: 6 * u)
        let r = (outer + inner) / 2

        let px = size / 2 + r * cos(center)
        let py = size / 2 + r * sin(center)

        // Pri Glass so neaktivni izseki rahlo prosojni (88 %), aktivni je poln
        let glass = style == WheelStyle.glass.rawValue
        let wedgeOpacity: Double = (glass && !active) ? 0.88 : 1

        return ZStack {
            ZStack {
                shape.fill(fill)
                shape.stroke(fill, style: StrokeStyle(lineWidth: 12 * u, lineJoin: .round))
            }
            .compositingGroup()
            .opacity(wedgeOpacity)
            Text(target.label)
                .font(inter(15 * u))
                .foregroundStyle(labelColor)
                .position(x: px, y: py)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}


struct SpinnerArc: View {
    let color: Color
    let width: CGFloat
    let diameter: CGFloat
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(spinning ? 270 : -90))
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }
}
