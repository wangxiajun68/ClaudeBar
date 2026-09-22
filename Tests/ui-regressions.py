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
    }
}
'''.replace('HEARTBEAT', heartbeat).replace('GRID', grid)
with tempfile.TemporaryDirectory(prefix='claudebar-ui-tests-') as folder:
    source = Path(folder) / 'Regression.swift'
    source.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
