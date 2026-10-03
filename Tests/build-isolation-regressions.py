#!/usr/bin/env python3
"""Exercise real channel/path/proxy code with temporary storage and mocked process I/O.
Never launch an app, signal a process, change real preferences or network settings.
"""
from pathlib import Path
import os
import json
import sys
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
shared = (root / 'Sources/Shared/BuildChannel.swift').read_text()
paths = (root / 'Sources/ClaudeBar/Utils/FilePaths.swift').read_text()
paths = paths.replace('FileManager.default.homeDirectoryForCurrentUser', 'fixtureHome')
paths = paths.replace('FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]', 'fixtureSupport')
proxy = (root / 'Sources/ClaudeBar/Utils/VpnSystemProxyController.swift').read_text()
# Replace only the external-process transport. All system-write entry guards are real.
proxy = proxy[:proxy.index('// MARK: - Process helper')]
# The installers' one shared dependency is spliced too: their privileged
# scripts build `ShellQuote.single(...)`, and a stub here would be a stub of
# the escaping under test.
helpers = '\n'.join((root / 'Sources/ClaudeBar/Utils' / name).read_text() for name in
                    ['ShellQuote.swift', 'FanHelperInstaller.swift', 'BatteryHelperInstaller.swift'])
stubs = r'''
struct AppPreferences {
    static let shared = AppPreferences()
    var vpnEnabled: Bool { true }
    var vpnSystemProxyEnabled: Bool { true }
    var vpnGuardEnabled: Bool { true }
    var vpnTunEnabled: Bool { true }
    var vpnMixedPort: Int { BuildChannel.vpnMixedPort }
}
@MainActor final class VpnManager {
    static let shared = VpnManager()
    var isRunning: Bool { true }
    func log(_ text: String) {}
}
enum VpnProviderDirect { static func hosts() -> [String] { [] } }
extension Process {
    struct RunResult { let status: Int32; let output: String }
    nonisolated(unsafe) static var calls = 0
    static func runAndRead(_ path: String, args: [String]) -> RunResult {
        calls += 1
        return .init(status: 0, output: "Wi-Fi\n")
    }
}
let fixtureHome = URL(fileURLWithPath: CommandLine.arguments[1])
let fixtureSupport = fixtureHome.appendingPathComponent("Library/Application Support")
@main struct Regression {
    @MainActor static func main() throws {
        precondition(BuildChannel.bundleID == CommandLine.arguments[2])
        let productionSupport = fixtureSupport.appendingPathComponent("ClaudeBar")
        let productionClaude = fixtureHome.appendingPathComponent(".claude")
        let productionCodex = fixtureHome.appendingPathComponent(".codex")
        precondition(FilePaths.appGroupID == BuildChannel.widgetBundleID)
        precondition(FilePaths.appSupportDir.lastPathComponent == BuildChannel.appName)
        if !BuildChannel.allowsSystemIntegration {
            precondition(FilePaths.appSupportDir != productionSupport)
            precondition(FilePaths.claudeDir != productionClaude)
            precondition(FilePaths.codexDir != productionCodex)
            precondition(FilePaths.vpnCoreBin.path.hasPrefix(FilePaths.appSupportDir.path + "/"))
            precondition(FilePaths.proxyTokenFile.path.hasPrefix(FilePaths.appSupportDir.path + "/"))
            try FileManager.default.createDirectory(at: FilePaths.claudeDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: FilePaths.codexDir, withIntermediateDirectories: true)
            try "isolated".write(to: FilePaths.settingsFile, atomically: true, encoding: .utf8)
            try "isolated".write(to: FilePaths.codexConfigFile, atomically: true, encoding: .utf8)
            precondition(!BatteryHelperInstaller.isInstalled())
            precondition(BatteryHelperInstaller.installIfNeeded() == BuildChannel.restrictionMessage)
            precondition(FanHelperInstaller.setAutomatic(fanID: 0) == BuildChannel.restrictionMessage)
            precondition(FanHelperInstaller.resetAll() == BuildChannel.restrictionMessage)
            // A stale marker must never cause non-production DNS restoration.
            try "sentinel".write(to: VpnTunDnsHelper.dnsMarker, atomically: true, encoding: .utf8)
            precondition(VpnSystemProxyController.applySystemProxyNow(port: 12345) == BuildChannel.restrictionMessage)
            VpnSystemProxyController.clearSystemProxyNow()
            VpnTunDnsHelper.setSystemDNSNow()
            VpnTunDnsHelper.restoreSystemDNSNow()
            precondition(Process.calls == 0, "isolated version executed system networking command")
            precondition(try String(contentsOf: VpnTunDnsHelper.dnsMarker, encoding: .utf8) == "sentinel")
        } else {
            precondition(FilePaths.appSupportDir.path == productionSupport.path)
            precondition(FilePaths.claudeDir.path == productionClaude.path)
            precondition(FilePaths.codexDir.path == productionCodex.path)
        }
        print("PASS: \(BuildChannel.name) identity, storage, system networking isolation")
    }
}
'''
# Throwing reads cannot be evaluated inside precondition's nonthrowing autoclosure.
stubs = stubs.replace('precondition(try String(contentsOf: VpnTunDnsHelper.dnsMarker, encoding: .utf8) == "sentinel")', 'let marker = try String(contentsOf: VpnTunDnsHelper.dnsMarker, encoding: .utf8)\n            precondition(marker == "sentinel")')
identities = []
executables = []
installs = []
names = []
# `BuildChannel` asks "is the release macro defined", not "is dev defined", so
# a compile with **no** channel macro lands on dev. That default is the whole
# fail-safe direction of every gate in the file (`allowsSystemIntegration`,
# `promptsForSystemPermissions`, the data directories): a build whose author
# forgot the flags, or a stray `swiftc` of the file, must restrict itself —
# never start the VPN, rewrite proxy/DNS, install helpers or write durable TCC
# grants. The list below is therefore (channel, macro) pairs, with the macro
# omitted for the unlabelled compile; `None` is a label, not a flag.
for channel, flag in [('dev', 'CLAUDEBAR_DEV'), ('release', 'CLAUDEBAR_RELEASE'), ('dev', None)]:
    # An unlabelled compile still has to name a real identity for the fixture's
    # path assertions; it is the dev identity because that is the claim under
    # test, not because the config defines it.
    config_channel = channel if flag else 'dev'
    env = dict(os.environ, CLAUDEBAR_CHANNEL=config_channel, CLAUDEBAR_SKIP_INSTALL='1', CLAUDEBAR_PACKAGE='0')
    result = subprocess.run(['bash', '-c', 'PROJECT_DIR="$PWD"; source Sources/build-config.sh; printf "%s\\n" "$APP_NAME" "$BUNDLE_ID" "$WIDGET_ID" "$APP_BUNDLE" "$APP_EXECUTABLE" "${SWIFT_FLAGS[*]}" "$INSTALL_DIR"'], cwd=root, env=env, check=True, capture_output=True, text=True)
    config = result.stdout.splitlines()
    identities.append(config[1])
    executables.append(config[4])
    installs.append(config[6])
    names.append(config[0])
    if flag:
        assert flag in config[5]
    else:
        # The real build path always names a channel macro — asserted here for
        # the unlabelled iteration too, so `build-config.sh` losing a flag
        # cannot make this case pass by accident. The harness compile below is
        # the only place both macros are dropped, which is the stray-`swiftc`
        # shape the case exists to cover.
        assert ('CLAUDEBAR_DEV' in config[5]) != ('CLAUDEBAR_RELEASE' in config[5]), (
            f'the build config must name exactly one channel macro: {config[5]}')
    assert f'.build/{config_channel}/' in config[3]
    assert config[2] == config[1] + '.widget'
    assert '-O' in config[5]
    assert ('-incremental' in config[5]) == (config_channel == 'dev')
    with tempfile.TemporaryDirectory(prefix=f'claudebar-isolation-{channel}-') as tmp:
        tmp = Path(tmp)
        source = tmp / 'Regression.swift'
        source.write_text(shared + '\n' + paths + '\n' + proxy + '\n' + helpers + '\n' + stubs)
        binary = tmp / 'regression'
        command = ['swiftc', '-parse-as-library']
        if flag:
            command += ['-D', flag]
        command += [str(source), '-o', str(binary)]
        compile = subprocess.run(command, capture_output=True, text=True)
        assert compile.returncode == 0, (
            f'{channel} identity failed to compile{"" if flag else " with no channel macro"}: '
            f'{compile.stderr.strip()}')
        subprocess.run([str(binary), str(tmp / 'home'), config[1]], check=True)
        # Printed, not assumed: this is where the measured channel lands on the
        # record even when every precondition above happened to pass.
        probe = f'''import Foundation
let fixtureHome = URL(fileURLWithPath: CommandLine.arguments[1])
let fixtureSupport = fixtureHome.appendingPathComponent("Library/Application Support")
@main struct Probe {{
    static func main() {{
        print("BuildChannel=\\(BuildChannel.name) integration=\\(BuildChannel.allowsSystemIntegration) "
            + "prompts=\\(BuildChannel.promptsForSystemPermissions) bundle=\\(BuildChannel.bundleID) "
            + "support=\\(FilePaths.appSupportDir.lastPathComponent) group=\\(FilePaths.appGroupID) "
            + "claude=\\(FilePaths.claudeDir.lastPathComponent)")
    }}
}}
'''
        probe_source = tmp / 'Probe.swift'
        probe_source.write_text(shared + '\n' + paths + '\n' + probe)
        probe_binary = tmp / 'probe'
        command = ['swiftc', '-parse-as-library']
        if flag:
            command += ['-D', flag]
        command += [str(probe_source), '-o', str(probe_binary)]
        subprocess.run(command, check=True)
        measured = subprocess.run([str(probe_binary), str(tmp / 'home')], check=True, capture_output=True, text=True)
        print(measured.stdout.strip())
        if channel != 'release':
            assert not (tmp / 'home/.claude/settings.json').exists()
            assert not (tmp / 'home/.codex/config.toml').exists()
# The unlabelled compile's identity was measured above; assert it equals the
# labelled dev identity field-by-field rather than trusting the prose.
assert names[2] == names[0] and identities[2] == identities[0], (
    f'an unlabelled compile does not claim the dev identity: {names[2]}/{identities[2]} '
    f'vs dev {names[0]}/{identities[0]}')
assert identities[2] != identities[1], 'an unlabelled compile must never claim the release bundle id'
# Channel identity is not only the bundle id: `Tools/check-bundle.py` pins
# CFBundleExecutable per channel at package time, but the installer path and the
# app name have no other check anywhere, and a dev build that shares any of
# these with the release is exactly the "two versions cannot coexist / installing
# dev replaces the shipped app" failure this suite exists to prevent. Each is
# compared explicitly rather than via `len(set(...)) == 2`, which would pass
# again if the *same* collision were made on both channels.
assert len(set(identities)) == 2, f'dev and release share a bundle id: {identities}'
assert len(set(names)) == 2, (
    f'dev and release share the app name "{names[0]}": the Finder/Dock identity would match and '
    'a user would not be able to tell which build is running')
assert len(set(executables)) == 2, (
    f'dev and release share the executable name "{executables[0]}": the two apps would '
    'overwrite each other in the same process namespace and a dev build would replace the '
    'shipped binary')
assert installs[0] == os.path.expanduser('~/Applications'), (
    f'dev installs to {installs[0]} — it must stay under the user\'s Applications so `make install` '
    'can never overwrite /Applications/ClaudeBar.app')
assert installs[1] == '/Applications', f'release installs to {installs[1]}, not /Applications'
for channel, package in [('invalid', '0'), ('dev', '1'), ('test', '0')]:
    env = dict(os.environ, CLAUDEBAR_CHANNEL=channel, CLAUDEBAR_PACKAGE=package)
    result = subprocess.run(['bash', '-c', 'PROJECT_DIR="$PWD"; source Sources/build-config.sh'], cwd=root, env=env, capture_output=True)
    assert result.returncode != 0
# Verify cache invalidation and Swift output identity using a temporary project.
with tempfile.TemporaryDirectory(prefix='claudebar-build-cache-') as directory:
    fixture = Path(directory)
    (fixture / 'Tools').mkdir()
    (fixture / 'Sources/A').mkdir(parents=True)
    (fixture / 'Sources/B').mkdir(parents=True)
    (fixture / 'VERSION').write_text('1.0.0')
    tool = fixture / 'Tools/build-cache.py'
    tool.write_text((root / 'Tools/build-cache.py').read_text())
    first = fixture / 'Sources/A/Model.swift'
    second = fixture / 'Sources/B/Model.swift'
    first.write_text('struct A {}')
    second.write_text('struct B {}')
    def fingerprint(flags='-O'):
        return subprocess.check_output([sys.executable, str(tool), 'fingerprint', '-', flags], text=True)
    initial = fingerprint()
    assert initial == fingerprint()
    assert initial != fingerprint('-Onone')
    (fixture / '.build').mkdir()
    (fixture / '.build/cache').write_text('generated objects are not inputs')
    assert initial == fingerprint()
    first.write_text('struct A { var value: Int }')
    assert initial != fingerprint()
    mapping_path = subprocess.check_output([sys.executable, str(tool), 'filemap', str(fixture / '.build/objects'), str(first), str(second)], text=True).strip()
    mapping = json.loads(Path(mapping_path).read_text())
    assert mapping[str(first)]['object'] != mapping[str(second)]['object']
    assert mapping[str(first)]['swift-dependencies'] != mapping[str(second)]['swift-dependencies']
    # Exercise the real driver across initial build, changed source, and relink
    # after deleting the app binary. Stable module paths are required with -g.
    first = first.rename(first.with_name('Main.swift'))
    second = second.rename(second.with_name('Value.swift'))
    mapping_path = subprocess.check_output([sys.executable, str(tool), 'filemap', str(fixture / '.build/objects'), str(first), str(second)], text=True).strip()
    first.write_text('@main struct Main { static func main() { print(value()) } }')
    second.write_text('func value() -> Int { 42 }')
    binary = fixture / '.build/cache-app'
    module = fixture / '.build/objects/CacheApp.swiftmodule'
    args = ['swiftc', '-emit-executable', '-O', '-g', '-incremental', '-enable-batch-mode',
            '-j', '2', '-emit-module-path', str(module), '-output-file-map', mapping_path,
            '-o', str(binary), str(first), str(second)]
    for iteration in range(3):
        if iteration == 1: second.write_text('func value() -> Int { 43 }')
        if binary.exists(): binary.unlink()
        subprocess.run(args, check=True)
        assert subprocess.check_output([str(binary)], text=True).strip() == ('42' if iteration == 0 else '43')
print('PASS: cache invalidation by content/flags, generated-output exclusion, unique Swift object/dependency paths')
build = (root / 'Sources/build.sh').read_text()
assert 'pkill' not in build and 'killall' not in build
manager = (root / 'Sources/ClaudeBar/Utils/VpnManager.swift').read_text()
start = manager[manager.index('    func startCore() {'):]
assert start.index('guard BuildChannel.allowsSystemIntegration') < start.index('Self.reapOrphanCore()')
print('PASS: safe build defaults, channel validation, packaging constraints, VPN launch guard')
