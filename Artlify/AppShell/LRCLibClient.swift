//
//  LRCLibClient.swift
//  Artlify / AppShell — `particles` branch
//
//  Karaoke phase 2 — network slice (lyrics).
//
//  Talks to https://lrclib.net — a free, no-auth, no-key public
//  database of time-synced LRC lyrics. We use two endpoints:
//
//    GET /api/search?q=...
//      or /api/search?track_name=...&artist_name=...
//      → JSON array of candidates (id, trackName, artistName,
//        albumName, duration, plainLyrics, syncedLyrics)
//
//    GET /api/get/{id}
//      → single record (used as a fallback if a search hit comes
//        back with `syncedLyrics: null` for some reason)
//
//  Why LRCLIB and not MusicKit lyrics:
//  - MusicKit lyrics require an Apple Music subscription on the
//    signed-in user *and* a paid developer membership for the
//    capability. LRCLIB needs neither.
//  - LRC strings drop straight into our existing `LRCParser.parse`.
//  - Real time-synced data per song, no per-track licensing dance.
//
//  Failure model: every call returns a `Result`-ish via `throws`.
//  The UI layer turns thrown errors into a visible error state in
//  the sheet — we never silently swallow.
//

import Foundation

// MARK: - DTOs (one-to-one with the LRCLIB JSON)

/// Decoded shape of a single LRCLIB search hit / get response.
/// Fields named to match the upstream JSON exactly so the
/// `Decodable` synthesis Just Works without a `CodingKeys`.
struct LRCLibTrack: Decodable, Identifiable, Hashable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String?
    /// Seconds. LRCLIB returns this as a Double.
    let duration: Double?
    let instrumental: Bool?
    /// Un-timed lyric text. Useful only as a last-resort fallback —
    /// we always prefer `syncedLyrics` because that's an LRC string.
    let plainLyrics: String?
    /// The thing we actually want. May be nil for instrumental
    /// tracks or for entries that LRCLIB only has plain text for.
    let syncedLyrics: String?
}

// MARK: - Errors

/// Errors raised by `LRCLibClient`. Kept narrow on purpose: the
/// UI only really cares about "no results" vs "something broke",
/// the rest is logged. `LocalizedError` lets us surface human text
/// in the sheet without a switch on the call site.
enum LRCLibError: LocalizedError {
    case badURL
    case transport(URLError)
    case http(Int)
    case decode(Error)
    case noResults
    case noSyncedLyrics

    var errorDescription: String? {
        switch self {
        case .badURL:           return "Couldn't build the LRCLIB URL."
        case .transport(let e): return "Network error: \(e.localizedDescription)"
        case .http(let code):   return "LRCLIB returned HTTP \(code)."
        case .decode(let e):    return "Couldn't parse LRCLIB response: \(e.localizedDescription)"
        case .noResults:        return "No matches on LRCLIB."
        case .noSyncedLyrics:   return "That track has no time-synced lyrics on LRCLIB."
        }
    }
}

// MARK: - Client

/// Stateless HTTP client. Methods are `async throws`. Holds no
/// session of its own — uses `URLSession.shared`, which honours
/// the system proxy + cache config we want for this scale.
enum LRCLibClient {

    /// User-Agent is *required* by LRCLIB's TOS; they bounce calls
    /// with no UA. The format is "App/Version (contact-or-repo)".
    private static let userAgent = "Artlify/1.0 (https://github.com/local/artlify)"

    /// Free-text search. Matches across title + artist + album.
    /// Returns up to whatever LRCLIB serves (typically ~20 hits).
    static func search(query: String) async throws -> [LRCLibTrack] {
        var comps = URLComponents(string: "https://lrclib.net/api/search")
        comps?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps?.url else { throw LRCLibError.badURL }
        return try await get(url)
    }

    /// Targeted search by track + artist. Higher precision than `q`
    /// when we already know both fields (e.g. coming from MusicKit).
    static func search(track: String, artist: String) async throws -> [LRCLibTrack] {
        var comps = URLComponents(string: "https://lrclib.net/api/search")
        comps?.queryItems = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let url = comps?.url else { throw LRCLibError.badURL }
        return try await get(url)
    }

    /// Fetch a single record by LRCLIB id. Used as a fallback when a
    /// search hit lacks `syncedLyrics` — sometimes the /get endpoint
    /// has fuller data than the /search summary.
    static func getByID(_ id: Int) async throws -> LRCLibTrack {
        guard let url = URL(string: "https://lrclib.net/api/get/\(id)") else {
            throw LRCLibError.badURL
        }
        let one: LRCLibTrack = try await getOne(url)
        return one
    }

    // MARK: Private transport

    private static func makeRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        return req
    }

    private static func get(_ url: URL) async throws -> [LRCLibTrack] {
        let data = try await fetchData(url)
        do {
            return try JSONDecoder().decode([LRCLibTrack].self, from: data)
        } catch {
            throw LRCLibError.decode(error)
        }
    }

    private static func getOne(_ url: URL) async throws -> LRCLibTrack {
        let data = try await fetchData(url)
        do {
            return try JSONDecoder().decode(LRCLibTrack.self, from: data)
        } catch {
            throw LRCLibError.decode(error)
        }
    }

    private static func fetchData(_ url: URL) async throws -> Data {
        let req = makeRequest(url)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw LRCLibError.http(http.statusCode)
            }
            return data
        } catch let e as LRCLibError {
            throw e
        } catch let e as URLError {
            throw LRCLibError.transport(e)
        } catch {
            throw LRCLibError.decode(error)
        }
    }
}
