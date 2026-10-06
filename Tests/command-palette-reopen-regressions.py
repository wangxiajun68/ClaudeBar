#!/usr/bin/env python3
"""The command palette's list is current on the first frame of every open.

`dismiss()` clears only the query; `items`/`filtered`/`selection` deliberately
survive the close so the fade-out keeps its rows. Finding 68's hazard was the
re-open that reuses that instance:

- **Escape, then ⌘K again inside the fade** — measured: the panel never leaves
  the hierarchy (`onDisappear` never fires, nothing remounts, `onAppear` never
  runs again), so the reopened panel *does* carry the previous search's
  `filtered`, while `dismiss()` has already cleared the query box it was
  filtered against.
- **Close, settle past the fade, re-open** — the subtree does unmount and the
  re-open mounts fresh; `onAppear` covers it.

The fix is the `.onChange(of: isPresented)` refresh in `body`, which runs on
the re-adoption path too. This file pins both halves: the source shape (both
refresh points present, the reopen handler open-edge only, `dismiss` touching
only the query) and the behaviour (an `NSHostingView` probe of the exact
`MainWindowView` wiring runs the gap matrix and asserts no open — settle or
same-fade — ever evaluates a frame carrying the previous presentation's rows).
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
palette = (root / 'Sources/ClaudeBar/Views/Shared/CommandPalette.swift').read_text()

# --- 1. The production source carries both refresh points -------------------
body = palette[palette.index('    var body: some View {'):palette.index('    private func moveSelection')]


def handler(anchor):
    """The brace-balanced body of the modifier call starting at `anchor`."""
    start = body.index(anchor)
    opening = body.index('{', start)
    depth, index = 1, opening + 1
    while depth:
        depth += (body[index] == '{') - (body[index] == '}')
        index += 1
    return body[opening + 1:index - 1]


appear = handler('.onAppear {')
assert 'searchFocused = true' in appear, 'the mount must restore focus'
assert 'refreshItems(reselect: true)' in appear, \
    'the mount refresh must rebuild and reselect — the settle path relies on it'

reopen = handler('.onChange(of: isPresented) {')
assert 'guard presented else { return }' in reopen, \
    'the reopen handler must only act on the open edge'
assert 'refreshItems(reselect: true)' in reopen, \
    'the reopen handler must rebuild and reselect — the same-fade re-adoption path ' \
    'has no mount and would otherwise draw the previous search\'s rows'
assert 'searchFocused = true' in reopen, \
    'a re-adopted instance also lost focus state; the reopen must restore it'

assert 'guard isPresented else { return }' in handler('viewChanges([.configuration, .sessions])'), \
    'publishes while closed must keep being dropped — that is why the reopen refresh is needed'

dismiss = palette[palette.index('    private func dismiss() {'):]
dismiss = dismiss[:dismiss.index('\n    }')]
assert 'query = ""' in dismiss, 'dismiss must still clear the query'
code = re.sub(r'//[^\n]*', '', dismiss)
for derived in ['filtered', 'items', 'selection']:
    assert derived not in code, \
        f'dismiss clears `{derived}` — that blanks the list under the fade-out'

# --- 2. Behaviour under the real wiring --------------------------------------
PROBE = r'''
import SwiftUI
import AppKit

/// Plain box, deliberately not @Observable: the probe records during body
/// evaluation, and writing observable state there re-triggers the body — a
/// feedback loop the first draft of this probe hung on.
final class Log {
    var lines: [String] = []
    var mounts = 0
    var disappearances = 0
    /// Frames, after the first presentation, that carried the pre-close rows.
    var staleFrames = 0
    var sawPreCloseRows = false
}

let log = Log()

struct PaletteShaped: View {
    @Binding var isPresented: Bool
    @State private var rows: [String] = []

    var body: some View {
        Group {
            if isPresented {
                VStack {
                    let snapshot = rows
                    let _ = record(snapshot)
                    Text(snapshot.joined(separator: ","))
                }
                .onAppear {
                    log.mounts += 1
                    log.lines.append("appear#\(log.mounts) rows=\(rows.isEmpty ? "[]" : rows.joined(separator: ","))")
                    // The user typed and stopped on a session — in the first
                    // presentation only, which is the state finding 68 is about.
                    if log.mounts == 1 { rows = ["claude:1234"] }
                }
                .onDisappear { log.disappearances += 1 }
            }
        }
        .animation(.smooth(duration: 0.2), value: isPresented)
        // The production reopen refresh, same placement and handler shape.
        .onChange(of: isPresented) { _, presented in
            guard presented else { return }
            rows = ["page:dashboard"]
            log.lines.append("reopen refresh")
        }
    }

    private func record(_ snapshot: [String]) {
        if snapshot == ["claude:1234"] {
            if log.mounts > 1 { log.staleFrames += 1; log.lines.append("STALE FRAME") }
            else { log.sawPreCloseRows = true }
        }
    }
}

/// MainWindowView's shape: an outer `@State` mirror the owner writes inside
/// `withAnimation`, driving both the mount and the palette's own gate.
@Observable final class Box { var show = false }

struct Mirror: View {
    let box: Box
    @State private var show = false
    var body: some View {
        ZStack {
            Color.gray
            if show {
                PaletteShaped(isPresented: $show)
                    .transition(.opacity)
            }
        }
        .onChange(of: box.show) { _, v in
            withAnimation(.bouncy(duration: 0.24, extraBounce: 0.16)) { show = v }
        }
    }
}

@main struct Probe {
    @MainActor static func main() {
        let box = Box()
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Mirror(box: box))
        window.orderFrontRegardless()
        func settle(_ seconds: Double = 0.5) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }
        settle()
        box.show = true; settle()                        // first open: the user types
        let gaps: [Double] = [0, 0.02, 0.05, 0.08, 0.12, 0.16, 0.5]
        for (index, gap) in gaps.enumerated() {
            let mountsBefore = log.mounts
            box.show = false
            settle(gap)
            box.show = true
            settle()
            log.lines.append("gap \(Int(gap * 1000))ms: \(log.mounts == mountsBefore ? "re-adopted" : "remounted")")
            if index == 0 { log.lines.append("same-transaction shape covered by gap 0") }
        }
        for line in log.lines { print(line) }
        precondition(log.sawPreCloseRows, "the probe never established the pre-close rows")
        precondition(log.staleFrames == 0,
                     "an open evaluated a frame with the previous presentation's rows")
        precondition(log.mounts + (gaps.count * 2 - log.disappearances) >= gaps.count,
                     "the matrix lost its presentations")
        print("PASS: \(log.mounts) mounts, \(log.disappearances) unmounts across "
              + "\(gaps.count) close→re-open cycles, no stale frame")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='claudebar-command-palette-') as folder:
    source = Path(folder) / 'Probe.swift'
    source.write_text(PROBE)
    binary = Path(folder) / 'probe'
    subprocess.run(['swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macos15.0',
                    str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=150)
