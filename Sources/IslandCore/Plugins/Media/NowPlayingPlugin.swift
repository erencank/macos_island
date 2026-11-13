import Combine
import Foundation
import SwiftUI

public enum NowPlayingThemeStyle: String, CaseIterable, Identifiable, Sendable {
    case monochrome
    case colored
    case gradient

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .monochrome: return "Monochrome"
        case .colored: return "Colored"
        case .gradient: return "Gradient"
        }
    }
}

public enum NowPlayingAuxiliaryAction: String, CaseIterable, Identifiable, Sendable {
    case favorite
    case shuffle
    case repeatTrack
    case copyLink

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .favorite: return "Favorite"
        case .shuffle: return "Shuffle"
        case .repeatTrack: return "Repeat"
        case .copyLink: return "Copy"
        }
    }
    public var symbolName: String {
        switch self {
        case .favorite: return "star.fill"
        case .shuffle: return "shuffle"
        case .repeatTrack: return "repeat"
        case .copyLink: return "link"
        }
    }
}

public enum WaveformIntensity: String, CaseIterable, Identifiable, Sendable {
    case calm
    case medium
    case intense

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .calm: return "Calm"
        case .medium: return "Medium"
        case .intense: return "Intense"
        }
    }
    public var symbolName: String {
        switch self {
        case .calm: return "water.waves"
        case .medium: return "waveform"
        case .intense: return "bolt.fill"
        }
    }
}

/// Animated multi-bar equalizer visualizer matching the right-side waveform in Alcove,
/// driven by native spring physics with configurable intensity dynamics (Calm, Medium, Intense).
public struct AudioWaveformView: View {
    public let isPlaying: Bool
    public let tintColor: Color
    public let intensity: WaveformIntensity

    private let barCount = 5
    private let barSpeeds: [Double] = [1.0, 0.95, 1.05, 0.92, 1.02]

    public init(
        isPlaying: Bool,
        tintColor: Color,
        intensity: WaveformIntensity = .medium
    ) {
        self.isPlaying = isPlaying
        self.tintColor = tintColor
        self.intensity = intensity
    }

    private var phases: [[CGFloat]] {
        switch intensity {
        case .calm:
            return [
                [4.0, 7.5, 5.0, 9.0],
                [4.5, 9.5, 6.0, 11.0],
                [5.0, 11.5, 7.0, 12.0],
                [4.5, 9.5, 6.0, 11.0],
                [3.5, 7.0, 4.5, 8.5]
            ]
        case .medium:
            return [
                [4.0, 9.5, 6.0, 11.0],
                [4.5, 13.0, 7.0, 14.5],
                [5.0, 15.0, 8.0, 13.5],
                [4.5, 12.5, 6.5, 14.0],
                [3.5, 9.0, 5.0, 10.5]
            ]
        case .intense:
            return [
                [3.5, 13.5, 5.0, 12.0],
                [4.0, 16.0, 6.5, 14.5],
                [5.0, 16.5, 7.5, 15.0],
                [4.0, 15.0, 6.0, 13.5],
                [3.5, 12.0, 4.5, 10.5]
            ]
        }
    }

    private var springResponse: Double {
        switch intensity {
        case .calm: return 0.60
        case .medium: return 0.46
        case .intense: return 0.28
        }
    }

    private var dampingFraction: Double {
        switch intensity {
        case .calm: return 0.95
        case .medium: return 0.88
        case .intense: return 0.72
        }
    }

    public var body: some View {
        let activePhases = phases
        let response = springResponse
        let damping = dampingFraction

        Group {
            if isPlaying {
                HStack(alignment: .center, spacing: 2.5) {
                    ForEach(0..<barCount, id: \.self) { index in
                        PhaseAnimator(activePhases[index]) { height in
                            Capsule(style: .continuous)
                                .fill(tintColor)
                                .frame(width: 2.3, height: height)
                        } animation: { _ in
                            .spring(response: response * barSpeeds[index], dampingFraction: damping)
                        }
                        .id("\(intensity.rawValue)-\(index)")
                    }
                }
                .id(intensity)
            } else {
                HStack(alignment: .center, spacing: 2.5) {
                    ForEach(0..<barCount, id: \.self) { _ in
                        Capsule(style: .continuous)
                            .fill(tintColor.opacity(0.6))
                            .frame(width: 2.3, height: 3.5)
                    }
                }
            }
        }
        .frame(height: 16)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: isPlaying)
    }
}

public struct AlbumArtworkThumbnail: View {
    public let image: NSImage?
    public let accentColor: Color
    public let size: CGFloat
    public let cornerRadius: CGFloat

    public init(image: NSImage?, accentColor: Color, size: CGFloat, cornerRadius: CGFloat) {
        self.image = image
        self.accentColor = accentColor
        self.size = size
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        Group {
            if let nsImage = image {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            accentColor.opacity(0.65),
                            accentColor.opacity(0.28)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundColor(.white.opacity(0.88))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
        )
    }
}

private func directionalTrackTransition(direction: TrackChangeDirection) -> AnyTransition {
    .asymmetric(
        insertion: .move(edge: direction == .forward ? .trailing : .leading)
            .combined(with: .opacity),
        removal: .move(edge: direction == .forward ? .leading : .trailing)
            .combined(with: .opacity)
    )
}

/// Full expanded Now Playing card matching your screenshot 5:
/// - Top row: Rounded album cover on left, Track title & Artist in center-left, animated waveform on right
/// - Middle row: Elapsed timestamp (`2:02`), interactive progress scrubber capsule, remaining timestamp (`-2:33`)
/// - Bottom row: Shuffle, Previous, Play/Pause, Next, and Output Device icon (`laptopcomputer`)
public struct NowPlayingExpandedCardView: View {
    @ObservedObject public var mediaService: MediaRemoteStreamService
    public var themeStyle: NowPlayingThemeStyle
    public var auxiliaryAction: NowPlayingAuxiliaryAction
    public var waveformIntensity: WaveformIntensity

    @State private var nudgeOffsetX: CGFloat = 0
    @State private var artworkPulseScale: CGFloat = 1.0
    @State private var highlightedDirection: TrackChangeDirection?
    @State private var pulseResetTask: Task<Void, Never>?
    @State private var hasAppeared: Bool = false
    @State private var lastHandledPulseID: UUID?

    public init(
        mediaService: MediaRemoteStreamService,
        themeStyle: NowPlayingThemeStyle = .colored,
        auxiliaryAction: NowPlayingAuxiliaryAction = .shuffle,
        waveformIntensity: WaveformIntensity = .medium
    ) {
        self.mediaService = mediaService
        self.themeStyle = themeStyle
        self.auxiliaryAction = auxiliaryAction
        self.waveformIntensity = waveformIntensity
    }

    public var body: some View {
        let track = mediaService.currentTrack ?? NowPlayingTrack(
            title: "Not Playing",
            artist: "Play music in Spotify, Music, or your browser",
            duration: 180,
            elapsedTime: 0,
            isPlaying: false
        )
        let direction = mediaService.latestTrackChange?.direction ?? .forward
        let trackKey = track.trackIdentity

        VStack(spacing: 14) {
            // Top Metadata Row
            HStack(alignment: .center, spacing: 14) {
                ZStack(alignment: .leading) {
                    HStack(alignment: .center, spacing: 14) {
                        AlbumArtworkThumbnail(
                            image: track.artworkImage,
                            accentColor: track.dominantColor,
                            size: 52,
                            cornerRadius: 12
                        )
                        .scaleEffect(artworkPulseScale)
                        .shadow(color: track.dominantColor.opacity(0.32), radius: 8, y: 3)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title)
                                .font(.system(size: 14.5, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            Text(track.artist)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white.opacity(0.56))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(trackKey)
                    .transition(hasAppeared ? directionalTrackTransition(direction: direction) : .identity)
                }
                .offset(x: nudgeOffsetX)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                .clipped()
                .padding(.horizontal, -4)
                .padding(.vertical, -8)

                AudioWaveformView(
                    isPlaying: track.isPlaying,
                    tintColor: themeStyle == .monochrome ? .white.opacity(0.85) : track.dominantColor,
                    intensity: waveformIntensity
                )
                .id("expanded-waveform-\(waveformIntensity.rawValue)")
                .padding(.trailing, 4)
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.80), value: trackKey)

            // Middle Interactive Progress Scrubber Row
            HStack(spacing: 10) {
                Text(formatTimestamp(track.elapsedTime))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.52))
                    .frame(width: 34, alignment: .leading)

                GeometryReader { geo in
                    let fraction = max(0.0, min(1.0, track.elapsedTime / max(1.0, track.duration)))
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.22))
                            .frame(height: 5.5)

                        Capsule(style: .continuous)
                            .fill(scrubberFillStyle(for: track.dominantColor))
                            .frame(width: max(6, geo.size.width * CGFloat(fraction)), height: 5.5)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                let ratio = max(0.0, min(1.0, value.location.x / max(1, geo.size.width)))
                                mediaService.seek(to: Double(ratio) * track.duration)
                            }
                    )
                }
                .frame(height: 14)

                Text("-" + formatTimestamp(max(0, track.duration - track.elapsedTime)))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.52))
                    .frame(width: 40, alignment: .trailing)
            }

            // Bottom Transport Controls Row
            HStack(spacing: 0) {
                MediaTransportIconButton(
                    symbolName: auxiliaryAction.symbolName,
                    iconSize: 14.5,
                    buttonSize: CGSize(width: 36, height: 32),
                    tint: track.isShuffled && auxiliaryAction == .shuffle ? track.dominantColor : .white.opacity(0.55)
                ) {
                    if auxiliaryAction == .copyLink {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(track.title) — \(track.artist)", forType: .string)
                    } else {
                        mediaService.sendCommand(.toggleShuffle)
                    }
                }

                Spacer()

                MediaTransportIconButton(
                    symbolName: "backward.fill",
                    iconSize: 18.5,
                    buttonSize: CGSize(width: 44, height: 36),
                    isExternallyHighlighted: highlightedDirection == .backward
                ) {
                    mediaService.sendCommand(.previousTrack)
                }

                Spacer()

                MediaTransportIconButton(
                    symbolName: track.isPlaying ? "pause.fill" : "play.fill",
                    iconSize: 23,
                    buttonSize: CGSize(width: 48, height: 40),
                    prominentHover: true
                ) {
                    mediaService.sendCommand(.togglePlayPause)
                }

                Spacer()

                MediaTransportIconButton(
                    symbolName: "forward.fill",
                    iconSize: 18.5,
                    buttonSize: CGSize(width: 44, height: 36),
                    isExternallyHighlighted: highlightedDirection == .forward
                ) {
                    mediaService.sendCommand(.nextTrack)
                }

                Spacer()

                Image(systemName: "laptopcomputer")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.48))
                    .frame(width: 36, height: 32)
                    .help("Output: MacBook Speakers (\(track.appName))")
            }
            .padding(.horizontal, 6)
        }
        .padding(.top, 6)
        .onAppear {
            lastHandledPulseID = mediaService.latestNavigationPulse?.id
            Task { @MainActor in
                hasAppeared = true
            }
        }
        .onReceive(mediaService.$latestNavigationPulse) { pulse in
            guard hasAppeared, let pulse, pulse.id != lastHandledPulseID else { return }
            lastHandledPulseID = pulse.id
            triggerNavigationPulse(pulse)
        }
        .onDisappear {
            pulseResetTask?.cancel()
            pulseResetTask = nil
            nudgeOffsetX = 0
            artworkPulseScale = 1.0
            highlightedDirection = nil
            hasAppeared = false
        }
    }

    private func triggerNavigationPulse(_ pulse: TrackNavigationPulse) {
        pulseResetTask?.cancel()
        withAnimation(.spring(response: 0.16, dampingFraction: 0.72)) {
            nudgeOffsetX = pulse.direction == .forward ? -14 : 14
            artworkPulseScale = 0.94
            highlightedDirection = pulse.direction
        }
        pulseResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 130_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                nudgeOffsetX = 0
                artworkPulseScale = 1.0
                highlightedDirection = nil
            }
        }
    }

    private func scrubberFillStyle(for accent: Color) -> AnyShapeStyle {
        switch themeStyle {
        case .monochrome:
            return AnyShapeStyle(Color.white.opacity(0.82))
        case .colored:
            return AnyShapeStyle(accent)
        case .gradient:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [accent, Color.mint],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

/// Interactive transport control button with smooth hover highlight pill, scale lift, and press feedback
private struct MediaTransportIconButton: View {
    let symbolName: String
    let iconSize: CGFloat
    let buttonSize: CGSize
    var tint: Color = .white
    var prominentHover: Bool = false
    var isExternallyHighlighted: Bool = false
    let action: () -> Void

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false

    var body: some View {
        let isHighlighted = isPressed || isExternallyHighlighted
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(isHighlighted ? 0.22 : (isHovered ? (prominentHover ? 0.16 : 0.12) : 0.0)))

                Image(systemName: symbolName)
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundColor((isHovered || isExternallyHighlighted) ? .white : tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: buttonSize.width, height: buttonSize.height)
            .scaleEffect(isPressed ? 0.90 : ((isHovered || isExternallyHighlighted) ? 1.08 : 1.0))
            .animation(.spring(response: 0.20, dampingFraction: 0.72), value: isHovered)
            .animation(.spring(response: 0.14, dampingFraction: 0.75), value: isPressed)
            .animation(.spring(response: 0.18, dampingFraction: 0.75), value: isExternallyHighlighted)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

/// Compact leading view for Now Playing wings:
/// - Smooth directional slide transition for album artwork (next slides left, prev slides right)
/// - Vivid accent-color glow pulse on track transition
/// - Optional track title & artist text reveal
public struct CompactNowPlayingLeadingView: View {
    @ObservedObject public var mediaService: MediaRemoteStreamService
    public var isShowingTrackInfo: Bool
    public var accentColor: Color

    @State private var glowOpacity: Double = 0.0
    @State private var glowScale: CGFloat = 0.8

    public init(
        mediaService: MediaRemoteStreamService,
        isShowingTrackInfo: Bool,
        accentColor: Color
    ) {
        self.mediaService = mediaService
        self.isShowingTrackInfo = isShowingTrackInfo
        self.accentColor = accentColor
    }

    public var body: some View {
        let track = mediaService.currentTrack
        let direction = mediaService.latestTrackChange?.direction ?? .forward
        let trackKey = track?.trackIdentity ?? "empty"

        HStack(spacing: 8) {
            ZStack {
                // Accent glow behind artwork
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(accentColor)
                    .frame(width: 22, height: 22)
                    .blur(radius: 5)
                    .scaleEffect(glowScale)
                    .opacity(glowOpacity)

                if let track = track {
                    AlbumArtworkThumbnail(
                        image: track.artworkImage,
                        accentColor: track.dominantColor,
                        size: 20,
                        cornerRadius: 5
                    )
                    .id(trackKey)
                    .transition(directionalTrackTransition(direction: direction))
                }
            }
            .frame(width: 20, height: 20)

            if isShowingTrackInfo, let track = track {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(track.artist)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, isShowingTrackInfo ? 4 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: isShowingTrackInfo)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: trackKey)
        .onReceive(mediaService.$latestTrackChange) { change in
            guard change != nil else { return }
            triggerGlow()
        }
    }

    private func triggerGlow() {
        glowOpacity = 0.95
        glowScale = 1.35
        withAnimation(.easeOut(duration: 0.7)) {
            glowOpacity = 0.0
            glowScale = 0.8
        }
    }
}

@MainActor
public final class NowPlayingPlugin: ObservableObject, NotchPlugin {
    public let id = "com.island.plugin.nowplaying"
    public let displayName = "Now Playing Media"
    public let symbolName = "music.note"
    @Published public var isEnabled: Bool = true
    @Published public var showWhenPaused: Bool {
        didSet {
            UserDefaults.standard.set(showWhenPaused, forKey: "island.nowplaying.showWhenPaused")
            syncTrackWithCoordinator(mediaService.currentTrack)
        }
    }
    @Published public var themeStyle: NowPlayingThemeStyle {
        didSet {
            UserDefaults.standard.set(themeStyle.rawValue, forKey: "island.nowplaying.themeStyle")
            syncTrackWithCoordinator(mediaService.currentTrack)
        }
    }
    @Published public var disableCompactWaveform: Bool {
        didSet {
            UserDefaults.standard.set(disableCompactWaveform, forKey: "island.nowplaying.disableWaveform")
            syncTrackWithCoordinator(mediaService.currentTrack)
        }
    }
    @Published public var hideWhileSourceAppActive: Bool {
        didSet {
            UserDefaults.standard.set(hideWhileSourceAppActive, forKey: "island.nowplaying.hideSourceActive")
            syncTrackWithCoordinator(mediaService.currentTrack)
        }
    }
    @Published public var auxiliaryAction: NowPlayingAuxiliaryAction {
        didSet {
            UserDefaults.standard.set(auxiliaryAction.rawValue, forKey: "island.nowplaying.auxAction")
            syncTrackWithCoordinator(mediaService.currentTrack)
        }
    }
    @Published public var waveformIntensity: WaveformIntensity {
        didSet {
            guard oldValue != waveformIntensity else { return }
            UserDefaults.standard.set(waveformIntensity.rawValue, forKey: "island.nowplaying.waveformIntensity")
            syncTrackWithCoordinator(mediaService.currentTrack)
        }
    }
    @Published public var showTrackInfoOnChange: Bool {
        didSet {
            UserDefaults.standard.set(showTrackInfoOnChange, forKey: "island.nowplaying.showTrackInfoOnChange")
            if !showTrackInfoOnChange {
                trackInfoDismissTask?.cancel()
                trackInfoDismissTask = nil
                isShowingTrackInfo = false
                syncTrackWithCoordinator(mediaService.currentTrack)
            }
        }
    }
    @Published public var trackInfoDisplayDuration: Double {
        didSet {
            UserDefaults.standard.set(trackInfoDisplayDuration, forKey: "island.nowplaying.trackInfoDuration")
        }
    }
    @Published public private(set) var isShowingTrackInfo: Bool = false

    public let mediaService = MediaRemoteStreamService()
    private weak var coordinator: NotchStateCoordinator?
    private var cancellables = Set<AnyCancellable>()
    private var trackInfoDismissTask: Task<Void, Never>?

    public init() {
        let saved = UserDefaults.standard.object(forKey: "island.plugin.\(id).enabled") as? Bool ?? true
        self.isEnabled = saved
        // Default to false so paused media does not permanently leave the compact notch wings open
        let savedShowPaused = UserDefaults.standard.object(forKey: "island.nowplaying.showWhenPaused") as? Bool ?? false
        self.showWhenPaused = savedShowPaused
        self.themeStyle = NowPlayingThemeStyle(rawValue: UserDefaults.standard.string(forKey: "island.nowplaying.themeStyle") ?? "") ?? .colored
        self.disableCompactWaveform = UserDefaults.standard.object(forKey: "island.nowplaying.disableWaveform") as? Bool ?? false
        self.hideWhileSourceAppActive = UserDefaults.standard.object(forKey: "island.nowplaying.hideSourceActive") as? Bool ?? false
        self.auxiliaryAction = NowPlayingAuxiliaryAction(rawValue: UserDefaults.standard.string(forKey: "island.nowplaying.auxAction") ?? "") ?? .shuffle
        let savedIntensity = UserDefaults.standard.string(forKey: "island.nowplaying.waveformIntensity") ?? ""
        self.waveformIntensity = WaveformIntensity(rawValue: savedIntensity) ?? .medium
        let savedShowTrackInfo = UserDefaults.standard.object(forKey: "island.nowplaying.showTrackInfoOnChange") as? Bool ?? true
        self.showTrackInfoOnChange = savedShowTrackInfo
        let savedDuration = UserDefaults.standard.object(forKey: "island.nowplaying.trackInfoDuration") as? Double ?? 2.5
        self.trackInfoDisplayDuration = max(1.0, min(6.0, savedDuration))
    }

    public func start(coordinator: NotchStateCoordinator) {
        self.coordinator = coordinator
        cancellables.removeAll()

        mediaService.$latestTrackChange
            .compactMap { $0 }
            .sink { [weak self] change in
                self?.handleTrackChange(change)
            }
            .store(in: &cancellables)

        mediaService.$currentTrack
            .sink { [weak self] track in
                self?.syncTrackWithCoordinator(track)
            }
            .store(in: &cancellables)

        coordinator.registerExpandedSwipeHandler(for: id) { [weak self] direction in
            self?.handleExpandedSwipe(direction) ?? false
        }

        mediaService.start()
    }

    public func stop() {
        trackInfoDismissTask?.cancel()
        trackInfoDismissTask = nil
        isShowingTrackInfo = false
        mediaService.stop()
        cancellables.removeAll()
        coordinator?.unregisterExpandedSwipeHandler(for: id)
        coordinator?.clearPersistentActivity(pluginID: id)
    }

    private func handleExpandedSwipe(_ direction: NotchSwipeDirection) -> Bool {
        guard isEnabled,
              let coordinator,
              coordinator.swipeToSkipMediaEnabled,
              coordinator.persistentActivity?.pluginID == id else { return false }
        switch direction {
        case .left:
            mediaService.sendCommand(.nextTrack)
            return true
        case .right:
            mediaService.sendCommand(.previousTrack)
            return true
        case .up, .down:
            return false
        }
    }

    private func handleTrackChange(_ change: TrackChangeEvent) {
        guard isEnabled, showTrackInfoOnChange, let coordinator, coordinator.posture != .expandedCard else { return }

        trackInfoDismissTask?.cancel()
        isShowingTrackInfo = true
        syncTrackWithCoordinator(mediaService.currentTrack)

        let duration = max(1.0, trackInfoDisplayDuration)
        trackInfoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.isShowingTrackInfo = false
            self.syncTrackWithCoordinator(self.mediaService.currentTrack)
        }
    }

    public func simulateTrack() {
        let demoTrack = NowPlayingTrack(
            title: "blue jean",
            artist: "Hazlett",
            album: "Goodbye to the Valley Below",
            duration: 275,
            elapsedTime: 122,
            isPlaying: true,
            isShuffled: false,
            appName: "Spotify",
            artworkImage: nil,
            dominantColor: Color(red: 0.78, green: 0.34, blue: 0.44)
        )
        mediaService.setSimulatedTrack(demoTrack)
    }

    public func simulateNextTrack() {
        let nextTrack = NowPlayingTrack(
            title: "Golden Hour",
            artist: "JVKE",
            album: "this is what ____ feels like",
            duration: 209,
            elapsedTime: 12,
            isPlaying: true,
            appName: "Spotify",
            artworkImage: nil,
            dominantColor: Color(red: 0.96, green: 0.65, blue: 0.28)
        )
        mediaService.setSimulatedTrack(nextTrack, direction: .forward)
    }

    public func simulatePreviousTrack() {
        let prevTrack = NowPlayingTrack(
            title: "blue jean",
            artist: "Hazlett",
            album: "Goodbye to the Valley Below",
            duration: 275,
            elapsedTime: 45,
            isPlaying: true,
            appName: "Spotify",
            artworkImage: nil,
            dominantColor: Color(red: 0.78, green: 0.34, blue: 0.44)
        )
        mediaService.setSimulatedTrack(prevTrack, direction: .backward)
    }

    public func clearSimulatedTrack() {
        trackInfoDismissTask?.cancel()
        trackInfoDismissTask = nil
        isShowingTrackInfo = false
        mediaService.setSimulatedTrack(nil)
    }

    public static func computeTrackInfoWingWidth(for track: NowPlayingTrack?) -> CGFloat {
        guard let track else { return 120 }
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .bold)
        let artistFont = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        let titleWidth = (track.title as NSString).size(withAttributes: [.font: titleFont]).width
        let artistWidth = (track.artist as NSString).size(withAttributes: [.font: artistFont]).width
        let textWidth = max(titleWidth, artistWidth)
        // 10 (leading pad: 8 container + 2 leading view) + 20 (artwork) + 8 (spacing) + textWidth + 10 (trailing pad)
        let needed = 10 + 20 + 8 + textWidth + 10
        return max(70, min(240, ceil(needed)))
    }

    private func syncTrackWithCoordinator(_ track: NowPlayingTrack?) {
        guard isEnabled, let coordinator else { return }
        guard let track, (track.isPlaying || showWhenPaused) else {
            coordinator.clearPersistentActivity(pluginID: id)
            return
        }

        let leading = AnyView(
            CompactNowPlayingLeadingView(
                mediaService: mediaService,
                isShowingTrackInfo: isShowingTrackInfo,
                accentColor: track.dominantColor
            )
        )

        let trailing = AnyView(
            Group {
                if !disableCompactWaveform {
                    AudioWaveformView(
                        isPlaying: track.isPlaying,
                        tintColor: themeStyle == .monochrome ? .white.opacity(0.85) : track.dominantColor,
                        intensity: waveformIntensity
                    )
                    .id("compact-waveform-\(waveformIntensity.rawValue)")
                }
            }
        )

        let expanded = AnyView(
            NowPlayingExpandedCardView(
                mediaService: mediaService,
                themeStyle: themeStyle,
                auxiliaryAction: auxiliaryAction,
                waveformIntensity: waveformIntensity
            )
        )

        let leftWingWidth: CGFloat = isShowingTrackInfo ? Self.computeTrackInfoWingWidth(for: track) : 34

        let payload = NotchActivityPayload(
            pluginID: id,
            priority: .background,
            posture: .compactWings,
            wingSizes: NotchWingSizes(leftWidth: leftWingWidth, rightWidth: disableCompactWaveform ? 0 : 34),
            compactLeadingView: leading,
            compactTrailingView: trailing,
            expandedView: expanded,
            accentColor: track.dominantColor
        )
        coordinator.publishPersistentActivity(payload)
    }
}
