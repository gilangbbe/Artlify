//
//  MusicKitClient.swift
//  Artlify / AppShell — `particles` branch
//
//  Karaoke phase 2 — Apple Music catalog source.
//
//  Thin wrapper around `MusicCatalogSearchRequest` that returns
//  songs the user can pick to drive `ApplicationMusicPlayer`. The
//  search side is what makes the installation experience work
//  ("visitors can pick literally any song"); the playback side
//  is `MusicKitPlayer`, lyrics still come from LRCLIB after
//  selection (MusicKit's lyric API requires an extra capability
//  and isn't reachable from a personal team).
//
//  Authorization: first call to `search(_:)` triggers
//  `MusicAuthorization.request()`. If denied, throws
//  `MusicKitError.notAuthorized` so the sheet can surface it.
//

import Foundation
import MusicKit

// MARK: - Errors

enum MusicKitError: LocalizedError {
    case notAuthorized(MusicAuthorization.Status)
    case empty
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthorized(let s):
            switch s {
            case .denied:       return "Apple Music access denied. Enable it in System Settings → Privacy → Media & Apple Music."
            case .restricted:   return "Apple Music is restricted on this Mac (parental controls or MDM)."
            case .notDetermined:return "Apple Music access wasn't granted."
            case .authorized:   return "Authorized — but the request still failed."
            @unknown default:   return "Apple Music authorization unavailable (\(s))."
            }
        case .empty: return "No matches on Apple Music."
        case .underlying(let e): return e.localizedDescription
        }
    }
}

// MARK: - Client

enum MusicKitClient {

    /// Ensure we have authorization. Returns the resolved status; a
    /// non-`.authorized` status throws so callers can short-circuit.
    @discardableResult
    static func ensureAuthorized() async throws -> MusicAuthorization.Status {
        let current = MusicAuthorization.currentStatus
        if current == .authorized { return current }
        let next = await MusicAuthorization.request()
        guard next == .authorized else {
            throw MusicKitError.notAuthorized(next)
        }
        return next
    }

    /// Catalog search for songs matching `query`. Limit is bounded
    /// (server-side max is 25 for catalog search), which is plenty
    /// for an installation picker.
    static func searchSongs(query: String, limit: Int = 25) async throws -> [Song] {
        try await ensureAuthorized()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var request = MusicCatalogSearchRequest(term: trimmed,
                                                types: [Song.self])
        request.limit = max(1, min(limit, 25))
        do {
            let response = try await request.response()
            return Array(response.songs)
        } catch let e as MusicKitError {
            throw e
        } catch {
            throw MusicKitError.underlying(error)
        }
    }
}
