import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI

public struct NowPlayingTrack: Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var elapsedTime: TimeInterval
    public var isPlaying: Bool
    public var isShuffled: Bool
    public var appName: String
    public var artworkImage: NSImage?
    public var dominantColor: Color

    public var trackIdentity: String {
        "\(title)///\(artist)"
    }

    public init(
        title: String,
        artist: String,
        album: String = "",
        duration: TimeInterval = 210,
        elapsedTime: TimeInterval = 0,
        isPlaying: Bool = true,
        isShuffled: Bool = false,
        appName: String = "Music",
        artworkImage: NSImage? = nil,
        dominantColor: Color = Color(red: 0.85, green: 0.35, blue: 0.48)
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = max(1, duration)
        self.elapsedTime = max(0, min(elapsedTime, max(1, duration)))
        self.isPlaying = isPlaying
        self.isShuffled = isShuffled
        self.appName = appName
        self.artworkImage = artworkImage
        self.dominantColor = dominantColor
    }
}

public enum TrackChangeDirection: String, Sendable, Equatable {
    case forward
    case backward
}

public struct TrackNavigationPulse: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let direction: TrackChangeDirection

    public init(id: UUID = UUID(), direction: TrackChangeDirection) {
        self.id = id
        self.direction = direction
    }
}

public struct TrackChangeEvent: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let artist: String
    public let direction: TrackChangeDirection
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        direction: TrackChangeDirection = .forward,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.direction = direction
        self.timestamp = timestamp
    }
}

public enum ArtworkColorExtractor {
    public static func dominantAccentColor(from image: NSImage) -> Color {
        guard let tiff = image.tiffRepresentation,
              let ciImage = CIImage(data: tiff) else {
            return Color(red: 0.85, green: 0.35, blue: 0.48)
        }

        let extentVector = CIVector(
            x: ciImage.extent.origin.x,
            y: ciImage.extent.origin.y,
            z: ciImage.extent.size.width,
            w: ciImage.extent.size.height
        )

        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: ciImage, kCIInputExtentKey: extentVector]
        ),
        let outputImage = filter.outputImage else {
            return Color(red: 0.85, green: 0.35, blue: 0.48)
        }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull!])
        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        var r = Double(bitmap[0]) / 255.0
        var g = Double(bitmap[1]) / 255.0
        var b = Double(bitmap[2]) / 255.0

        // Boost luminance and saturation slightly so equalizer bars are always vivid against the black notch
        let maxChannel = max(r, g, b)
        if maxChannel < 0.45 && maxChannel > 0.01 {
            let boost = 0.65 / maxChannel
            r = min(1.0, r * boost)
            g = min(1.0, g * boost)
            b = min(1.0, b * boost)
        }

        return Color(red: r, green: g, blue: b)
    }
}
