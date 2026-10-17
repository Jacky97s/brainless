import Foundation
import Compression

/// 把別處的詞彙匯進詞典：Typeless 的本機快取，或使用者選的文字／CSV／JSON 檔
enum DictionaryImport {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Typeless

    /// Typeless 的詞典只存在它的雲端；這裡讀它 Chromium HTTP 快取裡最近一次 /user/dictionary/list 的回應，不碰它的登入憑證
    static func typelessCachedTerms() -> Result<(terms: [String], cachedAt: Date), Failure> {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Typeless")
        guard fm.fileExists(atPath: root.path) else { return .failure(Failure(message: "這台電腦沒有 Typeless 的資料")) }
        var cacheDirs = [root.appendingPathComponent("Cache/Cache_Data")]
        let partitions = root.appendingPathComponent("Partitions")
        for p in (try? fm.contentsOfDirectory(atPath: partitions.path)) ?? [] {
            cacheDirs.append(partitions.appendingPathComponent(p).appendingPathComponent("Cache/Cache_Data"))
        }
        var newest: (terms: [String], cachedAt: Date)?
        for dir in cacheDirs {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix("_0") {
                let url = dir.appendingPathComponent(name)
                guard let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                      newest.map({ date > $0.cachedAt }) ?? true,
                      let data = try? Data(contentsOf: url),
                      let body = typelessDictionaryBody(data),
                      let terms = terms(fromJSON: body) else { continue }
                newest = (terms, date)
            }
        }
        guard let found = newest else {
            return .failure(Failure(message: "找不到 Typeless 的詞典快取。先在 Typeless 打開一次詞典頁，再回來匯入"))
        }
        return .success(found)
    }

    /// Chromium simple cache entry：24 bytes 標頭（含 key 長度）、key、回應本文、EOF 記錄、回應標頭
    private static func typelessDictionaryBody(_ d: Data) -> Data? {
        let bytes = [UInt8](d)
        guard bytes.count > 24 else { return nil }
        let keyLen = Int(UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24)
        let bodyStart = 24 + keyLen
        guard keyLen > 0, bodyStart < bytes.count,
              let key = String(bytes: bytes[24..<bodyStart], encoding: .utf8),
              key.contains("api.typeless.com/user/dictionary/list") else { return nil }
        let eofMagic: [UInt8] = [0xd8, 0x41, 0x0d, 0x97, 0x45, 0x6f, 0xfa, 0xf4]
        var end = bodyStart
        while end + 8 <= bytes.count, Array(bytes[end..<end + 8]) != eofMagic { end += 1 }
        guard end + 8 <= bytes.count else { return nil }
        let body = Data(bytes[bodyStart..<end])
        let headers = String(decoding: bytes[(end + 8)...], as: UTF8.self).lowercased()
        return headers.contains("content-encoding:br") ? brotliDecode(body) : body
    }

    private static func brotliDecode(_ src: Data) -> Data? {
        let cap = 8 << 20
        var dst = Data(count: cap)
        let n = dst.withUnsafeMutableBytes { d in
            src.withUnsafeBytes { s in
                compression_decode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_BROTLI)
            }
        }
        return n > 0 ? dst.prefix(n) : nil
    }

    // MARK: - 檔案

    /// JSON（Typeless API 格式或字串陣列）照結構讀；其他當成文字，換行、逗號、頓號都算分隔
    static func terms(fromFile url: URL) -> Result<[String], Failure> {
        guard let data = try? Data(contentsOf: url) else { return .failure(Failure(message: "讀不到檔案：\(url.lastPathComponent)")) }
        if let t = terms(fromJSON: data) { return .success(t) }
        guard let text = String(data: data, encoding: .utf8) else { return .failure(Failure(message: "檔案不是 UTF-8 文字")) }
        let t = text.components(separatedBy: CharacterSet(charactersIn: "\n\r,，、\t"))
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
        return t.isEmpty ? .failure(Failure(message: "檔案裡沒有詞")) : .success(t)
    }

    private static func terms(fromJSON data: Data) -> [String]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let arr = obj as? [String] { return arr }
        let root = obj as? [String: Any]
        let words = ((root?["data"] as? [String: Any])?["words"] ?? root?["words"] ?? obj) as? [[String: Any]]
        return words?.compactMap { $0["term"] as? String }
    }
}
