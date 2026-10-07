#!/usr/bin/env python3
"""The models fetch: URL candidates, response shapes, error text, bounded reads.

`ModelListFetcher` turns a user's base URL and key into model ids. Every path
here has a failure the user acts on:

  * the *URL candidates* — the address typed, the catalog's documented models
    route, or a bounded set of path guesses; never a different product's
    endpoint with the same key attached;
  * the *response parser* — ids live under `data`, `models` (objects or
    strings) or a bare array, and a vendor's display name must not override the
    real id;
  * the *auth verdict* — the user's own URL answering 401/403 is the one error
    that means 「换个 Key」, and it must survive the guessed candidates' 404s
    (finding 423);
  * the *bounded body* — a base URL that answers with a huge body is cut off,
    not buffered (finding 425).

The verification for the last one is a real `URLSession` against a loopback
`http.server` (the pattern `agent-protocol-bridge-regressions.py` uses): the
production fetcher runs, nothing is stubbed, and no vendor is contacted.
`CLAUDEBAR_*` env vars do not participate. The same session then proves the
*candidate loop* with the same production code path by pointing it at the local
server, and a credential-bearing request to it must be refused for `http://`
unless the host is loopback.
"""
from pathlib import Path
import http.server
import json
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
UTILS = ROOT / 'Sources/ClaudeBar/Utils'
CATALOG = ROOT / 'Sources/ClaudeBar/Models/ProviderCatalog.swift'

fetcher = (UTILS / 'ModelListFetcher.swift').read_text()
error_text = (UTILS / 'HTTPErrorText.swift').read_text()
catalog = CATALOG.read_text()

# `ProviderCatalogEntry` is the fetcher's only app dependency. Sliced whole
# (from `enum ProviderClient` to `ProviderSetupDraft`) rather than re-stated:
# a fixture that reimplements `identityURL` can agree with itself and still
# disagree with the app. The slice must keep the closing brace of
# `identityURL` — a missing one compiles here and breaks nothing until the
# candidate order matters.
catalog_slice = catalog[catalog.index('enum ProviderClient:'):catalog.index('struct ProviderSetupDraft')]
assert 'static func identityURL(' in catalog_slice and catalog_slice.rstrip().endswith('}'), \
    'ProviderCatalog.swift changed shape; re-point this extraction'

# --- shared error text ------------------------------------------------------
#
# Finding 422: the two probes used to carry near-identical copies of the
# NSError switch and had already drifted. The suite above compiles and exercises
# the shared type through the fetcher; these pins hold the *other* caller to it,
# because a re-copied switch in ConnectivityProbe would not fail any assertion —
# it would only disagree with this one the next time a case is added.
probe = (UTILS / 'ConnectivityProbe.swift').read_text()
assert 'HTTPErrorText.describeBody(' in probe and 'HTTPErrorText.describe(error' in probe, \
    'ConnectivityProbe must render through HTTPErrorText'
for drifted in ('case NSURLErrorNetworkConnectionLost', 'NSURLErrorSecureConnectionFailed',
                'private static func jsonError(', 'private static func clip('):
    assert drifted not in probe, f'ConnectivityProbe re-grew its own copy: {drifted}'

button = (ROOT / 'Sources/ClaudeBar/Views/Shared/ProviderModelFetchButton.swift').read_text()
assert 'guard !Task.isCancelled else { return }' in button, \
    'the button must drop a cancelled fetch rather than render its outcome'
assert 'ModelListFetcher.buttonMessage(for: outcome)' in button, \
    'the button must render failures through ModelListFetcher.buttonMessage'
assert 'HTTPErrorText.describe(error' in fetcher, 'ModelListFetcher must render through HTTPErrorText'
assert 'NSURLErrorNetworkConnectionLost' not in fetcher, \
    'the fetcher must not carry a second NSError switch'

# --------------------------------------------------------------------------
# The loopback server: a models endpoint, a huge body, a 401 that must be
# quoted back, and an oversized error body.
# --------------------------------------------------------------------------

HUGE_BYTES = 8 * 1024 * 1024


class Handler(http.server.BaseHTTPRequestHandler):
    """Routes are exact: the fetch tries at most two paths, and the point of
    the 401 case is *which* candidate answered it."""

    def _send(self, body: bytes, status: int = 200, content_type: str = 'application/json'):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    MODELS = json.dumps({'data': [
        {'id': 'local-beta'}, {'id': 'local-alpha'},
        {'id': 'local-alpha'},  # duplicate is folded, not listed twice
        {'model': 'local-from-model'},
        {'name': 'local-from-name'},
    ]}).encode()

    def do_GET(self):
        path = self.path
        if path in ('/v1/models', '/models'):
            self._send(self.MODELS)
        elif path == '/empty/models':
            self._send(b'{"data":[]}')
        elif path == '/denied/v1/models':
            # The user's own URL answering 401 — the verdict the fetch must
            # keep even though the next candidate 404s.
            self._send(b'{"error":{"message":"invalid api key"}}', status=401)
        elif path in ('/denied/models', '/no-such-route/v1/models'):
            self._send(b'{"error":{"message":"no such route"}}', status=404)
        elif path == '/no-such-route/models':
            # The guessed second candidate answers correctly.
            self._send(self.MODELS)
        elif path == '/huge/models':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(HUGE_BYTES))
            self.end_headers()
            try:
                chunk = b'x' * 65536
                for _ in range(HUGE_BYTES // len(chunk)):
                    self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif path == '/huge-error/models':
            # A large error body must be clipped by the error text, not shown
            # whole. (This one fits the reader's cap on purpose; an 8 MiB error
            # body is the 「响应过大」 path the /huge case covers.)
            self._send(b'{"error":{"message":"' + b'e' * 4000 + b'"}}', status=500)
        elif path == '/slow/models':
            # Holds the connection open long enough for the test to cancel the
            # fetch. The response itself never matters.
            import time
            time.sleep(2)
            self._send(self.MODELS)
        elif path == '/odd/models':
            self._send(b'{"models":[{"id":"obj-id"},{"name":"string-name"}]}')
        else:
            self._send(b'{"error":{"message":"no such route"}}', status=404)

    def log_message(self, *args):
        pass


def main() -> int:
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]

    swift = f'''
import Foundation

// The production slice: fetcher + shared error text + the catalog entry type it
// reads. `fetch` is the real one — it opens a `URLSession` to the loopback
// server below, which is exactly the point of this harness.
{catalog_slice}

{fetcher}

{error_text}

@main
struct Regression {{
    static func report(_ label: String, _ outcome: ModelListFetcher.Outcome) -> (Bool, String) {{
        switch outcome {{
        case .success(let payload): return (true, payload.models.joined(separator: ","))
        case .failure(let message): return (false, message)
        }}
    }}

    static func main() async {{
        let port = CommandLine.arguments[1]
        let base = "http://127.0.0.1:\\(port)"

        // 1. Success shape: content-keyed ids, deduped case-insensitively and
        //    sorted, from a real response.
        let (ok, detail) = report("models", await ModelListFetcher.fetch(baseURL: base, apiKey: "k"))
        precondition(ok, "a 200 models response failed: \\(detail)")
        precondition(detail == "local-alpha,local-beta,local-from-model,local-from-name",
                     "ids must be deduped and sorted, got \\(detail)")

        // 2. An empty list is a failure with the path named — the dialog must
        //    not open a picker with nothing in it.
        let (emptyOK, emptyMessage) = report("empty", await ModelListFetcher.fetch(baseURL: base + "/empty", apiKey: "k"))
        precondition(!emptyOK, "an empty list must not be success")
        precondition(emptyMessage.contains("空模型列表"), "got \\(emptyMessage)")

        // 3. The user's own URL answering 401 must be the message, even though
        //    the guessed candidates after it fail with 404 (finding 423).
        let (deniedOK, deniedMessage) = report("denied", await ModelListFetcher.fetch(baseURL: base + "/denied", apiKey: "k", wireAPI: "anthropic"))
        precondition(!deniedOK, "401 must not be success")
        precondition(deniedMessage.contains("鉴权失败"), "the typed URL's 401 must survive the later 404s, got \\(deniedMessage)")

        // 4. A 404 on the *typed* URL is not definitive; the guessed candidate
        //    (`<base>/v1/models`) succeeds and must be reached.
        let (guessOK, guessDetail) = report("guess", await ModelListFetcher.fetch(baseURL: base + "/no-such-route", apiKey: "k", wireAPI: "anthropic"))
        precondition(guessOK && guessDetail.contains("local-alpha"),
                     "the guessed /v1/models candidate must still be tried: \\(guessDetail)")

        // 5. A huge body is cut off rather than buffered (finding 425).
        let (hugeOK, hugeMessage) = report("huge", await ModelListFetcher.fetch(baseURL: base + "/huge", apiKey: "k"))
        precondition(!hugeOK, "a huge body must not be parsed as a model list")
        precondition(hugeMessage.contains("响应过大"), "got \\(hugeMessage)")

        // 6. Error text is clipped to the shared width, path included.
        let (errOK, errMessage) = report("err", await ModelListFetcher.fetch(baseURL: base + "/huge-error", apiKey: "k"))
        precondition(!errOK, "a 500 must not be success")
        precondition(errMessage.contains("HTTP 500") && errMessage.contains("/huge-error"),
                     "the status and the path must be named: \\(errMessage)")
        precondition(errMessage.count < 260, "the vendor's words must be clipped: \\(errMessage.count) chars")

        // 7. The key never crosses plain http to a public host — including the
        //    guessed candidates, which would otherwise leak it after a refusal.
        let (plainOK, plainMessage) = report("plain", await ModelListFetcher.fetch(baseURL: "http://example.com/v1", apiKey: "sk-secret"))
        precondition(!plainOK && plainMessage.contains("https"), "got \\(plainMessage)")
        let (noURL, noURLMessage) = report("blank", await ModelListFetcher.fetch(baseURL: "  ", apiKey: "sk-secret"))
        precondition(!noURL && noURLMessage.contains("Base URL"), "got \\(noURLMessage)")

        // 7b. Ids under `models` as objects — the third response shape, and a
        //     display name must not win over the real id.
        let (oddOK, oddDetail) = report("odd", await ModelListFetcher.fetch(baseURL: base + "/odd", apiKey: "k"))
        precondition(oddOK && oddDetail == "obj-id,string-name", "got \\(oddDetail)")

        // 7c. A cancelled fetch reports 已取消 — and the button must never
        //     turn that into a message: `cancel()` has already cleared it, and
        //     the view returns early while the task is cancelled. The string is
        //     pinned here so the pin below has teeth (if the button ever showed
        //     it, the user would read 已取消。也可手动填写模型 ID。).
        let cancelTask = Task {{ await ModelListFetcher.fetch(baseURL: base + "/slow", apiKey: "k", wireAPI: "anthropic") }}
        try? await Task.sleep(nanoseconds: 250_000_000)
        cancelTask.cancel()
        let (cancelOK, cancelMessage) = report("cancel", await cancelTask.value)
        precondition(!cancelOK && cancelMessage == "已取消", "got \\(cancelMessage)")

        // 8. The button's message is a value, not a view detail.
        let button = ModelListFetcher.buttonMessage(for: .failure("无法连接 example.com"))
        precondition(button == "无法连接 example.com。也可手动填写模型 ID。", "got \\(button ?? "nil")")
        precondition(ModelListFetcher.buttonMessage(for: .success(.init(models: []))) == nil,
                     "a successful fetch shows no message")

        print("PASS: URL candidates, response shapes, dedupe/sort, 401 survives the "
              + "guessed candidates, bounded body, clipped error text, key transport")
    }}
}}
'''

    with tempfile.TemporaryDirectory(prefix='claudebar-model-list-tests-') as folder:
        path = Path(folder) / 'Regression.swift'
        path.write_text(swift)
        binary = Path(folder) / 'regression'
        build = subprocess.run(['swiftc', '-O', '-parse-as-library', str(path), '-o', str(binary)],
                               capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stderr[:6000])
            print('FAIL: the fetch slice did not compile')
            return 1
        server.timeout = None
        run = subprocess.run([str(binary), str(port)],
                             capture_output=True, text=True, timeout=180)
    server.shutdown()
    print(run.stdout, end='')
    if run.returncode != 0:
        print(run.stderr[:4000])
        print('FAIL: the fetch slice assertion(s) failed')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
