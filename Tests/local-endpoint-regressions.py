#!/usr/bin/env python3
"""`isLocalEndpoint` decides whether an API key is real, so its edges matter.

It gates key validation, the editor's hint, and the connectivity probe. Getting
it wrong is not cosmetic: a false negative tells a user with a healthy local
Ollama that their key is missing; a false positive silently accepts an empty
key for a paid public endpoint. Host classification is pure, so test it directly
against the production source — no app launch.

Compiles the real `isLocalEndpoint` body extracted from ProviderCatalog.swift.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/ClaudeBar/Models/ProviderCatalog.swift').read_text()
start = source.index('    static func isLocalEndpoint(_ raw: String) -> Bool {')
end = source.index('\n    }\n', start) + len('\n    }\n')
body = source[start:end]

swift = r'''
import Foundation

enum ProviderCatalogEntry {
BODY
}

@main struct Regression {
    static func main() {
        // Loopback, private ranges, and Bonjour names: no real key is possible.
        let local = [
            "http://localhost:11434",
            "http://localhost:1234/v1",
            "http://127.0.0.1:11434",
            "https://127.0.0.1",
            "http://0.0.0.0:8080",
            "http://[::1]:11434",
            "http://[::1]",
            "http://ollama.local:11434",
            "http://192.168.1.50:1234",
            "http://10.0.0.7:4000",
            "http://172.16.5.5:4000",
            "http://172.31.255.1:4000",
            "  http://localhost:11434  ",
        ]
        // Public hosts, plus the boundaries that look private but are not.
        let remote = [
            "https://api.deepseek.com/anthropic",
            "https://api.openai.com/v1",
            "https://ollama.com",
            "https://localhost.evil.com",
            "https://127.0.0.2.example.com",
            "http://172.15.1.1:4000",     // one below the 172.16/12 block
            "http://172.32.1.1:4000",     // one above it
            "http://192.169.1.1:4000",    // adjacent to 192.168/16
            "http://11.0.0.1:4000",       // adjacent to 10/8
            "ftp://localhost:21",         // not an API scheme
            "",
            "not a url",
        ]

        var failures: [String] = []
        for url in local where !ProviderCatalogEntry.isLocalEndpoint(url) {
            failures.append("expected LOCAL, got remote: \(url)")
        }
        for url in remote where ProviderCatalogEntry.isLocalEndpoint(url) {
            failures.append("expected REMOTE, got local: \(url)")
        }
        precondition(failures.isEmpty, failures.joined(separator: "\n"))
        print("PASS: \(local.count) loopback/private hosts classified local, "
              + "\(remote.count) public hosts remote (172.15/172.32, 192.169, 11.x, "
              + "localhost.evil.com and ftp:// all correctly remote)")
    }
}
'''.replace('BODY', body)
with tempfile.TemporaryDirectory(prefix='claudebar-local-tests-') as folder:
    path = Path(folder) / 'Regression.swift'
    path.write_text(swift)
    binary = Path(folder) / 'regression'
    subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
