#!/usr/bin/env python3
"""Run SwiftUI layout/Combine regressions against extracted production methods.
Uses only Apple's SDK; no app launch, network access, or preference mutations.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
tile = (root / 'Sources/ClaudeBar/Views/Shared/Tile.swift').read_text()
grid = tile[tile.index('struct EqualRowGrid: Layout'):]
store = (root / 'Sources/ClaudeBar/Models/ProviderStore.swift').read_text()
start = store.index('    private func recordHeartbeats(')
end = store.index('\n    }', start) + len('\n    }')
heartbeat = store[start:end].replace('private func', 'func')
swift = r'''
import SwiftUI
import Combine

final class HeartbeatFixture: ObservableObject {
    static let heartbeatLength = 24
    @Published var heartbeats: [Int: [Bool]] = [:]
HEARTBEAT
}
GRID
@main struct Regression {
    @MainActor static func main() {
        _ = NSApplication.shared
        let store = HeartbeatFixture()
        store.heartbeats = [1: Array(repeating: false, count: 24),
                            2: Array(repeating: false, count: 24)]
        var publishes = 0
        let subscription = store.objectWillChange.sink { publishes += 1 }
        store.recordHeartbeats([1: false, 2: false])
        precondition(publishes == 0, "Unchanged idle trails must not publish")
        store.recordHeartbeats([1: true, 2: true])
        precondition(publishes == 1, "Multiple changes must publish once")
        precondition(store.heartbeats[1]?.count == 24)
        store.recordHeartbeats([2: true])
        precondition(store.heartbeats[1] == nil, "Dead sessions must be pruned")
        store.recordHeartbeats([:])
        precondition(store.heartbeats.isEmpty)
        let finalCount = publishes
        store.recordHeartbeats([:])
        precondition(publishes == finalCount)
        withExtendedLifetime(subscription) {}

        func grid(_ width: CGFloat, _ text: String, _ columns: Int) -> some View {
            EqualRowGrid(spacing: 1, minColumnWidth: 0, fixedColumns: columns) {
                ForEach(0..<columns, id: \.self) { _ in
                    Text(text).font(.system(size: 14)).padding(9)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(width: width)
        }
        for columns in [4, 5] {
            let renderer = ImageRenderer(content: grid(400, "100%", columns))
            let initial = renderer.cgImage!
            precondition(initial.width == 400)
            renderer.content = grid(400, String(repeating: "Long content ", count: 12), columns)
            let expanded = renderer.cgImage!
            precondition(expanded.height > initial.height, "Cache must invalidate when content changes")
            renderer.content = grid(620, "100%", columns)
            precondition(renderer.cgImage!.width == 620, "Cache must follow width changes")
            renderer.content = grid(400, "100%", columns)
            precondition(renderer.cgImage!.height == initial.height, "Shrinking must restore original geometry")
        }
        print("PASS: unchanged/changed/pruned/empty heartbeat publications; 4/5-column layout, content invalidation and resize")

        // The model-price card's added-slug draft was a ghost row: it lingered
        // after the edit was over, editing nothing. The visibility gate is one
        // predicate, executed here from the production source; the add path's
        // shape (which slugs take the draft at all) is pinned against the same
        // source below.
        var card = DraftFixture()
        precondition(!card.draftRowVisible("glm-5-new"), "with no draft there is nothing to draw")
        card.rows = ["glm-4", "glm-5"]
        card.editing = "glm-5-new"
        precondition(card.draftRowVisible("glm-5-new"),
                     "an edit of a slug the table is not drawing must show the draft")
        card.editing = "glm-5"
        precondition(!card.draftRowVisible("glm-5-new"),
                     "the draft belongs to the slug being edited, not to any slug")
        card.editing = nil
        precondition(!card.draftRowVisible("glm-5-new"),
                     "collapsing the row's editor (editing = nil) must retire the draft — the ghost row")
        card.editing = "glm-5.9-flash"
        precondition(card.draftRowVisible("glm-5.9-flash"),
                     "a slug that is not a real row is what the draft exists for")
        card.rows = ["glm-4", "glm-5", "glm-5.9-flash"]
        precondition(!card.draftRowVisible("glm-5.9-flash"),
                     "once the slug is a real row the table mounts the editor; the draft must go")
        print("PASS: the model-price draft row is drawn only while an edit of a slug outside the table is in progress")
    }
}
'''.replace('HEARTBEAT', heartbeat).replace('GRID', grid)

# --- The model-price draft predicate, sliced from the production file --------
#
# Sliced rather than restated: a fixture that reimplements the decision can
# agree with itself and still disagree with the card Settings mounts. The
# predicate reads only `rows` and `editing`, so the fixture holds those two
# under the same names. (The `rows` a `!rows.contains(slug)` term reaches here
# is the *visible* table; the catalog-wide check lives in `startAdding`, which
# this suite pins textually below — its body also writes four pieces of SwiftUI
# state with no home in a fixture.) The second term asserted below is the one
# that retires a ghost draft: a search word or a manual collapse can move a slug
# into `rows` without the editor ever closing, and the draft used to stay up.
price = (root / 'Sources/ClaudeBar/Views/Shared/ModelPriceCard.swift').read_text()


predicate = price[price.index('    private func shouldDrawDraft('):]
predicate = predicate[:predicate.index('\n    }\n') + len('\n    }\n')]
predicate = predicate.replace('private func shouldDrawDraft', 'func draftRowVisible', 1)
assert '!rows.contains(slug)' in predicate and 'editing == slug' in predicate, \
    'the draft predicate changed shape; re-point this extraction'
# The add path can only be pinned by text: it writes `editing`, `draftSlug`,
# `adding` and `addSlug` — four pieces of view state with no home in a fixture —
# and this suite's point is that the draft is decided by the *catalog* (a slug
# with no row) and gated on an edit being in progress. The assertions above
# execute the gate; these hold the decision.
for needle, reason in [
        ('draftSlug = catalog.allSlugs.contains(slug) ? nil : slug',
         'the draft must be chosen from the whole catalog, not the filtered rows'),
        ('editing = slug',
         'the add path must open the editor on the slug it resolves')]:
    assert needle in price, f'startAdding changed shape: {reason}'

fixture = '''struct DraftFixture {
    var rows: [String] = []
    var editing: String? = nil
HAS_DRAFT
}
'''.replace('HAS_DRAFT', predicate)
swift = swift.replace('@main struct Regression {', fixture + '\n@main struct Regression {')

with tempfile.TemporaryDirectory(prefix='claudebar-ui-tests-') as folder:
    source = Path(folder) / 'Regression.swift'
    source.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
