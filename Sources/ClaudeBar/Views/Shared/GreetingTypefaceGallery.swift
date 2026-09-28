import SwiftUI

/// 设置 → 问候字体: every `GreetingTypeface` as a swatch, each writing the
/// phrase the dashboard is showing right now, from the same outlines and the
/// same added weight the greeting card uses — so what is picked here is what
/// the sky gets. A click selects; the card writes the new face in.
///
/// Folded by default. The closed row shows the face that is actually in use;
/// opening it lays out the whole set.
struct GreetingTypefaceGallery: View {
    @Binding var selection: GreetingTypeface
    /// The phrase to write, lower-cased like the card's.
    var sample: String = GreetingPhrase.forDate(Date()).script.lowercased() + ","
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s10) {
            Button {
                withAnimation(Theme.Animation.smooth) { expanded.toggle() }
            } label: {
                // `SectionHeader` already pins a spacer to the trailing edge.
                // The name and chevron sit in that gap as an overlay so they
                // don't fight the spacer for width.
                SectionHeader(icon: "signature", title: "问候字体", tint: Theme.claude)
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 6) {
                            if !expanded {
                                Text(selection.label)
                                    .font(Theme.Font.microMedium)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary())
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("问候字体")
            .accessibilityValue(selection.label)
            .accessibilityHint(expanded ? "收起字体列表" : "展开字体列表")

            if expanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 188), spacing: Theme.Space.gridGapPage, alignment: .top)],
                          alignment: .leading, spacing: Theme.Space.gridGapPage) {
                    ForEach(GreetingTypeface.allCases) { face in
                        GreetingTypefaceSwatch(face: face, sample: sample, selected: face == selection) {
                            selection = face
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else {
                Button {
                    withAnimation(Theme.Animation.smooth) { expanded = true }
                } label: {
                    GreetingTypefaceSummary(face: selection, sample: sample)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("展开问候字体，当前 \(selection.label)")
            }
        }
    }
}

/// The folded row: one specimen of the face in use, so the section still
/// shows how the greeting is written without laying out every other face.
private struct GreetingTypefaceSummary: View {
    let face: GreetingTypeface
    let sample: String
    @State private var hovered = false
    @State private var specimen: GreetingScript.Line?

    var body: some View {
        GreetingSpecimen(face: face, line: specimen)
            .equatable()
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 44)
            .task(id: "\(face.rawValue)|\(sample)") {
                let face = face, sample = sample
                specimen = await Task.detached(priority: .userInitiated) {
                    GreetingScript.line(sample, typeface: face)
                }.value
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tile(tint: Theme.claude, hovered: hovered, dense: true)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .hoverState($hovered)
    }
}

private struct GreetingTypefaceSwatch: View {
    let face: GreetingTypeface
    let sample: String
    let selected: Bool
    let select: () -> Void
    @State private var hovered = false
    /// Loaded off the main thread: opening Settings would otherwise read
    /// twenty-four font files and outline every phrase before its first frame.
    @State private var specimen: GreetingScript.Line?
    @State private var available = true

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                GreetingSpecimen(face: face, line: specimen)
                    .equatable()
                    .frame(height: 50)
                    .opacity(specimen == nil ? 0 : available ? 1 : 0.35)
                    .animation(.easeOut(duration: 0.2), value: specimen == nil)
                HStack(spacing: 6) {
                    Text(face.label)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                    if !face.isBundled {
                        Text(available ? "系统" : "不可用")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textTertiary())
                    }
                    if face == .standard {
                        Text("默认")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textTertiary())
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.claude)
                        .opacity(selected ? 1 : 0)
                        .scaleEffect(selected ? 1 : 0.6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tile(tint: Theme.claude, hovered: hovered || selected, dense: true)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Theme.claude.opacity(selected ? 0.75 : 0), lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .hoverState($hovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
        .accessibilityLabel("问候字体 \(face.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(available ? face.label : "\(face.label) 未安装在这台 Mac 上")
        .task(id: sample) {
            let face = face, sample = sample
            let loaded = await Task.detached(priority: .userInitiated) {
                (GreetingScript.isAvailable(face), GreetingScript.line(sample, typeface: face))
            }.value
            available = loaded.0
            specimen = loaded.1
        }
    }
}

/// One line of the greeting in `face`, fitted into the frame and left-aligned
/// on a shared baseline band, filled and weighted exactly as the card draws it.
private struct GreetingSpecimen: View, Equatable {
    let face: GreetingTypeface
    let line: GreetingScript.Line?

    /// Hovering a swatch re-renders it; the outlines have not changed.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.face == rhs.face && lhs.line?.path === rhs.line?.path }

    var body: some View {
        Canvas { context, size in
            guard let line else { return }
            let weight = face.weight
            let bounds = line.bounds.insetBy(dx: -weight, dy: -weight)
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            let origin = CGPoint(x: -bounds.minX * scale,
                                 y: (size.height - bounds.height * scale) / 2 - bounds.minY * scale)
            let outline = Path(GreetingScript.path(line, size: scale, origin: origin))
            let ink = GraphicsContext.Shading.color(Theme.textPrimary)
            context.fill(outline, with: ink)
            if weight > 0 {
                context.stroke(outline, with: ink,
                               style: StrokeStyle(lineWidth: scale * weight * 2, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}
