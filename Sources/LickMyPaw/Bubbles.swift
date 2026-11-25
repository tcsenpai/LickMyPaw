import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: opacity)
    }
}

func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

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

func makeBubbles(_ parent: Node, size: CGSize, maxBubbles: Int = 22) -> [Bubble] {
    let kids = Array(parent.children.prefix(maxBubbles))
    guard let top = kids.first, top.size > 0, size.width > 50, size.height > 50 else { return [] }
    let rest = parent.children.dropFirst(maxBubbles).reduce(Int64(0)) { $0 + $1.size }
    var items: [(Node?, String, Int64)] = kids.map { ($0, $0.displayName, $0.size) }
    if rest > 0 { items.append((nil, T("Other items"), rest)) }
    items.sort { $0.2 > $1.2 }
    let radii = items.map { max(0.26, CGFloat(pow(Double($0.2) / Double(items[0].2), 0.38))) }
    let pts = packCircles(radii)
    var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
    for (p, r) in zip(pts, radii) { minX = min(minX, p.x - r); maxX = max(maxX, p.x + r); minY = min(minY, p.y - r); maxY = max(maxY, p.y + r) }
    let pad: CGFloat = 16
    let k = min((size.width - pad * 2) / (maxX - minX), (size.height - pad * 2) / (maxY - minY))
    let ox = size.width / 2 - (minX + maxX) / 2 * k, oy = size.height / 2 - (minY + maxY) / 2 * k
    return items.enumerated().map { i, it in
        Bubble(id: i, node: it.0, label: it.1, size: it.2, center: CGPoint(x: pts[i].x * k + ox, y: pts[i].y * k + oy), r: radii[i] * k)
    }
}

struct BubbleView: View {
    let parent: Node
    let checked: Set<Node>
    var onOpen: (Node) -> Void
    var onToggle: (Node) -> Void
    @State private var hover: Int?
    @State private var shown = false

    var body: some View {
        GeometryReader { g in
            let bubbles = makeBubbles(parent, size: g.size)
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
                            if let n = b.node, b.r > 26 {
                                Image(nsImage: Icons.icon(n)).resizable().interpolation(.high).scaledToFit().frame(width: b.r * (b.r > 55 ? 0.85 : 0.95), height: b.r * (b.r > 55 ? 0.85 : 0.95))
                            } else if b.node == nil && b.r > 26 {
                                Image(systemName: "ellipsis.circle.fill").font(.system(size: b.r * 0.5)).foregroundStyle(.white.opacity(0.8))
                            }
                            if b.r > 44 {
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
                    .position(b.center)
                    .help("\(b.label) — \(fmt(b.size))")
                    .onHover { hover = $0 ? b.id : (hover == b.id ? nil : hover) }
                    .onTapGesture { if let n = b.node { if n.isDir { onOpen(n) } else { onToggle(n) } } }
                    .contextMenu { if let n = b.node { Button(on ? T("Deselect") : T("Select")) { onToggle(n) } } }
                }
            }.frame(width: g.size.width, height: g.size.height)
        }.onAppear { shown = true }
    }
}
