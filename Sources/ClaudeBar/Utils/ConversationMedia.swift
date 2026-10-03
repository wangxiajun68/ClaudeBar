import Foundation

/// Image bytes shared by session migration and the Anthropic ↔ Responses bridge.
/// Documents, audio and video stay unsupported in both callers.
enum ConversationMedia {
    static let imageMediaTypes = ["image/png", "image/jpeg", "image/webp", "image/gif"]
    static let maxBytes = 16 * 1024 * 1024
    enum Failure: Error { case unsupported }

    /// A data URL for inline bytes, or an http(s) URL. `mediaType` is empty for remote URLs.
    static func imageURL(_ block: [String: Any]) throws -> (mediaType: String, url: String) {
        if let source = block["source"] as? [String: Any] {
            if source["type"] as? String == "base64" {
                guard let mime = source["media_type"] as? String, imageMediaTypes.contains(mime),
                      let encoded = source["data"] as? String else { throw Failure.unsupported }
                return try inline(mediaType: mime, encoded: encoded)
            }
            if source["type"] as? String == "url", let raw = source["url"] as? String {
                return try remote(raw)
            }
        }
        if let raw = block["image_url"] as? String {
            return raw.hasPrefix("data:") ? try dataURL(raw) : try remote(raw)
        }
        if let object = block["image_url"] as? [String: Any], let raw = object["url"] as? String {
            return raw.hasPrefix("data:") ? try dataURL(raw) : try remote(raw)
        }
        throw Failure.unsupported
    }

    private static func inline(mediaType: String, encoded: String) throws -> (mediaType: String, url: String) {
        guard imageMediaTypes.contains(mediaType), encoded.utf8.count < maxBytes,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty else { throw Failure.unsupported }
        return (mediaType, "data:" + mediaType + ";base64," + encoded)
    }

    private static func dataURL(_ raw: String) throws -> (mediaType: String, url: String) {
        guard raw.hasPrefix("data:"), let comma = raw.firstIndex(of: ",") else { throw Failure.unsupported }
        let header = raw[raw.index(raw.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64") else { throw Failure.unsupported }
        let mediaType = String(header.dropLast(";base64".count))
        return try inline(mediaType: mediaType, encoded: String(raw[raw.index(after: comma)...]))
    }

    private static func remote(_ raw: String) throws -> (mediaType: String, url: String) {
        guard raw.utf8.count < 2048, let url = URL(string: raw),
              ["https", "http"].contains(url.scheme?.lowercased()) else { throw Failure.unsupported }
        return ("", raw)
    }
}
