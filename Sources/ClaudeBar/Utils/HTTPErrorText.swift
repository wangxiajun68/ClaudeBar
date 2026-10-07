import Foundation

/// The one place a raw `URLSession` failure or error response becomes text the
/// user reads.
///
/// Two callers, one vocabulary. `ConnectivityProbe` renders why the loopback
/// proxy did not answer, `ModelListFetcher` why a `GET /models` failed; both
/// used to carry their own copy of this switch, and the copies had already
/// drifted — the fetcher's was missing 连接中断 and TLS 失败, so a bad
/// certificate surfaced as the raw locale-dependent `localizedDescription`
/// while the probe on the same machine said `TLS 失败（host）`. Two surfaces
/// describing the same NSError class differently is a user who cannot tell
/// 「我的证书不对」 from 「服务器拒绝了我」.
///
/// `clip` is a fixed 160 characters, so which caller asked does not decide how
/// much of a vendor's error body is shown.
enum HTTPErrorText {

    // MARK: - Errors

    /// An `NSError` from `URLSession`, in the same words every time.
    /// `host` is woven into the messages that are useless without it.
    static func describe(_ error: Error, host: String) -> String {
        let e = error as NSError
        if e.domain == NSURLErrorDomain {
            switch e.code {
            case NSURLErrorTimedOut: return "超时（\(host)）"
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "无法连接 \(host)"
            case NSURLErrorNotConnectedToInternet: return "无网络"
            case NSURLErrorNetworkConnectionLost: return "连接中断"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                return "TLS 失败（\(host)）"
            // A cancelled request is the user's own doing (they left the form,
            // or the fetch was superseded) and it is the one error that must
            // not be rendered as a *failure*: without this case the fallback
            // below prints `localizedDescription`, which is the untranslated
            // `cancelled`. Measured: cancelling mid-request lands here, not in
            // the caller's `Task.isCancelled` check.
            case NSURLErrorCancelled: return "已取消"
            default: break
            }
        }
        return clip(error.localizedDescription)
    }

    // MARK: - Error responses

    /// A status-only line when the body says nothing usable: `接口不存在（/v1/models）`
    /// with a path, or bare `限流` for the probe, which has only one URL.
    static func describeBody(_ data: Data, status: Int, path: String? = nil) -> String {
        let prefix: String
        switch status {
        case 401, 403: prefix = "鉴权失败"
        case 404: prefix = "接口不存在"
        case 429: prefix = "限流"
        default: prefix = "HTTP \(status)"
        }
        var head = prefix
        if let path, !path.isEmpty { head += "（\(path)）" }
        if let msg = jsonError(data), !msg.isEmpty { head += "：\(clip(msg))" }
        return head
    }

    // MARK: - Internals

    /// The error message a JSON body carries, else its opening bytes. Probes
    /// that only need this do not have to carry their own copy.
    private static func jsonError(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let dict = obj as? [String: Any] {
            if let err = dict["error"] as? [String: Any] {
                if let m = err["message"] as? String { return m }
                if let m = err["msg"] as? String { return m }
            }
            if let m = dict["error"] as? String { return m }
            if let m = dict["message"] as? String { return m }
            if let m = dict["msg"] as? String { return m }
        }
        return String(data: data.prefix(160), encoding: .utf8)
    }

    /// Collapse whitespace and cap the length. The cap is shared so both
    /// callers show a vendor's words at the same width.
    static func clip(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.count <= 160 { return flat }
        return String(flat.prefix(157)) + "…"
    }
}
