import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

public enum MediaPlaybackCommand: Int32 {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case stop = 3
    case nextTrack = 4
    case previousTrack = 5
    case toggleShuffle = 6
}

@MainActor
public final class MediaRemoteStreamService: ObservableObject {
    @Published public private(set) var currentTrack: NowPlayingTrack?
    @Published public private(set) var latestTrackChange: TrackChangeEvent?

    private var pollTimer: Timer?
    private var progressTickTimer: Timer?
    private var cachedTrackIdentifier: String = ""
    private var cachedArtworkImage: NSImage?
    private var cachedDominantColor: Color = Color(red: 0.85, green: 0.35, blue: 0.48)
    private var isSimulatedTrackActive: Bool = false
    /// Prevents a poll during the first 1.2s after a user clicks Play/Pause from overwriting the optimistic toggle
    private var lastUserCommandTimestamp: Date = .distantPast
    private var lastNavCommand: MediaPlaybackCommand?
    private var lastNavCommandTimestamp: Date = .distantPast

    public init() {}

    public func start() {
        stop()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshNowPlaying()
            }
        }

        progressTickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, var track = self.currentTrack, track.isPlaying else { return }
                track.elapsedTime = min(track.duration, track.elapsedTime + 0.5)
                self.currentTrack = track
            }
        }

        Task {
            await refreshNowPlaying()
        }
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        progressTickTimer?.invalidate()
        progressTickTimer = nil
    }

    public func setSimulatedTrack(_ track: NowPlayingTrack?, direction: TrackChangeDirection? = nil) {
        let prev = currentTrack
        isSimulatedTrackActive = (track != nil)

        if let track {
            if direction != nil || (prev != nil && track.trackIdentity != prev?.trackIdentity) {
                let dir = direction ?? (lastNavCommand == .previousTrack && Date().timeIntervalSince(lastNavCommandTimestamp) < 3.0 ? .backward : .forward)
                latestTrackChange = TrackChangeEvent(
                    title: track.title,
                    artist: track.artist,
                    direction: dir
                )
            }
        } else {
            latestTrackChange = nil
        }

        currentTrack = track
    }

    public func sendCommand(_ command: MediaPlaybackCommand) {
        lastUserCommandTimestamp = Date()
        if command == .nextTrack || command == .previousTrack {
            lastNavCommand = command
            lastNavCommandTimestamp = Date()
        }

        if isSimulatedTrackActive, var track = currentTrack {
            switch command {
            case .play:
                track.isPlaying = true
            case .pause:
                track.isPlaying = false
            case .togglePlayPause:
                track.isPlaying.toggle()
            case .nextTrack:
                track.elapsedTime = 0
            case .previousTrack:
                track.elapsedTime = 0
            case .toggleShuffle:
                track.isShuffled.toggle()
            case .stop:
                track.isPlaying = false
            }
            currentTrack = track
            return
        }

        // Optimistically update UI state immediately so the Play/Pause icon flips on click without lag
        if var track = currentTrack {
            switch command {
            case .togglePlayPause:
                track.isPlaying.toggle()
            case .play:
                track.isPlaying = true
            case .pause:
                track.isPlaying = false
            case .toggleShuffle:
                track.isShuffled.toggle()
            default:
                break
            }
            currentTrack = track
        }

        let appName = currentTrack?.appName ?? ""
        Task.detached { [weak self] in
            if !Self.sendMediaRemoteCommandViaPerlBridge(command) {
                Self.sendFallbackCommand(command, targetApp: appName)
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            await self?.refreshNowPlaying()
        }
    }

    public func seek(to seconds: TimeInterval) {
        lastUserCommandTimestamp = Date()
        if var track = currentTrack {
            track.elapsedTime = max(0, min(seconds, track.duration))
            currentTrack = track
        }

        guard !isSimulatedTrackActive else { return }
        let appName = currentTrack?.appName ?? ""
        Task.detached { [weak self] in
            if !Self.seekViaMediaRemotePerlBridge(seconds) {
                Self.seekViaAppleScript(seconds, targetApp: appName)
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            await self?.refreshNowPlaying()
        }
    }

    public func refreshNowPlaying() async {
        guard !isSimulatedTrackActive else { return }

        let prevTitle = currentTrack?.title
        let prevArtwork = cachedArtworkImage
        let prevColor = cachedDominantColor

        let fetched = await Task.detached(priority: .utility) { () -> NowPlayingTrack? in
            if let mrTrack = Self.queryViaMediaRemoteBridge(
                previousTitle: prevTitle,
                previousArtwork: prevArtwork,
                previousColor: prevColor
            ) {
                return mrTrack
            }
            return Self.queryViaRunningPlayers(
                previousTitle: prevTitle,
                previousArtwork: prevArtwork,
                previousColor: prevColor
            )
        }.value

        if var fetched {
            // If the user just clicked Play/Pause within the last 0.8s, keep their optimistic play/pause state
            // while mediaremoted catches up.
            if Date().timeIntervalSince(lastUserCommandTimestamp) < 0.8,
               let existing = currentTrack,
               existing.title == fetched.title {
                fetched.isPlaying = existing.isPlaying
            }

            let isNewTrack = (currentTrack != nil && fetched.trackIdentity != currentTrack?.trackIdentity)

            if fetched.title != cachedTrackIdentifier || cachedArtworkImage == nil {
                cachedTrackIdentifier = fetched.title
                cachedArtworkImage = fetched.artworkImage
                cachedDominantColor = fetched.dominantColor
            }
            if isNewTrack {
                let direction: TrackChangeDirection
                if lastNavCommand == .previousTrack && Date().timeIntervalSince(lastNavCommandTimestamp) < 3.0 {
                    direction = .backward
                } else {
                    direction = .forward
                }
                self.latestTrackChange = TrackChangeEvent(
                    title: fetched.title,
                    artist: fetched.artist,
                    direction: direction
                )
            }

            self.currentTrack = fetched
        } else if currentTrack != nil && !isSimulatedTrackActive {
            self.currentTrack = nil
        }
    }

    // MARK: - MediaRemote Bridge Helper Invocation

    private nonisolated static func helperDylibPath() -> String? {
        if let bundled = Bundle.main.path(forResource: "libIslandMediaRemoteBridge", ofType: "dylib") {
            return URL(fileURLWithPath: bundled).standardizedFileURL.path
        }
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let adjacentResources = execURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/libIslandMediaRemoteBridge.dylib")
            .path
        if FileManager.default.fileExists(atPath: adjacentResources) {
            return adjacentResources
        }
        let localBuildPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/libIslandMediaRemoteBridge.dylib")
            .standardizedFileURL.path
        if FileManager.default.fileExists(atPath: localBuildPath) {
            return localBuildPath
        }
        return nil
    }

    private nonisolated static func queryViaMediaRemoteBridge(
        previousTitle: String?,
        previousArtwork: NSImage?,
        previousColor: Color
    ) -> NowPlayingTrack? {
        guard let dylibPath = helperDylibPath() else { return nil }

        let perlScript = """
        use DynaLoader;
        my $lib = DynaLoader::dl_load_file($ARGV[0], 0x01) or exit(1);
        my $sym = DynaLoader::dl_find_symbol($lib, "island_mr_query_now_playing_json") or exit(1);
        DynaLoader::dl_install_xsub("main::query_mr", $sym);
        query_mr();
        """

        let proc = Process()
        let outPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = ["-e", perlScript, dylibPath]
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            // IMPORTANT: Read stdout to EOF *before* waitUntilExit() so large base64 album art
            // (>64KB pipe buffer) never deadlocks the subprocess!
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()

            guard !data.isEmpty,
                  let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = dict["title"] as? String,
                  !title.isEmpty else {
                return nil
            }

            let artist = (dict["artist"] as? String) ?? "Unknown Artist"
            let album = (dict["album"] as? String) ?? ""
            let duration = (dict["duration"] as? Double) ?? 200.0
            let elapsed = (dict["elapsedTime"] as? Double) ?? 0.0
            let isPlaying = (dict["isPlaying"] as? Bool) ?? false

            var artwork: NSImage? = (title == previousTitle) ? previousArtwork : nil
            var dominantColor: Color = (title == previousTitle && previousArtwork != nil)
                ? previousColor
                : Color(red: 0.85, green: 0.35, blue: 0.48)

            if artwork == nil,
               let base64 = dict["artworkBase64"] as? String,
               let imgData = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
               let nsImg = NSImage(data: imgData) {
                artwork = nsImg
                dominantColor = ArtworkColorExtractor.dominantAccentColor(from: nsImg)
            }

            return NowPlayingTrack(
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                elapsedTime: elapsed,
                isPlaying: isPlaying,
                appName: "Now Playing",
                artworkImage: artwork,
                dominantColor: dominantColor
            )
        } catch {
            return nil
        }
    }

    private nonisolated static func sendMediaRemoteCommandViaPerlBridge(_ command: MediaPlaybackCommand) -> Bool {
        guard let dylibPath = helperDylibPath() else { return false }
        let perlScript = """
        use DynaLoader;
        my $lib = DynaLoader::dl_load_file($ARGV[0], 0x01) or exit(1);
        my $sym = DynaLoader::dl_find_symbol($lib, "island_mr_send_command_" . $ARGV[1]) or exit(1);
        DynaLoader::dl_install_xsub("main::cmd_mr", $sym);
        cmd_mr();
        """
        let cmdName: String
        switch command {
        case .play: cmdName = "play"
        case .pause: cmdName = "pause"
        case .togglePlayPause: cmdName = "toggle"
        case .nextTrack: cmdName = "next"
        case .previousTrack: cmdName = "prev"
        default: return false
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = ["-e", perlScript, dylibPath, cmdName]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private nonisolated static func seekViaMediaRemotePerlBridge(_ seconds: TimeInterval) -> Bool {
        guard let dylibPath = helperDylibPath(),
              let handle = dlopen(dylibPath, RTLD_LAZY) else { return false }
        defer { dlclose(handle) }
        typealias SeekFn = @convention(c) (Double) -> Int32
        guard let sym = dlsym(handle, "island_mr_seek_to") else { return false }
        let fn = unsafeBitCast(sym, to: SeekFn.self)
        return fn(seconds) != 0
    }

    // MARK: - Spotify & Apple Music Native Bridge (with Spotify Album Cover Fetching)

    private nonisolated static func queryViaRunningPlayers(
        previousTitle: String?,
        previousArtwork: NSImage?,
        previousColor: Color
    ) -> NowPlayingTrack? {
        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })

        if runningBundleIDs.contains("com.spotify.client") {
            if let track = querySpotify(previousTitle: previousTitle, previousArtwork: previousArtwork, previousColor: previousColor) {
                return track
            }
        }

        if runningBundleIDs.contains("com.apple.Music") {
            if let track = queryAppleMusic(previousTitle: previousTitle, previousArtwork: previousArtwork, previousColor: previousColor) {
                return track
            }
        }

        return nil
    }

    private nonisolated static func querySpotify(
        previousTitle: String?,
        previousArtwork: NSImage?,
        previousColor: Color
    ) -> NowPlayingTrack? {
        let script = """
        tell application "Spotify"
            if player state is stopped then return ""
            set tName to name of current track
            set tArtist to artist of current track
            set tAlbum to album of current track
            set tDur to (duration of current track) / 1000.0
            set tPos to player position
            set tState to (player state is playing)
            set tArtUrl to artwork url of current track
            set tShuf to shuffling
            return tName & "|||" & tArtist & "|||" & tAlbum & "|||" & tDur & "|||" & tPos & "|||" & tState & "|||" & tArtUrl & "|||" & tShuf
        end tell
        """
        guard let output = runOsascript(script), !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: "|||")
        guard parts.count >= 8 else { return nil }

        let title = parts[0]
        let artist = parts[1]
        let album = parts[2]
        let duration = Double(parts[3]) ?? 200.0
        let elapsed = Double(parts[4]) ?? 0.0
        let isPlaying = (parts[5] == "true")
        let artworkURLString = parts[6]
        let isShuffled = (parts[7] == "true")

        var artwork: NSImage? = (title == previousTitle) ? previousArtwork : nil
        var dominantColor: Color = (title == previousTitle && previousArtwork != nil)
            ? previousColor
            : Color(red: 0.85, green: 0.35, blue: 0.48)

        if artwork == nil, let url = URL(string: artworkURLString), let data = try? Data(contentsOf: url), let img = NSImage(data: data) {
            artwork = img
            dominantColor = ArtworkColorExtractor.dominantAccentColor(from: img)
        }

        return NowPlayingTrack(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsedTime: elapsed,
            isPlaying: isPlaying,
            isShuffled: isShuffled,
            appName: "Spotify",
            artworkImage: artwork,
            dominantColor: dominantColor
        )
    }

    private nonisolated static func queryAppleMusic(
        previousTitle: String?,
        previousArtwork: NSImage?,
        previousColor: Color
    ) -> NowPlayingTrack? {
        let script = """
        tell application "Music"
            if player state is stopped then return ""
            set tName to name of current track
            set tArtist to artist of current track
            set tAlbum to album of current track
            set tDur to duration of current track
            set tPos to player position
            set tState to (player state is playing)
            return tName & "|||" & tArtist & "|||" & tAlbum & "|||" & tDur & "|||" & tPos & "|||" & tState
        end tell
        """
        guard let output = runOsascript(script), !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: "|||")
        guard parts.count >= 6 else { return nil }

        let title = parts[0]
        let artist = parts[1]
        let album = parts[2]
        let duration = Double(parts[3]) ?? 200.0
        let elapsed = Double(parts[4]) ?? 0.0
        let isPlaying = (parts[5] == "true")

        return NowPlayingTrack(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsedTime: elapsed,
            isPlaying: isPlaying,
            appName: "Music",
            artworkImage: previousArtwork,
            dominantColor: previousColor
        )
    }

    private nonisolated static func sendFallbackCommand(_ command: MediaPlaybackCommand, targetApp: String) {
        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let app: String
        if targetApp == "Music" || (!runningBundleIDs.contains("com.spotify.client") && runningBundleIDs.contains("com.apple.Music")) {
            app = "Music"
        } else {
            app = "Spotify"
        }

        let action: String
        switch command {
        case .play:
            action = "play"
        case .pause:
            action = "pause"
        case .togglePlayPause:
            action = "playpause"
        case .nextTrack:
            action = "next track"
        case .previousTrack:
            action = "previous track"
        case .toggleShuffle:
            action = "set shuffling to not shuffling"
        case .stop:
            action = "pause"
        }
        _ = runOsascript("tell application \"\(app)\" to \(action)")
    }

    private nonisolated static func seekViaAppleScript(_ seconds: TimeInterval, targetApp: String) {
        let app = targetApp == "Music" ? "Music" : "Spotify"
        _ = runOsascript("tell application \"\(app)\" to set player position to \(seconds)")
    }

    private nonisolated static func runOsascript(_ source: String) -> String? {
        let proc = Process()
        let outPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
