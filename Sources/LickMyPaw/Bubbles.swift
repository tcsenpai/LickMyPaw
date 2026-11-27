import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: opacity)
    }
}

func fmt(_ b: Int64) -> String {
    if Demo.enabled { return demoFmt(b) }
    return ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

/// Screenshots only: en_US style sizes (decimal point) regardless of the machine locale.
private func demoFmt(_ b: Int64) -> String {
    let u = ["bytes", "KB", "MB", "GB", "TB"]; var v = Double(b), i = 0
    while v >= 1000 && i < u.count - 1 { v /= 1000; i += 1 }
    return i >= 3 ? String(format: "%.1f %@", v, u[i]) : String(format: "%.0f %@", v, u[i])
}

enum Icons {
    nonisolated(unsafe) static var cache: [String: NSImage] = [:]
    static func icon(_ n: Node) -> NSImage {
        if n.isAggregate { return NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil) ?? NSImage() }
        if let i = cache[n.path] { return i }
        let i = NSWorkspace.shared.icon(forFile: n.path); cache[n.path] = i; return i
    }
}

struct Bubble: Identifiable {
    let id: Int
    let node: Node?          // nil = T("Other items")
    let label: String
    let size: Int64
    let center: CGPoint
    let r: CGFloat
}

/// Greedy circle packing: each circle goes tangent to two placed ones, closest to the origin, without overlap.
func packCircles(_ radii: [CGFloat], gap: CGFloat = 0.04) -> [CGPoint] {
    var pts: [CGPoint] = []
    for (i, r) in radii.enumerated() {
        if i == 0 { pts.append(.zero); continue }
        if i == 1 { pts.append(CGPoint(x: radii[0] + r + gap, y: 0)); continue }
        var best: CGPoint?, bestD = CGFloat.infinity
        for a in 0..<i { for b in (a + 1)..<i {
            let ra = radii[a] + r + gap, rb = radii[b] + r + gap
            let dx = pts[b].x - pts[a].x, dy = pts[b].y - pts[a].y, d = (dx * dx + dy * dy).squareRoot()
            if d == 0 || d > ra + rb || d < abs(ra - rb) { continue }
            let l = (ra * ra - rb * rb + d * d) / (2 * d), h = max(0, ra * ra - l * l).squareRoot()
            let mx = pts[a].x + l * dx / d, my = pts[a].y + l * dy / d
            for s in [CGFloat(1), -1] {
                let c = CGPoint(x: mx + s * h * dy / d, y: my - s * h * dx / d)
                var ok = true
                for j in 0..<i { let ex = c.x - pts[j].x, ey = c.y - pts[j].y
                    if (ex * ex + ey * ey).squareRoot() < radii[j] + r + gap - 0.001 { ok = false; break } }
                let dist = (c.x * c.x + c.y * c.y).squareRoot()
                if ok && dist < bestD { best = c; bestD = dist }
            }
        } }
        pts.append(best ?? CGPoint(x: pts.map { $0.x + 0 }.max()! + radii[i] + gap, y: 0))
    }
    return pts
}

func makeBubbles(_ parent: Node, size: CGSize) -> [Bubble] { layoutBubbles(parent, size: size).bubbles }

/// Packs bubbles to fit the view; when there are too many, bubbles keep a minimum size and the content grows (view scrolls).
func layoutBubbles(_ parent: Node, size: CGSize, maxBubbles: Int = 120, minRadius: CGFloat = 32) -> (bubbles: [Bubble], content: CGSize) {
    let kids = Array(parent.children.prefix(maxBubbles))
    guard let top = kids.first, top.size > 0, size.width > 50, size.height > 50 else { return ([], size) }
    let rest = parent.children.dropFirst(maxBubbles).reduce(Int64(0)) { $0 + $1.size }
    var items: [(Node?, String, Int64)] = kids.map { ($0, $0.displayName, $0.size) }
    if rest > 0 { items.append((nil, T("Other items"), rest)) }
    items.sort { $0.2 > $1.2 }
    let radii = items.map { max(0.26, CGFloat(pow(Double($0.2) / Double(items[0].2), 0.38))) }
    let pts = packCircles(radii)
    var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
    for (p, r) in zip(pts, radii) { minX = min(minX, p.x - r); maxX = max(maxX, p.x + r); minY = min(minY, p.y - r); maxY = max(maxY, p.y + r) }
    let pad: CGFloat = 16
    let fit = min((size.width - pad * 2) / (maxX - minX), (size.height - pad * 2) / (maxY - minY))
    let k = max(fit, minRadius / radii.min()!)
    let content = CGSize(width: max(size.width, (maxX - minX) * k + pad * 2), height: max(size.height, (maxY - minY) * k + pad * 2))
    let ox = content.width / 2 - (minX + maxX) / 2 * k, oy = content.height / 2 - (minY + maxY) / 2 * k
    return (items.enumerated().map { i, it in
        Bubble(id: i, node: it.0, label: it.1, size: it.2, center: CGPoint(x: pts[i].x * k + ox, y: pts[i].y * k + oy), r: radii[i] * k)
    }, content)
}

struct BubbleView: View {
    let parent: Node
    let checked: Set<Node>
    var onOpen: (Node) -> Void
    var onToggle: (Node) -> Void
    var onReveal: (Node) -> Void = { _ in }
    var scrollable = true            // false only for headless --render (ImageRenderer cannot draw ScrollView)
    @State private var hover: Int?
    @State private var shown = false

    var body: some View {
        GeometryReader { g in
            let lay = layoutBubbles(parent, size: g.size)
            let bubbles = lay.bubbles
            Wrap(scrollable: scrollable, center: CGPoint(x: lay.content.width / 2, y: lay.content.height / 2)) {
            ZStack {
                ForEach(bubbles) { b in
                    let on = b.node.map { checked.contains($0) } ?? false
                    ZStack {
                        Circle().fill(RadialGradient(colors: [Color.white.opacity(0.26), Color(hex: 0x7a3df0, opacity: 0.30), Color(hex: 0x4a14b8, opacity: 0.35)],
                                                     center: .init(x: 0.3, y: 0.2), startRadius: 0, endRadius: b.r * 1.6))
                        Circle().strokeBorder(on ? AnyShapeStyle(Color(hex: 0xFF3FA4))
                                                  : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom)),
                                              lineWidth: on ? 3.5 : 1.4)
                        VStack(spacing: 2) {
                            let full = b.r > 44, named = b.r >= 30
                            let side = b.r * (full ? (b.r > 55 ? 0.85 : 0.95) : (named ? 0.62 : 1.0))
                            if let n = b.node {
                                Image(nsImage: Icons.icon(n)).resizable().interpolation(.high).scaledToFit().frame(width: side, height: side)
                            } else {
                                Image(systemName: "ellipsis.circle.fill").font(.system(size: side * 0.6)).foregroundStyle(.white.opacity(0.8))
                            }
                            if named && !full {
                                Text(b.label).font(.system(size: 9.5, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                            }
                            if full {
                                Text(b.label).font(.system(size: min(15, max(10, b.r / 6.5)), weight: .semibold, design: .rounded)).lineLimit(1)
                                Text(fmt(b.size)).font(.system(size: min(14, max(9, b.r / 7)), design: .rounded)).opacity(0.9)
                            }
                        }.foregroundStyle(.white).padding(b.r * 0.12).frame(width: b.r * 2, height: b.r * 2)
                    }
                    .frame(width: b.r * 2, height: b.r * 2)
                    .scaleEffect(shown ? 1 : 0.15).opacity(shown ? 1 : 0)
                    .animation(.spring(response: 0.55, dampingFraction: 0.68).delay(Double(b.id) * 0.035), value: shown)
                    .scaleEffect(hover == b.id ? 1.05 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
                    // hit area = this circle; after .position the frame is the whole canvas and the topmost bubble steals every click (issue #1)
                    .contentShape(Circle())
                    .onHover { hover = $0 ? b.id : (hover == b.id ? nil : hover) }
                    .onTapGesture(count: 2) { if let n = b.node { if n.isDir { onOpen(n) } else { onReveal(n) } } }
                    .onTapGesture { if let n = b.node { onToggle(n) } }
                    .contextMenu { if let n = b.node { Button(on ? T("Deselect") : T("Select")) { onToggle(n) } } }
                    .position(b.center)
                }
                if let h = hover, let b = bubbles.first(where: { $0.id == h }) {
                    Text("\(b.label): \(fmt(b.size))").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.7))).overlay(Capsule().strokeBorder(Color.white.opacity(0.2)))
                        .fixedSize().position(x: min(max(b.center.x, 90), lay.content.width - 90), y: max(b.center.y - b.r - 14, 14))
                        .allowsHitTesting(false).zIndex(10)
                }
            }.frame(width: lay.content.width, height: lay.content.height)
            }.frame(width: g.size.width, height: g.size.height)
        }.onAppear { shown = true }
    }
}

struct Wrap<C: View>: View {
    let scrollable: Bool
    let center: CGPoint            // scroll starts here (the biggest bubbles), not at the top-left corner
    @ViewBuilder let content: () -> C
    var body: some View {
        if scrollable {
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        content()
                        Color.clear.frame(width: 1, height: 1).offset(x: center.x, y: center.y).id("center")
                    }
                }.onAppear { proxy.scrollTo("center", anchor: .center) }
            }
        }
        else { content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped() }
    }
}

/// Bubbles suite: a real double-click on each bubble, sent to an offscreen window, must open that bubble's folder (issue #1).
enum BubblesSelfTest {
    /// The selftest runs under dispatchMain, so AppKit only draws and delivers events while the run loop is pumped by hand.
    private static func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    @MainActor static func run(_ t: TestCtx) async {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)   // selftest has no app object; prohibited = no Dock icon, no focus steal
        let root = Node(name: "root", path: "/tmp/lmp-bubbles", isDir: true)
        for (i, s) in [900, 500, 300, 120, 60, 20].enumerated() {
            let c = Node(name: "d\(i)", path: "/tmp/lmp-bubbles/d\(i)", isDir: true, size: Int64(s) << 20); c.parent = root; root.children.append(c)
        }
        let size = CGSize(width: 900, height: 600)
        var opened: Node?
        let host = NSHostingView(rootView: BubbleView(parent: root, checked: [], onOpen: { opened = $0 }, onToggle: { _ in }, scrollable: false)
            .frame(width: size.width, height: size.height))
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host; w.orderFrontRegardless(); defer { w.orderOut(nil) }   // far off-screen, never key
        pump(1.2)   // let the pop-in animation finish
        for b in makeBubbles(root, size: size) {
            guard let n = b.node else { continue }
            opened = nil
            let p = NSPoint(x: b.center.x, y: size.height - b.center.y)   // SwiftUI is top-left, AppKit bottom-left
            for clicks in 1...2 {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) { w.sendEvent(e) }
                }
            }
            pump(0.15)
            if opened != nil { t.reachedCode() }
            t.check(opened === n, "double-click on \(n.name) opens \(n.name) (got \(opened?.name ?? "nothing"))")
        }
    }
}
