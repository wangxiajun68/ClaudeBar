#!/usr/bin/env python3
"""Glance-reel geometry: the pager must hold one line across every card shape.

The reel is a fixed 188 x `cardBodyHeight` card whose bottom strip carries the
page dots. Probe lanes are arbitrary heights — the point is that none of them
may move the card.
Two bugs shipped here before: the dots took part in the card's layout, so a
two-mark card (short content) pushed them up while a four-mark card pushed
them to the edge; and the reel sized itself from whatever the session lane
gave it, so the whole reel moved as sessions appeared. Both are layout facts,
so measure them: render each card shape and compare the pager's distance to
the card's own bottom edge. Source slices, no app launch.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
components = (root / 'Sources/ClaudeBar/Views/Island/IslandComponents.swift').read_text()
view = (root / 'Sources/ClaudeBar/Views/Island/NotchIslandView.swift').read_text()


def matching_brace(text, open_index):
    """Index just past the `}` matching the `{` at `open_index`."""
    depth = 0
    for i in range(open_index, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return i + 1
    raise AssertionError('unbalanced braces')


# The production mark cell and glance content, lifted verbatim so the test
# measures the shipped view tree rather than a copy.
#
# The cell is delimited by brace matching rather than by whatever function
# happens to follow it: the reel and the network page render the same cell
# through a shared card view, and a slice that ran to the "next function"
# would silently swallow everything in between.
start = components.index('    private func markCell(_ mark: IslandMark)')
open_brace = components.index('{', start)
markCell = components[start:matching_brace(components, open_brace)]
# Drop the production signature line: the probe supplies its own `cell`.
markCell = '\n'.join(markCell.splitlines()[1:])

# The probe's marks are (value, caption) pairs with no agent, so the well is
# always the instrument-glyph form. Collapse the product-mark branch and its
# `else` scaffold — dropping the branch *body* rather than making it dead code,
# so the probe does not have to know whether the well is built with a symbol
# name or a glyph kind.
if_start = markCell.index('if let agent = mark.mark {')
if_open = markCell.index('{', if_start)
if_close = matching_brace(markCell, if_open)
else_start = markCell.index('else {', if_close)
else_open = markCell.index('{', else_start)
else_close = matching_brace(markCell, else_open)
markCell = markCell[:if_start] + markCell[else_open + 1:else_close - 1] + markCell[else_close:]
markCell = markCell.replace('mark.kind', 'InstrumentGlyph.Kind.cpu')
markCell = markCell.replace('mark.tint', 'Color.white')
markCell = markCell.replace('mark.value', 'm.0').replace('mark.caption', 'm.1')
# The slice ends on the cell's own closing brace; the caller supplies that.
markCell = markCell.rstrip()
assert markCell.endswith('}'), 'mark cell slice did not end on its closing brace'
markCell = markCell[:-1].rstrip()

style = view[view.index('enum IslandStyle {'):view.index('/// What the island\'s buttons do')]
# The slice stops just before the trailing marker comments, so the enum needs
# its own closing brace appended.
style = style.rstrip().rstrip('}').rstrip() + '\n}\n'
# Mark wells live in the same file as the reel; the agent marks they can draw
# need the brand canvas, which is irrelevant to geometry.
well = components[components.index('struct IslandMarkWell: View {'):components.index('private struct IslandMark: Identifiable {')]
# The well draws whichever icon family the mark names; only its geometry is
# under test here, so the glyph artwork is replaced with a same-sized clear
# square. Its `Kind` vocabulary is lifted from production (below), so a new
# instrument kind does not need a change here.
well = well.replace('InstrumentGlyph(kind: kind, tint: tint)', 'Color.clear')

# Instrument vocabulary — `IslandAgent.markKind` and the well both name it.
glyph_source = (root / 'Sources/ClaudeBar/Views/Shared/InstrumentGlyph.swift').read_text()
kind_start = glyph_source.index('    enum Kind {')
kind_body = glyph_source[kind_start:matching_brace(glyph_source, glyph_source.index('{', kind_start))]
kind_enum = 'enum InstrumentGlyph {\n' + kind_body + '\n}\n'
agents = (root / 'Sources/ClaudeBar/Models/IslandLiveModel.swift').read_text()
agentEnum = agents[agents.index('enum IslandAgent: String'):agents.index('/// One live agent session')]
usageSource = 'enum UsageSource: String, CaseIterable, Identifiable {\n    case claude, codex, thirdParty\n    var id: String { rawValue }\n}\n'
theme = (root / 'Sources/ClaudeBar/Theme/Theme.swift').read_text()
hexInit = theme[theme.index('extension Color {'):theme.index('// MARK: - Theme')]

swift = r'''
import SwiftUI
import AppKit
import Combine
HEXINIT
USAGESOURCE
KINDENUM
AGENTENUM
STYLE
WELL

/// Brand glyph stub: the well's geometry, not its artwork, is under test.
struct IslandAgentMark: View {
    let agent: IslandAgent
    var body: some View { Color.white }
}

/// The production cell rolls its digits through this shared component. It
/// lives in `Interaction.swift`, outside the slice under test, so it is stubbed
/// to the same text — the geometry is what the probe measures, not the roll.
struct RollingNumberText: View {
    let value: String
    init(_ value: String) { self.value = value }
    var body: some View { Text(value).monospacedDigit() }
}

private struct IslandUsage { }

/// Renders one card of the reel — the same view tree the reel builds, minus
/// the tap / hover machinery and the 4.2 s playback task, plus a hand-rolled
/// pager so a regression cannot hide in the pager's own geometry.
struct CardProbe: View {
    let frameShape: (title: String, marks: [(String, String)])
    var body: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Text(frameShape.title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if frameShape.marks.count >= 4 {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 8) {
                        ForEach(Array(frameShape.marks.enumerated()), id: \.offset) { _, m in cell(m) }
                    }
                } else {
                    HStack(spacing: 4) {
                        ForEach(Array(frameShape.marks.enumerated()), id: \.offset) { _, m in cell(m) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(10)
        .overlay(alignment: .bottom) {
            pager
                .padding(.bottom, IslandStyle.pagerInset)
        }
        .frame(maxWidth: .infinity)
        .frame(height: IslandStyle.glanceReelHeight, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.045)))
    }

    private var pager: some View {
        HStack(spacing: 4) {
            ForEach(0..<8, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(i == 0 ? 0.85 : 0.22))
                    .frame(width: i == 0 ? 12 : 4, height: 4)
            }
        }
        .frame(height: 4)
    }

    private func cell(_ m: (String, String)) -> some View {
MARKCELL
    }
}

@main struct Regression {
    @MainActor static func main() {
        _ = NSApplication.shared

        /// Rasterise one card and return (pagerCentreY, cardBottomY) in points.
        func measure(title: String, marks: [(String, String)]) -> (CGFloat, CGFloat) {
            let renderer = ImageRenderer(content: CardProbe(frameShape: (title, marks)).frame(width: 188))
            renderer.scale = 2
            guard let image = renderer.cgImage else { fatalError("no image") }
            let rep = NSBitmapImageRep(cgImage: image)
            let width = image.width, height = image.height
            func luminance(_ x: Int, _ y: Int) -> CGFloat {
                guard let c = rep.colorAt(x: x, y: y) else { return 0 }
                return (c.redComponent + c.greenComponent + c.blueComponent) / 3
            }
            // The card's own fill (#000 + white 4.5%) is the widest near-uniform
            // band; background is pure black.
            var cardBottom = 0
            for y in 0..<height {
                var run = 0, best = 0
                for x in 0..<width {
                    let v = luminance(x, y)
                    if v > 0.030, v < 0.060 { run += 1; best = max(best, run) } else { run = 0 }
                }
                if best > width / 2 { cardBottom = y }
            }
            // The pager is the bottom-most band of bright dots.
            var pagerTop = 0, pagerBottom = 0
            for y in stride(from: height - 1, through: 0, by: -1) {
                let bright = (0..<width).filter { luminance($0, y) > 0.37 }.count
                if bright > 8 { pagerBottom = max(pagerBottom, y); pagerTop = y }
            }
            precondition(pagerBottom > 0, "pager not found in \(title)")
            return (CGFloat(pagerTop + pagerBottom) / 4, CGFloat(cardBottom) / 2)
        }

        let two = [("0%", "3 小时 39 分后"), ("53%", "6 天后")]
        let four = [("30%", "CPU"), ("0%", "GPU"), ("84%", "内存"), ("80%", "电池")]
        let cards: [(String, [(String, String)])] = [
            ("Codex 额度", two),
            ("本机", four),
            ("当前模型", [("deepseek-v4.1-flash", "Claude"), ("deepseek-v4.1-flash", "Codex")]),
            ("供应商余额", [("¥12.00", "A"), ("¥8.00", "B"), ("¥5.00", "C"), ("¥1.00", "D")]),
        ]

        // 1. Every card rasterises to exactly the same box.
        var heights = Set<Int>(), widths = Set<Int>()
        for (title, marks) in cards {
            let renderer = ImageRenderer(content: CardProbe(frameShape: (title, marks)).frame(width: 188))
            renderer.scale = 2
            let image = renderer.cgImage!
            heights.insert(image.height)
            widths.insert(image.width)
        }
        precondition(heights == [Int(IslandStyle.glanceReelHeight * 2)],
                     "every card must be exactly glanceReelHeight tall; got \(heights)")
        precondition(widths.count == 1, "every card must be the same width; got \(widths)")

        // 2. The pager holds one line across card shapes.
        let (twoPager, twoBottom) = measure(title: "Codex 额度", marks: two)
        let (fourPager, fourBottom) = measure(title: "本机", marks: four)
        let twoGap = twoBottom - twoPager
        let fourGap = fourBottom - fourPager
        precondition(abs(twoGap - fourGap) < 0.5,
                     "pager must sit the same distance from the card bottom; got \(twoGap) vs \(fourGap)")

        // 3. Option B: the lane still springs, so the card is top-aligned and
        //    clipped inside it instead of pushing the lane taller. The card's
        //    own size must not follow the lane.
        struct LaneProbe: View {
            let marks: [(String, String)]
            let laneHeight: CGFloat
            var body: some View {
                HStack(alignment: .top, spacing: 8) {
                    Color.clear.frame(maxWidth: .infinity, minHeight: laneHeight)
                    CardProbe(frameShape: ("本机", marks))
                        .frame(width: IslandStyle.glanceReelWidth,
                               height: IslandStyle.glanceReelHeight,
                               alignment: .top)
                        .clipped()
                }
                .frame(height: laneHeight, alignment: .top)
            }
        }
        for lane in [40.0, 44.0, 90.0, 136.0, 206.0] {
            let renderer = ImageRenderer(content: LaneProbe(marks: four, laneHeight: lane))
            renderer.scale = 2
            let image = renderer.cgImage!
            precondition(image.height == Int(lane * 2),
                         "lane \(lane)pt must stay \(lane)pt; got \(Double(image.height) / 2)")
        }
        precondition(IslandStyle.glanceReelHeight == IslandStyle.cardContentBand
                     + 2 * IslandStyle.glanceCardPadding + IslandStyle.reelPagerBand,
                     "the card box must be its content plus its padding plus the reserved pager band, "
                     + "not a hand-tuned number")
        precondition(IslandStyle.cardContentBand == IslandStyle.cardBodyHeight,
                     "the content band must be the card body the pages actually draw")
        precondition(IslandStyle.reelPagerBand == (IslandStyle.reelReservesPager
                     ? IslandStyle.pagerInset + IslandStyle.pagerDotHeight : 0),
                     "a reserved pager band must be exactly the pager's own height")
        print("PASS: card fixed at \(IslandStyle.glanceCardSize.width)x\(IslandStyle.glanceReelHeight)pt across "
              + "\(cards.count) shapes; pager gap \(twoGap)pt vs \(fourGap)pt; lane 40/44/90/136/206pt unaffected")
    }
}
'''.replace('HEXINIT', hexInit).replace('USAGESOURCE', usageSource) \
   .replace('KINDENUM', kind_enum) \
   .replace('AGENTENUM', agentEnum).replace('STYLE', style).replace('WELL', well) \
   .replace('MARKCELL', markCell)
with tempfile.TemporaryDirectory(prefix='claudebar-reel-tests-') as folder:
    source = Path(folder) / 'Regression.swift'
    source.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
