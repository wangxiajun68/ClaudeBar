import SwiftUI

// MARK: - Radar blip

/// A single live session on the radar — a dispatch target in the field. Carries
/// enough session detail to render an inline agent readout when inspected.
struct RadarBlip: Identifiable, Equatable {
    enum Kind: Equatable { case claude, cursor }

    let id: String
    let kind: Kind
    let title: String        // project folder
    let subtitle: String     // current activity or state label
    let busy: Bool
    let contextRatio: Double // 0...1 → orbital radius

    // Detail fields for the inline readout.
    let model: String
    let contextLabel: String
    let messageCount: Int
    let relativeUpdated: String
    let cwd: String
    let sessionId: String
    let subagentsCount: Int

    var color: Color {
        switch kind {
        case .claude: return busy ? Theme.claudeHi : Theme.claude
        case .cursor: return busy ? Theme.cursorHi : Theme.cursor
        }
    }
}

// MARK: - Live radar

/// The signature of the Dispatch world: a live radar that renders every running
/// Claude Code and Cursor session as a signal blip in orbit. Data is real —
/// blip position maps context fill, a busy session pings, and the sweep
/// accelerates with load — so motion conveys state instead of decorating.
///
/// Layers, bottom → top:
/// 1. Instrument graticule: concentric rings, crosshair, 30° ticks.
/// 2. The rotating sweep beam (a filled sector + leading-edge ray).
/// 3. Blips: glow + core; busy blips emit an expanding ping ring.
/// 4. Hover affordance: the nearest blip gains a selection ring + label bubble.
/// 5. Center beacon — "you", the dispatcher.
struct LiveRadar: View {
    @EnvironmentObject var providerStore: ProviderStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Fire when a blip is tapped; the host navigates to the sessions page.
    var onSelect: (RadarBlip) -> Void = { _ in }

    @State private var hoverPoint: CGPoint?
    @State private var size: CGSize = .zero

    // MARK: Blip source

    private var blips: [RadarBlip] {
        var out: [RadarBlip] = []
        for s in providerStore.sessions where s.isAlive {
            out.append(RadarBlip(
                id: "c-\(s.pid)",
                kind: .claude,
                title: s.projectFolder,
                subtitle: s.currentActivity.isEmpty ? (s.status == .busy ? "working…" : "idle") : s.currentActivity,
                busy: s.status == .busy,
                contextRatio: s.contextRatio,
                model: s.model,
                contextLabel: s.contextLabel,
                messageCount: s.messageCount,
                relativeUpdated: s.relativeUpdated,
                cwd: s.cwd,
                sessionId: s.sessionId,
                subagentsCount: s.subagents.count + s.workflows.reduce(0) { $0 + $1.agents.count }
            ))
        }
        for s in providerStore.cursorSessions {
            out.append(RadarBlip(
                id: "u-\(s.composerId)",
                kind: .cursor,
                title: s.projectFolder.isEmpty ? "cursor" : s.projectFolder,
                subtitle: s.currentActivity.isEmpty ? (s.status == .active ? "working…" : "idle") : s.currentActivity,
                busy: s.status == .active,
                contextRatio: s.contextRatio,
                model: "",
                contextLabel: s.contextLabel,
                messageCount: s.messageCount,
                relativeUpdated: s.relativeUpdated,
                cwd: s.cwd,
                sessionId: s.composerId,
                subagentsCount: s.subagents.count
            ))
        }
        return out
    }

    private var busyCount: Int { blips.filter(\.busy).count }

    // MARK: Body

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { gctx, canvasSize in
                draw(gctx: gctx, size: canvasSize, t: t)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onGeometryChange(for: CGSize.self) { proxy in proxy.size } action: { size = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hoverPoint = point
            case .ended:
                withAnimation(Theme.Animation.smooth) { hoverPoint = nil }
            @unknown default: break
            }
        }
        .gesture(SpatialTapGesture().onEnded { value in
            if let hit = blip(at: value.location) { onSelect(hit) }
        })
        .overlay(alignment: .topTrailing) { liveBadge }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("雷达概览，\(busyCount) 个活跃会话，共 \(blips.count) 个会话")
        .accessibilityAddTraits(.isButton)
    }

    /// "LIVE ● N" — the world's live indicator. Top-trailing so the radar
    /// reads as an instrument with a powered-on readout.
    private var liveBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(busyCount > 0 ? Theme.claude : Theme.statusIdle)
                .frame(width: 5, height: 5)
                .symbolEffect(.pulse, options: .repeating, isActive: busyCount > 0)
            Text(busyCount > 0 ? "LIVE · \(busyCount)" : "STANDBY")
                .font(Theme.Font.captionMono)
                .foregroundColor(busyCount > 0 ? Theme.claudeHi : Theme.textTertiary())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Theme.base3.opacity(0.8))
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        )
        .padding(8)
    }

    // MARK: Drawing

    private func draw(gctx: GraphicsContext, size: CGSize, t: Double) {
        guard size.width > 0, size.height > 0 else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - 18

        // Scope face: a faint luminous disk so the radar reads as an
        // instrument face rather than line-work floating on glass.
        gctx.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(colors: [Color.white.opacity(0.045), Color.white.opacity(0.0)]),
                center: center, startRadius: 0, endRadius: radius
            )
        )

        drawGraticule(gctx, center: center, radius: radius)
        drawSweep(gctx, center: center, radius: radius, t: t)
        drawBlips(gctx, center: center, radius: radius, t: t)

        // Center beacon — the dispatcher.
        gctx.fill(Path(ellipseIn: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)),
                  with: .color(Theme.textSecondary.opacity(0.7)))
        gctx.stroke(Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)),
                    with: .color(Theme.textSecondary.opacity(0.25)), lineWidth: 1)
    }

    // MARK: Graticule

    private func drawGraticule(_ gctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        gctx.stroke(Path(CGRect(x: center.x - radius, y: center.y, width: radius * 2, height: 0.5)),
                    with: .color(Theme.Radar.crosshair), lineWidth: 0.5)
        gctx.stroke(Path(CGRect(x: center.x, y: center.y - radius, width: 0.5, height: radius * 2)),
                    with: .color(Theme.Radar.crosshair), lineWidth: 0.5)
        for r in [radius, radius * 0.62, radius * 0.34] {
            gctx.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                        with: .color(Theme.Radar.ring), lineWidth: 1)
        }
        for i in 0..<12 {
            let a = Double(i) / 12.0 * .pi * 2
            let p1 = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
            let p2 = CGPoint(x: center.x + cos(a) * (radius - 6), y: center.y + sin(a) * (radius - 6))
            var p = Path()
            p.move(to: p1); p.addLine(to: p2)
            gctx.stroke(p, with: .color(Theme.Radar.ring), lineWidth: 1)
        }
    }

    // MARK: Sweep beam

    private func drawSweep(_ gctx: GraphicsContext, center: CGPoint, radius: CGFloat, t: Double) {
        // Sweep accelerates with load: idle drifts, busy scans fast.
        let speed = reduceMotion ? 0.05 : (1.1 + Double(busyCount) * 0.5)
        let angle = speed * t

        let trailing = angle - 1.1   // ~63° trailing tail
        var sector = Path()
        sector.move(to: center)
        sector.addArc(center: center, radius: radius,
                      startAngle: .radians(trailing), endAngle: .radians(angle),
                      clockwise: false)
        sector.closeSubpath()
        gctx.fill(sector, with: .radialGradient(
            Gradient(colors: [Theme.Radar.sweepEdge.opacity(0.9), Theme.Radar.sweep.opacity(0.0)]),
            center: center, startRadius: 0, endRadius: radius
        ))

        // Leading-edge ray.
        let edge = CGPoint(x: center.x + cos(angle) * radius,
                           y: center.y + sin(angle) * radius)
        var ray = Path()
        ray.move(to: center); ray.addLine(to: edge)
        gctx.stroke(ray, with: .color(Theme.claude.opacity(reduceMotion ? 0.06 : 0.30)), lineWidth: 1.1)
    }

    // MARK: Blips

    private func drawBlips(_ gctx: GraphicsContext, center: CGPoint, radius: CGFloat, t: Double) {
        for b in blips {
            let pos = blipPosition(b, center: center, radius: radius)
            let c = b.color
            let isHovered = hoveredBlip?.id == b.id

            // Ping ring for busy blips — the "something is working" signal.
            if b.busy && !reduceMotion {
                let stagger = Double(stableHash(b.id) % 100) / 100.0
                let p = (t / 1.5 + stagger).truncatingRemainder(dividingBy: 1)
                let pr = 4 + CGFloat(p) * 11
                gctx.stroke(
                    Path(ellipseIn: CGRect(x: pos.x - pr, y: pos.y - pr, width: pr * 2, height: pr * 2)),
                    with: .color(c.opacity((1 - p) * 0.4)), lineWidth: 1.2
                )
            }

            // Glow + core.
            if isHovered || b.busy {
                gctx.fill(Path(ellipseIn: CGRect(x: pos.x - 7, y: pos.y - 7, width: 14, height: 14)),
                          with: .color(c.opacity(isHovered ? 0.30 : 0.18)))
            }
            gctx.fill(Path(ellipseIn: CGRect(x: pos.x - 3.2, y: pos.y - 3.2, width: 6.4, height: 6.4)),
                      with: .color(b.busy ? c : c.opacity(0.55)))

            // Selection ring on hover.
            if isHovered {
                gctx.stroke(Path(ellipseIn: CGRect(x: pos.x - 9, y: pos.y - 9, width: 18, height: 18)),
                            with: .color(c.opacity(0.85)), lineWidth: 1.4)
            }
        }

        // Hover label bubble, drawn last so it sits above everything.
        if let hb = hoveredBlip {
            let pos = blipPosition(hb, center: center, radius: radius)
            drawLabel(hb, at: pos, in: gctx, bounds: CGSize(width: radius * 2, height: radius * 2))
        }
    }

    private func drawLabel(_ b: RadarBlip, at pos: CGPoint, in gctx: GraphicsContext, bounds: CGSize) {
        let text = gctx.resolve(
            Text("\(b.title) · \(b.subtitle)")
                .font(Theme.Font.captionMono)
                .foregroundColor(b.color)
        )
        let tw = text.measure(in: bounds).width
        let bw = min(tw + 16, bounds.width - 20)
        var rect = CGRect(x: pos.x - bw / 2 - 8, y: pos.y - 30, width: bw + 16, height: 20)
        // Keep the bubble on-canvas.
        rect.origin.x = max(4, min(rect.origin.x, bounds.width - rect.width - 4))
        let bubble = Path(roundedRect: rect, cornerRadius: 6)
        gctx.fill(bubble, with: .color(Theme.base3.opacity(0.92)))
        gctx.stroke(bubble, with: .color(b.color.opacity(0.5)), lineWidth: 0.5)
        gctx.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
    }

    // MARK: Geometry

    private func blipPosition(_ b: RadarBlip, center: CGPoint, radius: CGFloat) -> CGPoint {
        let a = blipAngle(b)
        let r = blipRadius(b) * radius
        return CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
    }

    /// Stable per-session angle — deterministic across launches (FNV-1a).
    private func blipAngle(_ b: RadarBlip) -> Double {
        Double(stableHash(b.id) % 3600) / 3600.0 * .pi * 2
    }

    /// Context fill maps to orbital radius: empty → inner ring, full → outer.
    private func blipRadius(_ b: RadarBlip) -> CGFloat {
        CGFloat(0.32 + min(max(b.contextRatio, 0), 1) * 0.46)
    }

    private var hoveredBlip: RadarBlip? {
        guard let hp = hoverPoint, size.width > 0, size.height > 0 else { return nil }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - 18
        return blips.min { a, b in
            let pa = blipPosition(a, center: center, radius: radius)
            let pb = blipPosition(b, center: center, radius: radius)
            let da = hypot(pa.x - hp.x, pa.y - hp.y)
            let db = hypot(pb.x - hp.x, pb.y - hp.y)
            return da < db
        }.flatMap { candidate in
            let p = blipPosition(candidate, center: center, radius: radius)
            return hypot(p.x - hp.x, p.y - hp.y) <= 20 ? candidate : nil
        }
    }

    private func blip(at point: CGPoint) -> RadarBlip? {
        guard size.width > 0, size.height > 0 else { return nil }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - 18
        return blips.min { a, b in
            let pa = blipPosition(a, center: center, radius: radius)
            let pb = blipPosition(b, center: center, radius: radius)
            return hypot(pa.x - point.x, pa.y - point.y) < hypot(pb.x - point.x, pb.y - point.y)
        }.flatMap { candidate in
            let p = blipPosition(candidate, center: center, radius: radius)
            return hypot(p.x - point.x, p.y - point.y) <= 20 ? candidate : nil
        }
    }
}

// MARK: - Radar agent detail

/// The inline readout shown when a radar blip is inspected: the selected
/// agent's live telemetry plus actions. The radar becomes a dispatch console —
/// hover to preview, click to inspect, act without leaving the dashboard.
struct RadarAgentDetail: View {
    let blip: RadarBlip
    let onClose: () -> Void
    let onOpenSessions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: status + title + live trace + close.
            HStack(spacing: 6) {
                Circle()
                    .fill(blip.busy ? blip.color : Theme.statusIdle)
                    .frame(width: 5, height: 5)
                    .symbolEffect(.pulse, options: .repeating, isActive: blip.busy)
                Text(blip.title)
                    .font(Theme.Font.bodyLarge)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                if blip.busy { SignalTrace(isActive: true, color: blip.color) }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }

            // Current activity in the agent's signal color.
            if !blip.subtitle.isEmpty {
                Text(blip.subtitle)
                    .font(Theme.Font.captionMono)
                    .foregroundColor(blip.color)
                    .lineLimit(1)
            }

            // Telemetry row: context / model / msgs / recency / subagents.
            HStack(spacing: 10) {
                if !blip.contextLabel.isEmpty && !blip.contextLabel.hasPrefix("—") {
                    Label(blip.contextLabel, systemImage: "text.bubble")
                        .foregroundColor(Theme.contextColor(blip.contextRatio))
                }
                if !blip.model.isEmpty {
                    Label(blip.model, systemImage: "cpu")
                }
                Label("\(blip.messageCount) msgs", systemImage: "bubble.left")
                if blip.subagentsCount > 0 {
                    Label("\(blip.subagentsCount) 子代理", systemImage: "person.2")
                }
                Spacer()
                Label(blip.relativeUpdated, systemImage: "clock")
            }
            .font(Theme.Font.caption)
            .foregroundColor(Theme.textSecondary)
            .lineLimit(1)

            // Actions.
            HStack(spacing: 6) {
                primaryActionChip
                ActionChip(systemImage: "folder", tint: Theme.textSecondary, help: "在 Finder 显示") {
                    revealCwd()
                }
                Spacer()
                Button("在会话页查看") { onOpenSessions() }
                    .buttonStyle(.glass)
                    .tint(Theme.claude)
                    .font(Theme.Font.bodySmall)
            }
        }
        .padding(10)
        .glassEffect(.regular.tint(Color.white.opacity(0.07)), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(Theme.Animation.smooth, value: blip.id)
    }

    /// Resume in terminal (Claude) / open in Cursor — the dispatch action.
    private var primaryActionChip: some View {
        switch blip.kind {
        case .claude:
            return ActionChip(systemImage: "play.fill", tint: Theme.claude, help: "在终端恢复") {
                TerminalLauncher.resumeClaudeSession(cwd: blip.cwd, sessionId: blip.sessionId)
            }
        case .cursor:
            return ActionChip(systemImage: "cursorarrow", tint: Theme.cursorAccent, help: "在 Cursor 打开") {
                TerminalLauncher.openInCursor(cwd: blip.cwd)
            }
        }
    }

    private func revealCwd() {
        guard !blip.cwd.isEmpty,
              FileManager.default.fileExists(atPath: blip.cwd) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: blip.cwd)
    }
}

// MARK: - Deterministic hash

/// FNV-1a over a string's UTF-8 bytes — stable across launches (unlike
/// `String.hashValue`, which is SipHash-seeded per process).
func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for byte in s.utf8 {
        h = (h ^ UInt64(byte)) &* 0x100000001b3
    }
    return h
}
