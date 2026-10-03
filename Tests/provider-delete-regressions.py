#!/usr/bin/env python3
"""Deleting the *active* provider must take the client off it.

`ProviderStore.deleteProvider` removes the row and, with `reassignActive: true`,
merely clears `activeProviderID`. It never touches the client config, so the
page-level delete used to leave `settings.json` (Claude) / `config.toml` +
`auth.json` (Codex) pointing at a vendor the app no longer lists — and no row
carried the id any more, so nothing could ever switch back off it. The sibling
select paths (`restoreOfficial`, `activate`) do restore the official
configuration, and the twin-removal path in `ProviderProfileSync` already
restores when the deleted row was live.

Two halves, because the defect spans two layers:

  * a source assertion on `ProvidersView.deleteConnection` — the page must ask
    the store to restore the official configuration, conditionally on the
    removed row being the live one, and *before* removing it;
  * the production `deleteProvider` / `restoreOfficial` bodies (spliced from
    `ProviderStore.swift`) running against the real `SettingsManager` with
    temporary paths, so the end state is read back off the disk the app writes.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = root / 'Sources/ClaudeBar'

# --- 1. The page's delete asks for the restore, ahead of the removal ---------
view = (root / 'Sources/ClaudeBar/Views/Pages/ProvidersView.swift').read_text()
start = view.index('    private func deleteConnection(')
end = view.index('\n    }\n', start) + len('\n    }\n')
page = view[start:end]
for client in ['providerStore', 'codexStore']:
    assert f'{client}.restoreOfficial()' in page, \
        f'deleteConnection no longer restores the official config on the {client} side'
assert page.index('providerStore.restoreOfficial()') < page.index('providerStore.deleteProvider('), \
    'the Claude restore must happen before the row is removed'
assert page.index('codexStore.restoreOfficial()') < page.index('codexStore.deleteProvider('), \
    'the Codex restore must happen before the row is removed'
assert 'activeProviderID == id' in page, \
    'the restore must be conditional — deleting an inactive row must not touch the live config'

# --- 2. Production store bodies against real persistence ---------------------
swift = '\n'.join((sources / name).read_text() for name in [
    'Models/Preset.swift',
    'Models/Provider.swift',
    'Models/SettingsManager.swift',
    'Utils/PrivateFileWriter.swift',
]) + r'''
enum FilePaths {
    static let claudeDir = URL(fileURLWithPath: CommandLine.arguments[1])
    static let settingsFile = claudeDir.appendingPathComponent("settings.json")
}

/// A minimal store around the **production** `deleteProvider`, spliced out of
/// `ProviderStore.swift` by text with only the `propagate` branch dropped — the
/// twin-store propagation is what this fixture cannot host, and it does not
/// touch the client config either way, which is what this suite is about.
struct StoreFixture {
    var providers: [Provider] = []
    var activeProviderID: UUID? = nil
    var collapsedProviderIDs: Set<UUID> = []
    var errorMessage: String?
    var currentEnv: EnvConfig?
    var hasSettingsFile = false
    @discardableResult func saveProviders() -> Bool { true }
    func refreshSharedProxy() {}
    func refreshBalance() {}
    func writeWidgetSnapshot() {}
DELETE_PROVIDER
}
@main struct Regression {
    static func main() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: FilePaths.claudeDir, withIntermediateDirectories: true)
        let model = ModelConfig(name: "fixture-model")
        let gateway = Provider(name: "gateway", authToken: "fixture-key",
                               baseURL: "https://gateway.example", models: [model])
        let backup = Provider(name: "backup", authToken: "fixture-key",
                              baseURL: "https://backup.example", models: [model])

        func env() throws -> [String: Any] {
            let data = try Data(contentsOf: FilePaths.settingsFile)
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return json["env"] as? [String: Any] ?? [:]
        }

        var store = StoreFixture(providers: [gateway, backup], activeProviderID: gateway.id)
        try SettingsManager.writeSettings(env: EnvConfig(
            ANTHROPIC_AUTH_TOKEN: "fixture-key", ANTHROPIC_BASE_URL: "https://gateway.example",
            ANTHROPIC_MODEL: "fixture-model"))
        let activated = try env()
        precondition(activated["ANTHROPIC_BASE_URL"] as? String == "https://gateway.example")

        // What the page used to do: remove the row only. The client config
        // stays pointed at the deleted connection — the defect.
        store.deleteProvider(gateway)
        precondition(store.activeProviderID == backup.id, "the remaining row is adopted")
        let orphaned = try env()
        precondition(orphaned["ANTHROPIC_BASE_URL"] as? String == "https://gateway.example",
                     "deleting alone leaves settings.json on the dead provider — this is what the page must repair")

        // What the page does now: when the deleted row was live, restore the
        // official configuration first, exactly like 切回官方 does. Only then is
        // the row removed — the list goes back to 官方 while the remaining
        // 配置 stays saved and unactivated, which is the same end state the
        // twin-removal path (`ProviderProfileSync`) produces.
        try SettingsManager.writeSettings(env: EnvConfig(
            ANTHROPIC_AUTH_TOKEN: "fixture-key", ANTHROPIC_BASE_URL: "https://gateway.example",
            ANTHROPIC_MODEL: "fixture-model"))
        var live = StoreFixture(providers: [gateway, backup], activeProviderID: gateway.id)
        if live.activeProviderID == gateway.id { live.restoreOfficial() }
        live.deleteProvider(gateway)
        precondition(live.providers == [backup], "only the deleted row is gone")
        precondition(live.activeProviderID == nil, "the client was on the deleted row, so it is back on 官方")
        let restored = try env()
        precondition(restored["ANTHROPIC_BASE_URL"] == nil, "the official overlay is gone")
        precondition(restored["ANTHROPIC_AUTH_TOKEN"] == nil, "the dead provider's key is gone")
        precondition(restored["ANTHROPIC_MODEL"] == nil, "the dead provider's model is gone")
        precondition((SettingsManager.readSettings()?.ANTHROPIC_BASE_URL ?? "") == "",
                     "the app reads the official configuration back")

        // And the reason the restore has to come first: the store's own
        // reassignment nominates the next row *without* writing that row's
        // config, so on its own it would leave the list claiming `backup` is
        // active while settings.json still points at the deleted gateway.
        var bare = StoreFixture(providers: [gateway, backup], activeProviderID: gateway.id)
        try SettingsManager.writeSettings(env: EnvConfig(
            ANTHROPIC_AUTH_TOKEN: "fixture-key", ANTHROPIC_BASE_URL: "https://gateway.example",
            ANTHROPIC_MODEL: "fixture-model"))
        bare.deleteProvider(gateway)
        let stranded = try env()
        precondition(bare.activeProviderID == backup.id && stranded["ANTHROPIC_BASE_URL"] as? String == "https://gateway.example",
                     "a bare delete nominates a row it never wrote — the page must restore ahead of it")

        // Deleting a row that is not live must not touch the config at all.
        var inactive = StoreFixture(providers: [gateway, backup], activeProviderID: backup.id)
        try SettingsManager.writeSettings(env: EnvConfig(
            ANTHROPIC_AUTH_TOKEN: "fixture-key", ANTHROPIC_BASE_URL: "https://backup.example",
            ANTHROPIC_MODEL: "fixture-model"))
        inactive.deleteProvider(gateway)
        let untouched = try env()
        precondition(untouched["ANTHROPIC_BASE_URL"] as? String == "https://backup.example",
                     "an inactive delete must leave the live configuration alone")
        precondition(inactive.activeProviderID == backup.id)
        print("PASS: deleting the live provider restores the official client config, an inactive delete does not, and the page's restore precedes the removal on both clients")
    }
}
'''
# The delete body is sliced, not restated: a fixture that reimplements it can
# agree with the page and still disagree with the store the page actually calls.
_store = (sources / 'Models/ProviderStore.swift').read_text()
_start = _store.index('    func deleteProvider(')
_end = _store.index('\n    }\n', _start) + len('\n    }\n')
_delete = _store[_start:_end].replace('    func deleteProvider', '    mutating func deleteProvider', 1)
# `propagate` reaches for the twin store and the main actor; neither is part of
# what this suite asserts, and the branch does not write the client config.
_delete = _delete.replace("""        if propagate, let profileID {
            MainActor.assumeIsolated { ProviderProfileSync.removeCodex(profileID: profileID, store: self) }
        }
""", """        _ = profileID
""")
_delete = _delete.replace('    MainActor.assumeIsolated', '    ')
assert 'ProviderProfileSync' not in _delete and 'mutating func deleteProvider' in _delete, \
    'the delete slice changed shape; re-point this extraction'
swift = swift.replace('DELETE_PROVIDER', _delete + '''    /// The production `restoreOfficial` body, spliced: it strips the managed
    /// keys and clears the active tile through the same `SettingsManager` the
    /// app's 切回官方 button uses.
    mutating func restoreOfficial() {
        do { try SettingsManager.restoreOfficial() } catch { errorMessage = "restore failed"; return }
        activeProviderID = nil
        currentEnv = SettingsManager.readSettings()
        hasSettingsFile = FileManager.default.fileExists(atPath: FilePaths.settingsFile.path)
    }
''')

with tempfile.TemporaryDirectory(prefix='claudebar-provider-delete-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary), folder], check=True)
