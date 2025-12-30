import Foundation
import MusicKit
import MediaPlayer

/// Sandbox-compliant music control using MusicKit
@MainActor
class MusicService {
    static let shared = MusicService()

    private var isAuthorized = false

    private init() {}

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        let status = await MusicAuthorization.request()
        isAuthorized = status == .authorized
        return isAuthorized
    }

    var authorizationStatus: MusicAuthorization.Status {
        MusicAuthorization.currentStatus
    }

    /// Ensures music access is authorized, requesting if needed
    private func ensureAuthorized() async -> Bool {
        if isAuthorized { return true }
        return await requestAuthorization()
    }

    // MARK: - Playback Control

    func play() async -> String {
        guard await ensureAuthorized() else {
            return "Music access not authorized. Please allow in System Settings."
        }

        let player = ApplicationMusicPlayer.shared
        do {
            try await player.play()
            return "Playing music"
        } catch {
            return "Failed to play: \(error.localizedDescription)"
        }
    }

    func pause() async -> String {
        let player = ApplicationMusicPlayer.shared
        player.pause()
        return "Music paused"
    }

    func next() async -> String {
        let player = ApplicationMusicPlayer.shared
        do {
            try await player.skipToNextEntry()
            if let nowPlaying = player.queue.currentEntry {
                return "Now playing: \(nowPlaying.title)"
            }
            return "Skipped to next track"
        } catch {
            return "Failed to skip: \(error.localizedDescription)"
        }
    }

    func previous() async -> String {
        let player = ApplicationMusicPlayer.shared
        do {
            try await player.skipToPreviousEntry()
            if let nowPlaying = player.queue.currentEntry {
                return "Now playing: \(nowPlaying.title)"
            }
            return "Skipped to previous track"
        } catch {
            return "Failed to skip: \(error.localizedDescription)"
        }
    }

    // MARK: - Search and Play

    func searchAndPlay(query: String) async -> String {
        guard await ensureAuthorized() else {
            return "Music access not authorized. Please allow in System Settings."
        }

        do {
            // Search for songs
            var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
            request.limit = 1

            let response = try await request.response()

            if let song = response.songs.first {
                let player = ApplicationMusicPlayer.shared
                player.queue = [song]
                try await player.play()
                return "Now playing: \(song.title) by \(song.artistName)"
            }

            return "No songs found for '\(query)'"
        } catch {
            return "Search failed: \(error.localizedDescription)"
        }
    }

    func playPlaylist(name: String) async -> String {
        guard await ensureAuthorized() else {
            return "Music access not authorized. Please allow in System Settings."
        }

        do {
            // Search for playlists
            var request = MusicCatalogSearchRequest(term: name, types: [Playlist.self])
            request.limit = 5

            let response = try await request.response()

            if let playlist = response.playlists.first {
                let player = ApplicationMusicPlayer.shared
                player.queue = ApplicationMusicPlayer.Queue(for: [playlist])
                try await player.play()
                return "Playing playlist: \(playlist.name)"
            }

            // If no playlist found, try to find songs matching the genre/mood
            return await searchAndPlay(query: name)
        } catch {
            return "Failed to play playlist: \(error.localizedDescription)"
        }
    }

    // MARK: - Now Playing Info

    func getNowPlaying() -> (title: String?, artist: String?, artwork: Data?)? {
        let player = ApplicationMusicPlayer.shared

        guard let entry = player.queue.currentEntry else {
            return nil
        }

        return (entry.title, entry.subtitle, nil)
    }

    // MARK: - Control Action Handler

    func handleAction(action: String, query: String?) async -> String {
        switch action.lowercased() {
        case "play":
            if let query = query, !query.isEmpty {
                return await searchAndPlay(query: query)
            } else {
                return await play()
            }

        case "pause":
            return await pause()

        case "next":
            return await next()

        case "previous":
            return await previous()

        case "playlist":
            if let query = query, !query.isEmpty {
                return await playPlaylist(name: query)
            } else {
                return "Please specify a playlist name or genre"
            }

        default:
            return "Unknown music action: \(action)"
        }
    }
}
