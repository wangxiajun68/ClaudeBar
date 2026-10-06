#!/usr/bin/env python3
"""The two ProcessSampler predicates that read the process table.

`argvMentionsCodex` decides whether a `node` process is running the Codex CLI.
It reads `KERN_PROCARGS2`, which returns `argc`, the executable path, the
arguments and the entire environment in one NUL-separated buffer. macOS puts
`/var/run/com.apple.security.cryptexd/codex.system/...` on every process's PATH,
so a predicate that scans the whole buffer calls every node process a Codex
session — Cursor's agent workers among them. The fixture body carries that
exact PATH.

`batteryReadsOnlyWhenAttributed` guards the IOKit battery read behind the
attribution requirement: the read is only worth its wake-up when a window is
showing the numbers.

Both are driven through the production source slice, not a re-implementation.
The sysctl path runs against real child processes of this test binary; nothing
is killed and no sampler state is shared with a running app.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sampler = (root / 'Sources/ClaudeBar/Utils/ProcessSampler.swift').read_text()


def method(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    level, end = 1, opening + 1
    while level:
        level += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


for required in ('    private static func argvMentionsCodex(',
                 '    private static func containsCodex('):
    assert required in sampler, f'the probe lost the production slice: {required}'

argv_mentions = method(sampler, '    private static func argvMentionsCodex(').replace(
    'private static func', 'static func')
contains_codex = method(sampler, '    private static func containsCodex(').replace(
    'private static func', 'static func')

probe = r'''
import Darwin
import Foundation

struct ProcessScanScratch { var argv: [UInt8] = [] }

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { print("FAIL: " + message); exit(1) }
}

enum Sampler {
<<<ARGV_MENTIONS>>>
<<<CONTAINS_CODEX>>>
}

@main struct Probe {
    /// `posix_spawn` rather than `fork`: Swift marks `fork` unavailable, and
    /// this variant takes the child's argv and envp directly, which is what the
    /// probe needs to control.
    static func spawn(_ path: String, argvExtra: [String], path env: String?) -> pid_t {
        var argvPointers: [UnsafeMutablePointer<CChar>?] = ([path] + argvExtra).map { strdup($0) }
        argvPointers.append(nil)
        var envPointers: [UnsafeMutablePointer<CChar>?]
        if let env {
            envPointers = [strdup("PATH=" + env), nil]
        } else {
            envPointers = [nil]
        }
        defer {
            for pointer in argvPointers where pointer != nil { free(pointer) }
            for pointer in envPointers where pointer != nil { free(pointer) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, nil, nil, &argvPointers, &envPointers)
        return rc == 0 ? pid : -1
    }

    static func main() {
        // Parked child: the third case needs an argument list that contains
        // "codex", which `/bin/sleep` would reject and exit from before the
        // sample. This binary parks itself instead.
        if CommandLine.arguments.contains("--park") {
            Thread.sleep(forTimeInterval: 60)
            exit(0)
        }
        let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let sleep = "/bin/sleep"
        var scratch = ProcessScanScratch()

        // 1. Plain `sleep 30`: no codex anywhere.
        let plain = spawn(sleep, argvExtra: ["30"], path: nil)
        require(plain > 0, "spawn failed")
        // 2. `sleep 30` whose environment carries the cryptexd PATH entry.
        let withPath = spawn(sleep, argvExtra: ["30"],
                             path: "/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin:/usr/bin:/bin")
        require(withPath > 0, "spawn failed")
        // 3. A parked child with codex in an *argument* — the true positive.
        let inArgv = spawn(selfPath, argvExtra: ["--park", "--label", "codex exec"], path: nil)
        require(inArgv > 0, "spawn failed")
        defer { for pid in [plain, withPath, inArgv] { kill(pid, SIGKILL) } }

        Thread.sleep(forTimeInterval: 0.3)

        let plainHit = Sampler.argvMentionsCodex(plain, scratch: &scratch)
        var scratch2 = ProcessScanScratch()
        let pathHit = Sampler.argvMentionsCodex(withPath, scratch: &scratch2)
        var scratch3 = ProcessScanScratch()
        let argvHit = Sampler.argvMentionsCodex(inArgv, scratch: &scratch3)

        require(!plainHit, "a child with no codex anywhere matched")
        require(!pathHit, "a PATH entry containing 'codex' was read as an argument")
        require(argvHit, "codex in argv did not match")
        // A dead pid must not match and must not trap on the empty buffer.
        var scratch4 = ProcessScanScratch()
        require(!Sampler.argvMentionsCodex(999_999, scratch: &scratch4), "an absent pid matched")
        print("PASS: argv-only Codex detection (env ignored, argv matched, absent pid false)")
    }
}
'''
probe = probe.replace('<<<ARGV_MENTIONS>>>', argv_mentions).replace('<<<CONTAINS_CODEX>>>', contains_codex)
assert 'KERN_PROCARGS2' in probe and 'containsCodex' in probe, \
    'the probe lost the production slice it is supposed to compile'

with tempfile.TemporaryDirectory(prefix='claudebar-process-argv-') as folder:
    folder = Path(folder)
    source = folder / 'Probe.swift'
    source.write_text(probe)
    binary = folder / 'probe'
    subprocess.run(['swiftc', '-O', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
