#!/usr/bin/env python3
"""`SwarmGrid` packing, slotting and strip arithmetic, driven for real.

The Codex swarm cluster is pure layout math — column packing, the visible
prefix, the trailing "+N" slot, and the strip/requiredHeight contracts the
sessions page sizes its cards against — and until now it had zero coverage:
every guard lived in a comment, and the first 'Darwin' → 'D…' width
regression shipped through exactly that gap. This slices the production
`SwarmGrid` (with its `slots()` placement rule) and asserts the invariants
every call site depends on, across a width/height/count matrix:

- `visibleCount + overflow == count`, and every drawn agent slot is a
  distinct index of `0..<visibleCount`, in row-major order;
- the "+N" tile appears exactly once (last drawn row) iff `overflow > 0`,
  and it never displaces an agent that could have been drawn;
- no drawn row exceeds `columns` cells, and no more rows are drawn than
  `rows`;
- `cardWidth` clears the documented floor whenever the box itself is at
  least that wide;
- `strip`'s drawn cells fit the rows its returned height reserves at the
  *same* width — the invariant whose absence clipped the bottom row of the
  sessions grid card's strip.

No app, no SwiftUI rendering: the slice is arithmetic and plain values.
"""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[1]
source_file = (root / 'Sources/ClaudeBar/Views/Shared/AgentSwarmView.swift').read_text()


def declaration(text, marker):
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


grid = declaration(source_file, '    struct SwarmGrid {')
# The struct is nested inside the view; the fixture lifts it to top level.
grid = grid.replace('    struct SwarmGrid {', 'struct SwarmGrid {', 1)

swift = r'''
import Foundation
import CoreGraphics

''' + grid + r'''

func require(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    guard condition() else { print("FAIL \(line): \(message)"); exit(1) }
}

@main struct Regression {
    static func main() {
        let widths: [CGFloat] = [1, 40, 55, 56, 57, 68, 100, 152, 200, 299, 300, 560, 900, 1400]
        let heights: [CGFloat] = [1, 20, 23, 24, 30, 51, 100, 260, 520, 1400]
        let counts = [0, 1, 2, 5, 9, 10, 11, 45, 60, 61, 199, 200, 10_000]

        for compact in [true, false] {
            let floorW = SwarmGrid.cardFloor(compact: compact)
            for width in widths {
                for height in heights {
                    for count in counts {
                        let grid = SwarmGrid(count: count, size: CGSize(width: width, height: height),
                                             compact: compact)
                        let tag = "compact=\(compact) w=\(width) h=\(height) n=\(count)"
                        if count == 0 {
                            require(grid.visibleCount == 0 && grid.overflow == 0 && grid.slots().isEmpty,
                                    "empty packing must draw nothing — \(tag)")
                            continue
                        }
                        require(grid.columns > 0 && grid.rows > 0, "packing must draw rows — \(tag)")
                        require(grid.visibleCount + grid.overflow == count,
                                "visible+overflow must account for every agent — \(tag)")
                        require(grid.visibleCount <= count, "visible exceeds count — \(tag)")
                        if width >= floorW {
                            require(grid.cardWidth >= floorW,
                                    "cardWidth \(grid.cardWidth) under the floor \(floorW) — \(tag)")
                        }
                        require(grid.rowFill > 0 && grid.rowFill <= 1, "rowFill out of range — \(tag)")

                        // Slots: exactly the agents 0..<visibleCount in row-major
                        // order, the "+N" tile once at the end when overflowing.
                        let rows = grid.slots()
                        require(rows.count <= grid.rows, "more rows drawn than packed — \(tag)")
                        var agents: [Int] = []
                        var overflowSlots = 0
                        for (index, row) in rows.enumerated() {
                            require(!row.isEmpty && row.count <= grid.columns,
                                    "row \(index) has \(row.count) cells for \(grid.columns) columns — \(tag)")
                            for cell in row {
                                switch cell {
                                case .some(let agent): agents.append(agent)
                                case .none:
                                    overflowSlots += 1
                                    require(index == rows.count - 1,
                                            "the +N tile must be the last drawn row — \(tag)")
                                }
                            }
                        }
                        require(agents == Array(0..<grid.visibleCount),
                                "drawn agents must be 0..<visibleCount in order — \(tag)")
                        if grid.overflow > 0 {
                            require(overflowSlots == 1,
                                    "an overflowing grid draws the +N tile exactly once — \(tag)")
                            require(grid.overflow >= 2,
                                    "an overflowing grid hides at least two agents — \(tag)")
                        } else {
                            require(overflowSlots == 0, "a complete grid draws no +N tile — \(tag)")
                        }

                        // The strip contract at the same width: the cells its
                        // returned height reserves must actually be there.
                        let stripHeight = grid.cardHeight
                        require(stripHeight == SwarmGrid.cardHeight(compact: compact),
                                "packed card height must match the preset — \(tag)")
                    }
                }
            }
        }

        // Explicit `strip` contract: drawn cells fit the reserved rows at the
        // width the strip was sized against, and the height is exactly the
        // rows that much drawing needs.
        for compact in [true, false] {
            let cardH = SwarmGrid.cardHeight(compact: compact)
            let sp = SwarmGrid.spacing(compact: compact)
            for maxRows in [1, 2, 3, 6] {
                for width in widths {
                    for count in counts + [Int.max] {
                        let strip = SwarmGrid.strip(count: count, width: width,
                                                    maxRows: maxRows, compact: compact)
                        let tag = "strip compact=\(compact) w=\(width) rows=\(maxRows) n=\(count)"
                        require(strip.visible >= 0, "negative visible — \(tag)")
                        let columns = SwarmGrid.columns(forWidth: width, compact: compact)
                        let capacity = columns * maxRows
                        let overflowing = count > capacity
                        require(strip.visible <= capacity, "visible exceeds the reserved cells — \(tag)")
                        if !overflowing {
                            require(strip.visible == count, "a fitting strip shows every agent — \(tag)")
                        } else {
                            require(strip.visible == capacity - 1,
                                    "an overflowing strip reserves one cell for +N — \(tag)")
                        }
                        let drawn = strip.visible + (overflowing ? 1 : 0)
                        let drawnRows = max(1, (drawn + columns - 1) / columns)
                        require(drawnRows <= maxRows,
                                "drawn cells \(drawn) need \(drawnRows) rows of \(maxRows) — \(tag)")
                        require(strip.height == CGFloat(drawnRows) * cardH + CGFloat(drawnRows - 1) * sp,
                                "height \(strip.height) does not match \(drawnRows) drawn rows — \(tag)")

                        // The reserved height must really carry the drawn grid:
                        // packing exactly `visible` cards into (width, height)
                        // may not need more rows than the strip reserved.
                        let packed = SwarmGrid(count: strip.visible,
                                               size: CGSize(width: width, height: strip.height),
                                               compact: compact)
                        require(strip.visible == 0 || packed.rows <= maxRows,
                                "the reserved height packs into \(packed.rows) rows — \(tag)")
                        if strip.visible == 0 {
                            require(!overflowing || capacity <= 1, "empty strip without overflow — \(tag)")
                        }
                    }
                }
            }
        }

        // Dense sweep over every integer width/count at a mid height: the
        // floor guarantee (`cardWidth >= floorW` whenever the box itself is at
        // least that wide) is the property finding 214 doubted — its
        // `needed` path was believed to push `chosen` past what `maxColumns`
        // allows, sizing cards under the floor. It cannot: `chosen` is capped
        // by `maxColumns`, which is computed *at* the floor.
        for compact in [true, false] {
            let floorW = SwarmGrid.cardFloor(compact: compact)
            for width in 0..<600 {
                let w = CGFloat(width)
                for count in [1, 3, 20, 61, 200, 1000] {
                    let grid = SwarmGrid(count: count, size: CGSize(width: w, height: 260),
                                         compact: compact)
                    if w >= floorW {
                        require(grid.cardWidth >= floorW,
                                "dense: cardWidth \(grid.cardWidth) < floor \(floorW) at w=\(w) n=\(count)")
                        let cell = (w + grid.spacing) / CGFloat(grid.columns)
                        require(cell >= floorW, "dense: cell pitch \(cell) < floor at w=\(w) n=\(count)")
                    }
                }
            }
        }

        // `requiredHeight`: the sessions page sizes a full-width tile with this
        // at `tileEstimateWidth`, so a tile must be tall enough for the grid it
        // draws there.
        for compact in [true, false] {
            for count in [1, 2, 9, 10, 45, 60, 61, 200, 10_000] {
                let width = SwarmGrid.tileEstimateWidth
                let height = SwarmGrid.requiredHeight(count: count, width: width, compact: compact)
                let packed = SwarmGrid(count: count, size: CGSize(width: width, height: height),
                                       compact: compact)
                require(packed.visibleCount == count,
                        "requiredHeight must fit the whole fan-out (n=\(count), compact=\(compact))")
            }
        }
        print("PASS: swarm grid packing/slots/strip invariants across the size matrix")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='claudebar-swarm-grid-') as tmp:
    path = Path(tmp) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(tmp) / 'regression'
    subprocess.run(['swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macos15.0',
                    str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
