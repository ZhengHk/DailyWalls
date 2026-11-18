import Foundation

/// Rich metadata saved alongside each downloaded image (see sidecar `.json` files).
struct WallpaperMetadata: Codable {
    let fetchedDate: String
    let source: String
    let imageUrl: String
    let fileName: String
    let title: String?
    let copyright: String?
    let description: String?
    let entityId: String?
    let spotlightId: String?
    let copyrightLink: String?
    let iconHoverText: String?
    let ctaText: String?
    let ctaUri: String?
}

/// A normalised daily wallpaper entry (source-independent)
struct WallpaperImage {
    let date: String       // yyyy-MM-dd
    let imageUrl: String   // Direct, full image URL
    let title: String?
    let copyright: String?
    /// Original CDN / Bing filename used when saving under ~/Pictures/ms-wallpapers/
    let fileName: String
    let metadata: WallpaperMetadata
}

// MARK: - Bing HPImageArchive models

private struct BingArchiveResponse: Decodable {
    let images: [BingImage]
}

private struct BingImage: Decodable {
    let startdate: String   // "20260603"
    let urlbase: String     // "/th?id=OHR.SomeName_EN-US1234567890"
    let title: String?
    let copyright: String?
    let copyrightlink: String?
}

// MARK: - Microsoft Spotlight (arc.msn.com) models

private struct SpotlightResponse: Decodable {
    let batchrsp: SpotlightBatch
}

private struct SpotlightBatch: Decodable {
    let items: [SpotlightItem]?
    let errors: [SpotlightAPIErrorItem]?
}

private struct SpotlightItem: Decodable {
    let item: String   // JSON string — must be decoded again
}

private struct SpotlightAd: Decodable {
    let ad: [String: SpotlightAsset]
}

private struct SpotlightAsset: Decodable {
    let t: String    // "img" | "txt"
    let u: String?   // URL (images only)
    let tx: String?  // Text value (text assets only)
}

private struct SpotlightAPIErrorItem: Decodable {
    let code: Int?
    let msg: String?
}

private struct SpotlightV4AdPayload: Decodable {
    let ad: SpotlightV4Ad
}

private struct SpotlightV4Ad: Decodable {
    let landscapeImage: SpotlightV4LandscapeImage
    let title: String?
    let description: String?
    let copyright: String?
    let entityId: String?
    let iconHoverText: String?
    let ctaText: String?
    let ctaUri: String?
}

private struct SpotlightV4LandscapeImage: Decodable {
    let asset: String
}

// MARK: - Unified API client

/// Fetches today's wallpaper metadata from official Microsoft/Bing sources only.
/// • Bing:      www.bing.com/HPImageArchive.aspx  (official, no bot protection)
/// • Spotlight: arc.msn.com/v3/Delivery/Placement (official Windows lock-screen endpoint)
final class WallpaperAPI {
    static let shared = WallpaperAPI()
    private init() {}

    // MARK: - Locale helpers

    /// Bing market identifier, e.g. "en-US", "zh-CN", "de-DE"
    private var bingMarket: String {
        let lang   = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.region?.identifier ?? "US"
        return "\(lang)-\(region)"
    }

    /// Returns (locale string, country code) for Spotlight, e.g. ("en-US", "US")
    private var spotlightLocale: (String, String) {
        let lang   = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.region?.identifier ?? "US"
        return ("\(lang)-\(region)", region)
    }

    // MARK: - Public API

    func fetchTodayImage(source: WallpaperSource) async throws -> WallpaperImage {
        switch source {
        case .bing:      return try await fetchBing()
        case .spotlight: return try await fetchSpotlight()
        }
    }

    /// Up to four Spotlight candidates for the picker (`bcnt` on API v4).
    func fetchSpotlightOptions(count: Int = 4) async throws -> [WallpaperImage] {
        let batch = min(max(count, 1), 4)
        do {
            let images = try await fetchSpotlightV4Batch(count: batch)
            if !images.isEmpty { return images }
        } catch {
            Logger.shared.log("Spotlight batch v4 failed (\(error.localizedDescription)); falling back.")
        }
        return [try await fetchSpotlightV3()]
    }

    // MARK: - Bing via HPImageArchive (official)

    /// Uses the same JSON endpoint that Bing.com itself uses to populate its homepage.
    /// • idx=0  → today's image
    /// • n=1    → one image
    /// • mkt=   → locale market (e.g. en-US)
    /// Image URL is constructed from `urlbase` + "_UHD.jpg" for maximum resolution.
    private func fetchBing() async throws -> WallpaperImage {
        let market = bingMarket
        let urlString = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=\(market)"
        guard let url = URL(string: urlString) else {
            throw WallpaperAPIError.invalidURL(urlString)
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("DailyWalls/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response, source: "Bing HPImageArchive")

        let archive = try JSONDecoder().decode(BingArchiveResponse.self, from: data)
        guard let first = archive.images.first else {
            throw WallpaperAPIError.emptyFeed("Bing HPImageArchive")
        }

        // urlbase is a relative path like "/th?id=OHR.SomeName_EN-US1234"
        // Append "_UHD.jpg" for the highest available resolution (up to 3840×2160)
        let imageUrl = "https://www.bing.com\(first.urlbase)_UHD.jpg"

        // Convert startdate "20260603" → "2026-06-03"
        let date = formatBingDate(first.startdate)
        let fileName = bingFileName(urlbase: first.urlbase)
        let metadata = WallpaperMetadata(
            fetchedDate: date,
            source: WallpaperSource.bing.rawValue,
            imageUrl: imageUrl,
            fileName: fileName,
            title: first.title,
            copyright: first.copyright,
            description: nil,
            entityId: nil,
            spotlightId: bingSpotlightId(from: first.urlbase),
            copyrightLink: first.copyrightlink,
            iconHoverText: nil,
            ctaText: nil,
            ctaUri: nil
        )

        return WallpaperImage(
            date: date,
            imageUrl: imageUrl,
            title: first.title,
            copyright: first.copyright,
            fileName: fileName,
            metadata: metadata
        )
    }

    /// Converts Bing's compact date format "20260603" to "2026-06-03"
    private func formatBingDate(_ raw: String) -> String {
        guard raw.count == 8 else { return raw }
        let y = raw.prefix(4)
        let m = raw.dropFirst(4).prefix(2)
        let d = raw.dropFirst(6).prefix(2)
        return "\(y)-\(m)-\(d)"
    }

    // MARK: - Spotlight (v4 preferred, v3 fallback)

    /// Tries Windows 11 Spotlight API v4 (up to 4K, native CDN filenames) first, then v3.
    private func fetchSpotlight() async throws -> WallpaperImage {
        do {
            return try await fetchSpotlightV4()
        } catch {
            Logger.shared.log("Spotlight API v4 unavailable (\(error.localizedDescription)); falling back to v3.")
            return try await fetchSpotlightV3()
        }
    }

    /// Spotlight API v4 — `fd.api.iris.microsoft.com`, up to 3840×2160.
    private func fetchSpotlightV4() async throws -> WallpaperImage {
        let images = try await fetchSpotlightV4Batch(count: 1)
        guard let first = images.first else {
            throw WallpaperAPIError.emptyFeed("Microsoft Spotlight v4")
        }
        return first
    }

    private func fetchSpotlightV4Batch(count: Int) async throws -> [WallpaperImage] {
        let (locale, country) = spotlightLocale
        let countryCode = country.uppercased()
        let urlString = "https://fd.api.iris.microsoft.com/v4/api/selection"
            + "?placement=88000820&bcnt=\(count)&country=\(countryCode)&locale=\(locale)&fmt=json"
        guard let url = URL(string: urlString) else {
            throw WallpaperAPIError.invalidURL(urlString)
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response, source: "Microsoft Spotlight v4")

        let outer = try JSONDecoder().decode(SpotlightResponse.self, from: data)
        if let errors = outer.batchrsp.errors, !errors.isEmpty {
            let msg = errors.compactMap(\.msg).joined(separator: "; ")
            throw WallpaperAPIError.emptyFeed("Microsoft Spotlight v4: \(msg)")
        }
        guard let items = outer.batchrsp.items, !items.isEmpty else {
            throw WallpaperAPIError.emptyFeed("Microsoft Spotlight v4")
        }

        var seen = Set<String>()
        var result: [WallpaperImage] = []
        for item in items {
            guard let innerData = item.item.data(using: .utf8) else { continue }
            guard let image = try? wallpaperImageFromSpotlightV4(innerData: innerData) else { continue }
            let key = image.metadata.entityId ?? image.fileName
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(image)
        }
        return result
    }

    private func wallpaperImageFromSpotlightV4(innerData: Data) throws -> WallpaperImage {
        let payload = try JSONDecoder().decode(SpotlightV4AdPayload.self, from: innerData)
        let ad = payload.ad
        let imageUrl = ad.landscapeImage.asset
        let today = todayString()
        let fileName = fileNameFromImageURL(imageUrl, fallbackStem: ad.entityId ?? today)
        let metadata = WallpaperMetadata(
            fetchedDate: today,
            source: WallpaperSource.spotlight.rawValue,
            imageUrl: imageUrl,
            fileName: fileName,
            title: ad.title,
            copyright: ad.copyright,
            description: ad.description,
            entityId: ad.entityId,
            spotlightId: spotlightId(fromCTA: ad.ctaUri),
            copyrightLink: nil,
            iconHoverText: ad.iconHoverText,
            ctaText: ad.ctaText,
            ctaUri: ad.ctaUri
        )
        return WallpaperImage(
            date: today,
            imageUrl: imageUrl,
            title: ad.title,
            copyright: ad.copyright,
            fileName: fileName,
            metadata: metadata
        )
    }

    /// Legacy Spotlight API v3 — `arc.msn.com`, up to 1080p (used when v4 returns no content).
    private func fetchSpotlightV3() async throws -> WallpaperImage {
        let (locale, country) = spotlightLocale
        let now = ISO8601DateFormatter().string(from: Date())
        let urlString = "https://arc.msn.com/v3/Delivery/Placement"
            + "?pid=338387&fmt=json&rafb=0&ua=WindowsShellClient%2F0"
            + "&cdm=1&disphorzres=9999&dispvertres=9999&lo=80217"
            + "&pl=\(locale)&lc=\(locale)&ctry=\(country)"
            + "&time=\(now)"
        guard let url = URL(string: urlString) else {
            throw WallpaperAPIError.invalidURL(urlString)
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("WindowsShellClient/0 (Windows)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response, source: "Microsoft Spotlight v3")

        let outer = try JSONDecoder().decode(SpotlightResponse.self, from: data)
        guard let items = outer.batchrsp.items, let firstItem = items.first else {
            throw WallpaperAPIError.emptyFeed("Microsoft Spotlight v3")
        }
        guard let innerData = firstItem.item.data(using: .utf8) else {
            throw WallpaperAPIError.malformedData("Spotlight v3 inner JSON is not valid UTF-8")
        }
        let ad = try JSONDecoder().decode(SpotlightAd.self, from: innerData)

        guard let landscapeAsset = ad.ad["image_fullscreen_001_landscape"],
              landscapeAsset.t == "img",
              let imageUrl = landscapeAsset.u else {
            throw WallpaperAPIError.malformedData("No landscape image asset in Spotlight v3 response")
        }

        let title = ad.ad["title_text"]?.tx ?? ad.ad["hs1_title_text"]?.tx
        let copyright = ad.ad["copyright_text"]?.tx
        let description = collectSpotlightHotspotText(from: ad.ad)
        let today = todayString()
        let fileName = fileNameFromImageURL(imageUrl, fallbackStem: today)
        let ctaUri = ad.ad["title_destination_url"]?.u ?? ad.ad["hs1_destination_url"]?.u
        let metadata = WallpaperMetadata(
            fetchedDate: today,
            source: WallpaperSource.spotlight.rawValue,
            imageUrl: imageUrl,
            fileName: fileName,
            title: title,
            copyright: copyright,
            description: description,
            entityId: nil,
            spotlightId: spotlightId(fromCTA: ctaUri),
            copyrightLink: nil,
            iconHoverText: nil,
            ctaText: ad.ad["hs1_cta_text"]?.tx,
            ctaUri: ctaUri
        )

        return WallpaperImage(
            date: today,
            imageUrl: imageUrl,
            title: title,
            copyright: copyright,
            fileName: fileName,
            metadata: metadata
        )
    }

    // MARK: - Helpers

    private func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func bingFileName(urlbase: String) -> String {
        let id = bingImageId(from: urlbase)
        return "\(id)_UHD.jpg"
    }

    private func bingImageId(from urlbase: String) -> String {
        if let components = URLComponents(string: "https://www.bing.com\(urlbase)"),
           let query = components.queryItems?.first(where: { $0.name == "id" })?.value {
            return query
        }
        return urlbase
            .replacingOccurrences(of: "/th?id=", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func bingSpotlightId(from urlbase: String) -> String? {
        let id = bingImageId(from: urlbase)
        guard id.hasPrefix("OHR.") else { return nil }
        let withoutPrefix = id.dropFirst(4)
        if let underscore = withoutPrefix.firstIndex(of: "_") {
            return String(withoutPrefix[..<underscore])
        }
        return String(withoutPrefix)
    }

    /// Uses the last path component of the image URL (Microsoft CDN names) when available.
    private func fileNameFromImageURL(_ imageUrl: String, fallbackStem: String) -> String {
        guard let url = URL(string: imageUrl) else {
            return sanitizedFileName("\(fallbackStem).jpg")
        }
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/", last.contains(".") {
            return sanitizedFileName(last)
        }
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        return sanitizedFileName("\(fallbackStem).\(ext)")
    }

    private func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let cleaned = name.unicodeScalars.map { invalid.contains($0) ? "_" : Character($0) }
        return String(cleaned).replacingOccurrences(of: "..", with: "_")
    }

    private func spotlightId(fromCTA uri: String?) -> String? {
        guard let uri, let url = URL(string: uri.replacingOccurrences(of: "microsoft-edge:", with: "")),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name == "spotlightid" })?.value else {
            return nil
        }
        return id
    }

    private func collectSpotlightHotspotText(from ad: [String: SpotlightAsset]) -> String? {
        var parts: [String] = []
        let keys = ad.keys.filter { $0.hasSuffix("_title_text") }.sorted()
        for key in keys {
            if let text = ad[key]?.tx?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                parts.append(text)
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    private func validateHTTP(_ response: URLResponse, source: String) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        throw WallpaperAPIError.httpError(http.statusCode, source)
    }
}

// MARK: - Errors

enum WallpaperAPIError: LocalizedError {
    case invalidURL(String)
    case httpError(Int, String)
    case emptyFeed(String)
    case malformedData(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):        return "Invalid URL: \(url)"
        case .httpError(let c, let s):    return "HTTP \(c) from \(s)"
        case .emptyFeed(let s):           return "\(s) returned an empty feed"
        case .malformedData(let msg):     return "Malformed response: \(msg)"
        }
    }
}
