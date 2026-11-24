import Foundation

struct TranscriptFiling: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case topic = "Topic"
        case youtube = "YouTube"
    }

    var kind: Kind = .topic
    var channel: YouTubeChannel?
    var videoURL: String?

    static func suggested(source: String, text: String = "") -> Self {
        if let link = YouTubeLink(source) {
            return Self(kind: .youtube, channel: link.channel, videoURL: link.videoID == nil ? nil : link.url.absoluteString)
        }
        return Self(kind: TranscriptTimecode.hasCopiedCaptions(text) ? .youtube : .topic)
    }
}

struct YouTubeChannel: Codable, Hashable, Identifiable {
    let name: String
    let url: URL?

    init?(name: String, url: URL? = nil) {
        let cleaned = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        self.name = cleaned
        self.url = url
    }

    var nameKey: String {
        let trimmed = name.hasPrefix("@") ? String(name.dropFirst()) : name
        return trimmed.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    var channelPath: String? {
        url.flatMap { YouTubeLink($0.absoluteString)?.channelPath }
    }

    var id: String { channelPath.map { "channel:\($0)" } ?? "name:\(nameKey)" }
}

struct YouTubeFolder: Identifiable {
    let id: String
    let channel: YouTubeChannel?
    let transcriptIDs: Set<Int64>

    var title: String { channel?.name ?? "Needs channel" }

    static func sections(for records: [TranscriptRecord]) -> [Self] {
        let videos = records.filter { $0.folder.kind == .youtube }
        let channels = videos.compactMap { $0.folder.channel }
        let known = Dictionary(grouping: channels.filter { $0.channelPath != nil }, by: \.nameKey)

        let groups = Dictionary(grouping: videos) { record -> String in
            guard let channel = record.folder.channel else { return "unassigned" }
            if channel.channelPath == nil, let matches = known[channel.nameKey],
               Set(matches.map(\.id)).count == 1, let match = matches.first {
                return match.id
            }
            return channel.id
        }
        return groups.map { id, records in
            let channels = records.compactMap { $0.folder.channel }
            return Self(id: id, channel: channels.first(where: { $0.id == id }) ?? channels.first,
                        transcriptIDs: Set(records.map(\.id)))
        }.sorted {
            if ($0.channel == nil) != ($1.channel == nil) { return $1.channel == nil }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

struct YouTubeLink {
    let url: URL
    let videoID: String?
    let channelPath: String?
    let channel: YouTubeChannel?

    init?(_ source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: address), let host = components.host?.lowercased(),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil,
              host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
                  || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com"),
              let url = components.url else { return nil }
        self.url = url
        let path = components.path.split(separator: "/").map(String.init)
        var video: String?
        if host == "youtu.be" {
            video = path.first
        } else if path.first == "watch" {
            video = components.queryItems?.first(where: { $0.name == "v" })?.value
        } else if path.count >= 2, ["shorts", "live", "embed", "v"].contains(path[0]) {
            video = path[1]
        }
        videoID = video.flatMap {
            $0.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) == nil ? nil : $0
        }

        if let first = path.first, first.hasPrefix("@"), first.count > 1 {
            channelPath = first.lowercased()
            channel = YouTubeChannel(name: first, url: url)
        } else if path.count >= 2, ["channel", "c", "user"].contains(path[0]) {
            let slug = path[0] == "channel" ? path[1] : path[1].lowercased()
            channelPath = path[0] + "/" + slug
            channel = path[0] == "channel" ? nil : YouTubeChannel(name: path[1], url: url)
        } else {
            channelPath = nil
            channel = nil
        }
    }

    var videoURL: URL? {
        videoID.flatMap { URL(string: "https://www.youtube.com/watch?v=\($0)") }
    }

    func fetchChannel() async -> YouTubeChannel? {
        struct Metadata: Decodable {
            let author_name: String
            let author_url: URL?
        }
        guard let videoURL, var endpoint = URLComponents(string: "https://www.youtube.com/oembed") else { return nil }
        endpoint.queryItems = [URLQueryItem(name: "url", value: videoURL.absoluteString),
                              URLQueryItem(name: "format", value: "json")]
        guard let url = endpoint.url,
              let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 6)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else { return nil }
        return YouTubeChannel(name: metadata.author_name, url: metadata.author_url)
    }
}
