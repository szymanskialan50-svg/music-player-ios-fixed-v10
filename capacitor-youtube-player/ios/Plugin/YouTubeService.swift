import Foundation

// MARK: - Track

/// One video found by the InnerTube search / related endpoints, in the shape the
/// web layer already uses (videoId/title/artist/duration/thumbnail).
struct Track {
    let id: String
    let title: String
    let artist: String
    let duration: Double
    // `var` with a default so both `Track(id:title:artist:duration:)` and
    // `Track(id:...thumb: nil)` compile.
    var thumb: String? = nil
}

/// "3:33" / "1:02:03" -> seconds (0 for anything that is not a clock).
private func parseClock(_ s: String) -> Double {
    var total = 0.0
    for part in s.split(separator: ":") {
        guard let n = Double(part), n >= 0 else { return 0 }
        total = total * 60 + n
    }
    return total
}

// MARK: - Errors

enum YTError: LocalizedError {
    case http(Int)
    case badJSON
    case noAudio
    case unplayable(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "YouTube returned HTTP \(code)."
        case .badJSON: return "Unexpected response from YouTube."
        case .noAudio: return "No playable audio stream was found for this song."
        case .unplayable(let reason): return reason
        }
    }
}

// MARK: - Resolved stream

struct ResolvedStream {
    let url: URL
    /// The User-Agent the CDN expects for this URL (it is bound to the client that requested it).
    let userAgent: String
    /// Index of the client that produced this stream; used to fall back to the next one.
    let clientIndex: Int
    /// Duration in seconds (0 if YouTube did not say).
    let duration: Double
    let title: String?
    let artist: String?
    let isHLS: Bool
}

// MARK: - Service

/// Talks directly to YouTube's InnerTube API (the same private API the official
/// apps use), so no WebView, no iframe and no API key of your own is needed.
///
/// Client identities/versions follow the open-source yt-dlp project and the
/// SmartTubeIOS project (see CREDITS.md). They change from time to time; if
/// playback stops working, update the numbers in `clients` below.
actor YouTubeService {
    static let shared = YouTubeService()

    // MARK: Client table

    struct PlayerClient {
        let name: String
        let nameID: String
        let version: String
        let userAgent: String
        let base: String
        let apiKey: String
        let sendOrigin: Bool
        let client: [String: Any]
    }

    private static let webKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"   // public key from youtube.com's own JS
    private static let vrKey = "AIzaSyDCU8mBbAkSfXX4txZFpEpPEBoAOUMCxkU"    // public key used by yt-dlp's android_vr client

    private static let webVersion = "2.20260708.00.00"
    private static let webUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15"

    /// Order matters: first the iOS client, then Android VR (needs no PO token), then mobile web.
    static let clients: [PlayerClient] = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osDots = os.patchVersion == 0
            ? "\(os.majorVersion).\(os.minorVersion)"
            : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let osUnderscore = osDots.replacingOccurrences(of: ".", with: "_")

        let iosVersion = "21.26.4"
        let ios = PlayerClient(
            name: "iOS", nameID: "5", version: iosVersion,
            userAgent: "com.google.ios.youtube/\(iosVersion) (iPhone16,2; U; CPU iOS \(osUnderscore) like Mac OS X;)",
            base: "https://youtubei.googleapis.com/youtubei/v1",
            apiKey: webKey, sendOrigin: false,
            client: [
                "hl": "en", "gl": "US",
                "clientName": "iOS", "clientVersion": iosVersion,
                "deviceMake": "Apple", "deviceModel": "iPhone16,2",
                "osName": "iPhone", "osVersion": osDots,
                "clientScreen": "WATCH",
            ])

        let vrVersion = "1.65.10"
        let vr = PlayerClient(
            name: "ANDROID_VR", nameID: "28", version: vrVersion,
            userAgent: "com.google.android.apps.youtube.vr.oculus/\(vrVersion) (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            base: "https://www.youtube.com/youtubei/v1",
            apiKey: vrKey, sendOrigin: true,
            client: [
                "clientName": "ANDROID_VR", "clientVersion": vrVersion,
                "deviceMake": "Oculus", "deviceModel": "Quest 3",
                "androidSdkVersion": 32,
                "userAgent": "com.google.android.apps.youtube.vr.oculus/\(vrVersion) (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                "osName": "Android", "osVersion": "12L",
            ])

        let mwebVersion = "2.20260708.05.00"
        let mwebUA =
            "Mozilla/5.0 (iPad; CPU OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1,gzip(gfe)"
        let mweb = PlayerClient(
            name: "MWEB", nameID: "2", version: mwebVersion, userAgent: mwebUA,
            base: "https://www.youtube.com/youtubei/v1",
            apiKey: webKey, sendOrigin: true,
            client: [
                "hl": "en", "gl": "US",
                "clientName": "MWEB", "clientVersion": mwebVersion,
            ])

        return [ios, vr, mweb]
    }()

    // MARK: State

    private let session: URLSession
    private var visitorData: String?
    private var cache: [String: (stream: ResolvedStream, date: Date)] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    // MARK: - Search

    func search(_ query: String) async throws -> [Track] {
        let body: [String: Any] = [
            "context": ["client": ["hl": "en", "gl": "US", "clientName": "WEB", "clientVersion": Self.webVersion]],
            "query": query,
        ]
        let json = try await post(
            url: endpoint("search", base: "https://www.youtube.com/youtubei/v1", key: Self.webKey),
            body: body, headers: webHeaders())
        return Self.extractTracks(from: json)
    }

    /// Songs similar to `videoId` (YouTube "mix" / radio). Used for autoplay.
    func related(to videoId: String) async throws -> [Track] {
        let body: [String: Any] = [
            "context": ["client": ["hl": "en", "gl": "US", "clientName": "WEB", "clientVersion": Self.webVersion]],
            "videoId": videoId,
            "playlistId": "RD\(videoId)",
        ]
        let json = try await post(
            url: endpoint("next", base: "https://www.youtube.com/youtubei/v1", key: Self.webKey),
            body: body, headers: webHeaders())
        return Self.extractTracks(from: json).filter { $0.id != videoId }
    }

    /// Basic info for one video (used for pasted links).
    func trackInfo(videoId: String) async throws -> Track {
        let stream = try await resolve(videoId: videoId)
        return Track(
            id: videoId,
            title: stream.title ?? "YouTube \(videoId)",
            artist: stream.artist ?? "",
            duration: stream.duration)
    }

    func suggestions(for query: String) async -> [String] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty,
            var comps = URLComponents(string: "https://suggestqueries-clients6.youtube.com/complete/search")
        else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "client", value: "youtube"),
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "q", value: query),
        ]
        guard let url = comps.url else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            guard var text = String(data: data, encoding: .utf8),
                let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close
            else { return [] }
            text = String(text[text.index(after: open)..<close])
            guard let raw = text.data(using: .utf8),
                let arr = try JSONSerialization.jsonObject(with: raw) as? [Any],
                arr.count > 1, let items = arr[1] as? [[Any]]
            else { return [] }
            return items.compactMap { $0.first as? String }.prefix(8).map { $0 }
        } catch {
            return []
        }
    }

    // MARK: - Stream resolving

    /// Returns an audio stream for the video. Tries each client in turn starting at `startingAt`.
    func resolve(videoId: String, startingAt first: Int = 0) async throws -> ResolvedStream {
        if first == 0, let hit = cache[videoId], Date().timeIntervalSince(hit.date) < 3 * 3600 {
            return hit.stream
        }
        var lastError: Error = YTError.noAudio
        var index = first
        while index < Self.clients.count {
            do {
                let stream = try await fetchStream(videoId: videoId, clientIndex: index)
                cache[videoId] = (stream, Date())
                return stream
            } catch {
                lastError = error
                index += 1
            }
        }
        throw lastError
    }

    func dropCache(for videoId: String) {
        cache[videoId] = nil
    }

    /// One client, one attempt: ask the player endpoint and pick a format AVPlayer can play.
    private func fetchStream(videoId: String, clientIndex: Int) async throws -> ResolvedStream {
        let c = Self.clients[clientIndex]
        var clientFields = c.client
        if let vd = visitorData { clientFields["visitorData"] = vd }

        let body: [String: Any] = [
            "context": ["client": clientFields],
            "videoId": videoId,
            "racyCheckOk": true,
            "contentCheckOk": true,
            "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]],
        ]

        var headers: [String: String] = [
            "User-Agent": c.userAgent,
            "X-YouTube-Client-Name": c.nameID,
            "X-YouTube-Client-Version": c.version,
        ]
        if c.sendOrigin { headers["Origin"] = "https://www.youtube.com" }
        if let vd = visitorData { headers["X-Goog-Visitor-Id"] = vd }

        let json = try await post(
            url: endpoint("player", base: c.base, key: c.apiKey), body: body, headers: headers)

        let playability = json["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String ?? "UNKNOWN"
        guard let streaming = json["streamingData"] as? [String: Any] else {
            let reason = playability?["reason"] as? String ?? "This video is unavailable (\(status))."
            throw YTError.unplayable(reason)
        }

        let details = json["videoDetails"] as? [String: Any]
        let duration = Double(details?["lengthSeconds"] as? String ?? "") ?? 0
        let title = details?["title"] as? String
        let artist = details?["author"] as? String

        // audio/mp4 (AAC) comes first: it is the only thing AVPlayer decodes out of the
        // box, while the webm/opus formats YouTube offers alongside are not playable there.
        let adaptive = streaming["adaptiveFormats"] as? [[String: Any]] ?? []
        let audios = adaptive.filter { f in
            guard let mime = f["mimeType"] as? String, mime.hasPrefix("audio/mp4"), f["url"] is String else {
                return false
            }
            // Videos with several dubbed audio tracks: keep only the original/default one.
            if let track = f["audioTrack"] as? [String: Any], let isDefault = track["audioIsDefault"] as? Bool,
                isDefault == false
            {
                return false
            }
            return true
        }
        let preferred = audios.first(where: { ($0["itag"] as? Int) == 140 })
            ?? audios.max(by: { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) })

        if let urlString = preferred?["url"] as? String, let url = URL(string: urlString) {
            let approxMs = Double(preferred?["approxDurationMs"] as? String ?? "") ?? 0
            return ResolvedStream(
                url: url, userAgent: c.userAgent, clientIndex: clientIndex,
                duration: duration > 0 ? duration : approxMs / 1000,
                title: title, artist: artist, isHLS: false)
        }

        // No AAC track: an HLS manifest is still playable by AVPlayer, but only if the
        // client actually returned one.
        if let hls = streaming["hlsManifestUrl"] as? String, let url = URL(string: hls) {
            return ResolvedStream(
                url: url, userAgent: c.userAgent, clientIndex: clientIndex,
                duration: duration, title: title, artist: artist, isHLS: true)
        }

        throw YTError.noAudio
    }

    // MARK: - Networking helpers

    private func webHeaders() -> [String: String] {
        [
            "User-Agent": Self.webUA,
            "Origin": "https://www.youtube.com",
            "X-YouTube-Client-Name": "1",
            "X-YouTube-Client-Version": Self.webVersion,
            "Accept-Language": "en-US,en;q=0.9",
        ]
    }

    private func endpoint(_ name: String, base: String, key: String) -> URL {
        var comps = URLComponents(string: "\(base)/\(name)")!
        comps.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]
        return comps.url!
    }

    private func post(url: URL, body: [String: Any], headers: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw YTError.http(code) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTError.badJSON
        }
        if let context = json["responseContext"] as? [String: Any],
            let vd = context["visitorData"] as? String
        {
            visitorData = vd
        }
        return json
    }

    // MARK: - Parsing (nonisolated, pure)

    /// Walks any InnerTube response and collects every video it can find, in order.
    static func extractTracks(from root: Any) -> [Track] {
        var result: [Track] = []
        var seen = Set<String>()

        func add(_ track: Track?) {
            guard let track = track, !track.id.isEmpty, !seen.contains(track.id) else { return }
            seen.insert(track.id)
            result.append(track)
        }

        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                for key in ["videoRenderer", "compactVideoRenderer", "playlistPanelVideoRenderer"] {
                    if let renderer = dict[key] as? [String: Any] {
                        add(parseVideoRenderer(renderer))
                        return
                    }
                }
                if let lockup = dict["lockupViewModel"] as? [String: Any] {
                    add(parseLockup(lockup))
                    return
                }
                for key in dict.keys.sorted() {
                    if let child = dict[key] { walk(child) }
                }
            } else if let array = node as? [Any] {
                for child in array { walk(child) }
            }
        }

        walk(root)
        return result
    }

    private static func text(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String { return simple }
        if let content = dict["content"] as? String { return content }
        if let runs = dict["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func parseVideoRenderer(_ r: [String: Any]) -> Track? {
        guard let id = r["videoId"] as? String else { return nil }
        let title = text(r["title"]) ?? ""
        guard !title.isEmpty else { return nil }
        // Live streams and premieres have no length: not useful in a music player.
        guard let lengthText = text(r["lengthText"]) else { return nil }
        let artist = text(r["ownerText"]) ?? text(r["longBylineText"]) ?? text(r["shortBylineText"]) ?? ""
        return Track(id: id, title: title, artist: artist, duration: parseClock(lengthText), thumb: nil)
    }

    private static func parseLockup(_ lockup: [String: Any]) -> Track? {
        if let type = lockup["contentType"] as? String, type != "LOCKUP_CONTENT_TYPE_VIDEO" { return nil }

        var videoId: String?
        if let ctx = lockup["rendererContext"] as? [String: Any],
            let cmdCtx = ctx["commandContext"] as? [String: Any],
            let onTap = cmdCtx["onTap"] as? [String: Any],
            let command = onTap["innertubeCommand"] as? [String: Any],
            let watch = command["watchEndpoint"] as? [String: Any]
        {
            videoId = watch["videoId"] as? String
        }
        if videoId == nil { videoId = lockup["contentId"] as? String }
        guard let id = videoId, id.count == 11 else { return nil }

        let meta = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]
        let title = text(meta?["title"]) ?? ""
        guard !title.isEmpty else { return nil }

        var artist = ""
        if let content = (meta?["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any],
            let rows = content["metadataRows"] as? [[String: Any]],
            let parts = rows.first?["metadataParts"] as? [[String: Any]],
            let first = parts.first
        {
            artist = text(first["text"]) ?? ""
        }

        // A lockup without a duration badge is a live stream or a short: skip it.
        guard let image = lockup["contentImage"], let clockText = findClock(in: image) else { return nil }
        return Track(id: id, title: title, artist: artist, duration: parseClock(clockText), thumb: nil)
    }

    private static func findClock(in node: Any) -> String? {
        if let dict = node as? [String: Any] {
            if let s = dict["text"] as? String, isClock(s) { return s }
            for key in dict.keys.sorted() {
                if let child = dict[key], let found = findClock(in: child) { return found }
            }
        } else if let array = node as? [Any] {
            for child in array {
                if let found = findClock(in: child) { return found }
            }
        }
        return nil
    }

    private static func isClock(_ s: String) -> Bool {
        s.range(of: "^[0-9]{1,2}(:[0-9]{2}){1,2}$", options: .regularExpression) != nil
    }
}
