#!/usr/bin/env python3
"""The Settings → 权限与隐私 status mapping, executed without touching TCC.

`PermissionStatus.denied` exists so the settings row can say 「已拒绝」 and
offer the jump to System Settings, but the screen-recording row never produced
it: `CGPreflightScreenCaptureAccess` is binary, and the old mapping sent every
"off" to `.notDetermined`, so the提示 and the button branches
(`PermissionsSection.swift:56/83`) were unreachable for that permission. The
only place the denial surfaced was `ScreenshotHotKey.lastError` after a real
⌘⇧A.

This suite slices the mapping — `PermissionStatus` and the pure
`screenRecordingStatus(preflight:userEnabled:promptsForSystemPermissions:)` —
and runs the whole truth table. It also pins the two things that must not move
while fixing that:

  * the *request* stays where it was: the screen-recording prompt is issued
    only through `PermissionCenter.request(_:)`, which is reached from
    `setEnabled` behind `BuildChannel.promptsForSystemPermissions`, so a dev
    build records the user's intent without writing a TCC grant;
  * `PermissionStatus`'s four remaining labels keep their wording — the denied
    row now actually shows one of them.

No app, no window, no CGPreflight / CGRequest call: the mapping is pure, and
the real API is never invoked (that is what makes this suite runnable on a dev
machine at all).
"""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[1]
center = (root / 'Sources/ClaudeBar/Utils/PermissionCenter.swift').read_text()


def declaration(text, marker):
    start = text.index(marker)
    end = text.index('{', start)
    depth = 0
    while True:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
        if depth == 0:
            break
    return text[start:end]


status_enum = declaration(center, 'enum PermissionStatus: Equatable {')
mapping = declaration(center, '    static func screenRecordingStatus(').replace(
    'static func screenRecordingStatus(', 'static func screenRecordingStatus(')
assert 'CGPreflightScreenCaptureAccess' not in mapping, \
    'the mapping must be pure — the TCC read stays at the call site'
assert "next[.screenRecording] = Self.screenRecordingStatus(" in center, \
    'refreshStatus must route through the mapping'

# The prompt gate, pinned to the shipped request path: `setEnabled` reaches
# `request(_:)` only behind the build gate, and the screen-recording request
# itself is the only place that raises the TCC prompt.
assert 'if on, BuildChannel.promptsForSystemPermissions { request(permission) }' in center, \
    'the switch must not be able to request outside the build gate'
assert 'if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }' in center, \
    'the screen-recording request stays in request(_:)'
assert center.index('if on, BuildChannel.promptsForSystemPermissions { request(permission) }') \
    < center.index('case .screenRecording:\n            if !CGPreflightScreenCaptureAccess()'), \
    'the request body must sit behind the gate at the call site'

swift = r'''
import Foundation

STATUS_ENUM

enum PermissionFixture {
MAPPING
}

@main struct Regression {
    static func main() {
        // 1. Preflight true is granted, whatever the switch or the build say.
        for enabled in [true, false] {
            for prompts in [true, false] {
                precondition(PermissionFixture.screenRecordingStatus(
                    preflight: true, userEnabled: enabled, promptsForSystemPermissions: prompts) == .granted,
                    "preflight true must read 已授权")
            }
        }
        // 2. Intent on + preflight false in a build that may prompt: the user
        //    answered the system dialog and said no — the row must say so.
        precondition(PermissionFixture.screenRecordingStatus(
            preflight: false, userEnabled: true, promptsForSystemPermissions: true) == .denied,
            "a refused screen-recording request must read 已拒绝")
        // 3. Intent off: nothing was ever asked (the switch is opt-in and off
        //    by default), so there is no denial to report.
        precondition(PermissionFixture.screenRecordingStatus(
            preflight: false, userEnabled: false, promptsForSystemPermissions: true) == .notDetermined,
            "an untouched screen-recording switch must read 未授权")
        // 4. A build that must not prompt (dev) records intent without ever
        //    raising the request, so intent-on cannot mean "denied" there.
        precondition(PermissionFixture.screenRecordingStatus(
            preflight: false, userEnabled: true, promptsForSystemPermissions: false) == .notDetermined,
            "a non-prompting build must not invent a denial")
        precondition(PermissionFixture.screenRecordingStatus(
            preflight: false, userEnabled: false, promptsForSystemPermissions: false) == .notDetermined)

        // 5. The labels the settings row prints for each status.
        precondition(PermissionStatus.granted.label == "已授权")
        precondition(PermissionStatus.denied.label == "已拒绝")
        precondition(PermissionStatus.notDetermined.label == "未授权")
        precondition(PermissionStatus.askOnUse.label == "使用时询问")
        precondition(PermissionStatus.notRequired.label == "无需授权")

        print("PASS: screen-recording status distinguishes refused from never-asked, under both build channels")
    }
}
'''.replace('STATUS_ENUM', status_enum).replace('MAPPING', mapping)

with tempfile.TemporaryDirectory(prefix='claudebar-permission-') as tmp:
    folder = Path(tmp)
    source = folder / 'Regression.swift'
    source.write_text(swift)
    binary = folder / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
