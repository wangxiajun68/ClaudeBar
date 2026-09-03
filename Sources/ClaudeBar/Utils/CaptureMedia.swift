import Foundation
import AppKit

/// Extract / persist inline images from captured request JSON.
/// Base64 screenshots are often several MB and used to blow the payload cap;
/// they are written beside the capture and replaced with a short file ref.
enum CaptureMedia {
    static let payloadCapBytes = 16 * 1024 * 1024
    static let payloadCapLabel = "16 MB"
    private static let filePrefix = "cbfile:"

    struct EmbeddedImage: Equatable {
        var mediaType: String
        var fileURL: URL? = nil
        var data: Data? = nil
    }

    static func mediaDir(captureID: Int64) -> URL {
        let dir = FilePaths.capturePayloadsDir
            .appendingPathComponent("\(captureID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Replace bulky base64 blobs with `cbfile:img-N.ext` refs and write files.
    static func compact(_ raw: String?, captureID: Int64, cap: Int = payloadCapBytes) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) else {
            return truncate(raw, cap: cap)
        }
        var index = 0
        let dir = mediaDir(captureID: captureID)
        let walked = walk(obj, dir: dir, index: &index)
        guard JSONSerialization.isValidJSONObject(walked),
              let data = try? JSONSerialization.data(withJSONObject: walked),
              let compact = String(data: data, encoding: .utf8) else {
            return truncate(raw, cap: cap)
        }
        return truncate(compact, cap: cap)
    }

    static func image(from part: [String: Any], mediaDir: URL?) -> EmbeddedImage? {
        if let source = part["source"] as? [String: Any],
           let img = image(fromSource: source, mediaDir: mediaDir) {
            return img
        }
        if let url = part["image_url"] as? [String: Any] {
            if let img = image(fromURL: (url["url"] as? String) ?? "", mediaDir: mediaDir) {
                return img
            }
        }
        if let url = part["image_url"] as? String, let img = image(fromURL: url, mediaDir: mediaDir) {
            return img
        }
        if let url = part["url"] as? String, let img = image(fromURL: url, mediaDir: mediaDir) {
            return img
        }
        return nil
    }

    static func nsImage(from img: EmbeddedImage) -> NSImage? {
        if let url = img.fileURL { return NSImage(contentsOf: url) }
        if let data = img.data { return NSImage(data: data) }
        return nil
    }

    // MARK: - Walk / compact

    private static func walk(_ any: Any, dir: URL, index: inout Int) -> Any {
        if let dict = any as? [String: Any] {
            var out = dict
            if let source = dict["source"] as? [String: Any],
               let data = source["data"] as? String, isBulky(data) {
                var src = source
                if let ref = persist(data, mediaType: (source["media_type"] as? String) ?? "image/png",
                                     dir: dir, index: &index) {
                    src["data"] = ref
                }
                out["source"] = src
            }
            if let url = dict["image_url"] as? [String: Any],
               let s = url["url"] as? String, isBulky(s) {
                var u = url
                if let ref = persistURL(s, dir: dir, index: &index) { u["url"] = ref }
                out["image_url"] = u
            } else if let s = dict["image_url"] as? String, isBulky(s) {
                if let ref = persistURL(s, dir: dir, index: &index) { out["image_url"] = ref }
            }
            for (k, v) in out {
                if k == "source" || k == "image_url" { continue }
                out[k] = walk(v, dir: dir, index: &index)
            }
            return out
        }
        if let arr = any as? [Any] {
            return arr.map { walk($0, dir: dir, index: &index) }
        }
        return any
    }

    private static func isBulky(_ s: String) -> Bool {
        s.count > 512 && (s.hasPrefix("data:image") || s.hasPrefix(filePrefix) || looksBase64(s))
    }

    private static func looksBase64(_ s: String) -> Bool {
        let sample = s.prefix(80)
        return sample.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }
            && s.count > 800
    }

    private static func persistURL(_ url: String, dir: URL, index: inout Int) -> String? {
        if url.hasPrefix(filePrefix) { return url }
        if url.hasPrefix("data:image"), let parsed = decodeDataURI(url) {
            return persist(parsed.data, mediaType: parsed.mime, dir: dir, index: &index)
        }
        if looksBase64(url) {
            return persist(url, mediaType: "image/png", dir: dir, index: &index)
        }
        return nil
    }

    private static func persist(_ data: String, mediaType: String, dir: URL, index: inout Int) -> String? {
        if data.hasPrefix(filePrefix) { return data }
        let payload: Data
        if data.hasPrefix("data:image"), let parsed = decodeDataURI(data) {
            payload = parsed.data
        } else {
            payload = Data(base64Encoded: data.replacingOccurrences(of: "\n", with: "")) ?? Data()
        }
        guard !payload.isEmpty else { return nil }
        let ext = ext(for: mediaType)
        let name = String(format: "img-%03d.%@", index, ext)
        index += 1
        try? payload.write(to: dir.appendingPathComponent(name), options: .atomic)
        return filePrefix + name
    }

    private static func persist(_ data: Data, mediaType: String, dir: URL, index: inout Int) -> String? {
        guard !data.isEmpty else { return nil }
        let ext = ext(for: mediaType)
        let name = String(format: "img-%03d.%@", index, ext)
        index += 1
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
        return filePrefix + name
    }

    // MARK: - Decode

    private static func image(fromSource source: [String: Any], mediaDir: URL?) -> EmbeddedImage? {
        let mime = (source["media_type"] as? String) ?? "image/png"
        guard let data = source["data"] as? String else { return nil }
        return decodeBlob(data, mime: mime, mediaDir: mediaDir)
    }

    private static func image(fromURL url: String, mediaDir: URL?) -> EmbeddedImage? {
        if url.hasPrefix("http") { return nil }
        if url.hasPrefix("data:image"), let parsed = decodeDataURI(url) {
            return EmbeddedImage(mediaType: parsed.mime, data: parsed.data)
        }
        return decodeBlob(url, mime: "image/png", mediaDir: mediaDir)
    }

    private static func decodeBlob(_ raw: String, mime: String, mediaDir: URL?) -> EmbeddedImage? {
        if raw.hasPrefix(filePrefix) {
            let name = String(raw.dropFirst(filePrefix.count))
            guard let mediaDir else { return nil }
            return EmbeddedImage(mediaType: mime, fileURL: mediaDir.appendingPathComponent(name))
        }
        let cleaned = raw.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: cleaned), !data.isEmpty else { return nil }
        return EmbeddedImage(mediaType: mime, data: data)
    }

    private static func decodeDataURI(_ uri: String) -> (data: Data, mime: String)? {
        // data:image/png;base64,XXXX
        guard uri.hasPrefix("data:"),
              let comma = uri.firstIndex(of: ",") else { return nil }
        let meta = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma]
        let mime = String(meta.split(separator: ";").first ?? "image/png")
        let b64 = String(uri[uri.index(after: comma)...]).replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: b64), !data.isEmpty else { return nil }
        return (data, mime)
    }

    private static func ext(for mime: String) -> String {
        switch mime {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        default: return "png"
        }
    }

    static func truncate(_ text: String, cap: Int) -> String {
        if text.utf8.count <= cap { return text }
        return String(decoding: Data(text.utf8.prefix(cap)), as: UTF8.self) + "\n… [truncated]"
    }
}
