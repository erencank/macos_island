import SwiftUI

/// Renders the signature MacBook Notch / Alcove silhouette:
/// - Smooth concave "top ears" that flare outward flush into the top bezel of the screen
/// - Smooth convex continuous rounded corners at the bottom left and bottom right
/// - Fully animatable width, height, topEarRadius, and bottomCornerRadius for 120Hz ProMotion springs
public struct NotchSilhouetteShape: Shape, InsettableShape {
    public var topEarRadius: CGFloat
    public var bottomCornerRadius: CGFloat
    public var insetAmount: CGFloat = 0

    public init(topEarRadius: CGFloat = 12, bottomCornerRadius: CGFloat = 18) {
        self.topEarRadius = topEarRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    public func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topEarRadius, bottomCornerRadius) }
        set {
            topEarRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    public func path(in outerRect: CGRect) -> Path {
        let rect = outerRect.insetBy(dx: insetAmount, dy: insetAmount)
        let ear = max(0, min(topEarRadius, rect.width * 0.15, rect.height * 0.45))
        let bottomRadius = max(0, min(bottomCornerRadius, (rect.width - ear * 2) * 0.5, rect.height * 0.5))

        let bodyMinX = rect.minX + ear
        let bodyMaxX = rect.maxX - ear
        let topY = rect.minY
        let bottomY = rect.maxY

        var path = Path()

        // 1. Start at top-left outer ear tip (flush with the top of the screen)
        path.move(to: CGPoint(x: rect.minX, y: topY))

        // 2. Concave top-left ear curving inward and down into the left vertical wall
        if ear > 0.1 {
            path.addQuadCurve(
                to: CGPoint(x: bodyMinX, y: topY + ear),
                control: CGPoint(x: bodyMinX, y: topY)
            )
        } else {
            path.addLine(to: CGPoint(x: bodyMinX, y: topY))
        }

        // 3. Left vertical wall down to the bottom-left corner start
        path.addLine(to: CGPoint(x: bodyMinX, y: bottomY - bottomRadius))

        // 4. Convex bottom-left corner curving into the bottom horizontal edge
        if bottomRadius > 0.1 {
            path.addQuadCurve(
                to: CGPoint(x: bodyMinX + bottomRadius, y: bottomY),
                control: CGPoint(x: bodyMinX, y: bottomY)
            )
        }

        // 5. Bottom horizontal edge across to the bottom-right corner start
        path.addLine(to: CGPoint(x: bodyMaxX - bottomRadius, y: bottomY))

        // 6. Convex bottom-right corner curving up into the right vertical wall
        if bottomRadius > 0.1 {
            path.addQuadCurve(
                to: CGPoint(x: bodyMaxX, y: bottomY - bottomRadius),
                control: CGPoint(x: bodyMaxX, y: bottomY)
            )
        }

        // 7. Right vertical wall up to the top-right ear start
        path.addLine(to: CGPoint(x: bodyMaxX, y: topY + ear))

        // 8. Concave top-right ear flaring upward and outward flush with the top of the screen
        if ear > 0.1 {
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: topY),
                control: CGPoint(x: bodyMaxX, y: topY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: topY))
        }

        path.closeSubpath()
        return path
    }
}

public enum IslandSprings {
    /// Fluid expansion spring with subtle organic cushion
    public static let expand = Animation.spring(response: 0.34, dampingFraction: 0.78, blendDuration: 0.08)
    /// Crisp collapse spring that settles cleanly into the physical hardware notch without clipping
    public static let collapse = Animation.spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.08)
    /// Responsive press/hover pre-tension spring (during the 50ms hover window)
    public static let tension = Animation.spring(response: 0.18, dampingFraction: 0.75)
    /// Snappy progress bar animation for Volume and Brightness keys
    public static let hudProgress = Animation.spring(response: 0.20, dampingFraction: 0.85)
}
