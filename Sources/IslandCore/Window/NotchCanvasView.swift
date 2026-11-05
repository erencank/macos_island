import SwiftUI

/// Container that renders the Left Wing and Right Wing around the exact physical MacBook camera notch.
public struct NotchSplitWingContainer<Leading: View, Trailing: View>: View {
    public let leftWingWidth: CGFloat
    public let physicalNotchWidth: CGFloat
    public let rightWingWidth: CGFloat
    public let leading: Leading
    public let trailing: Trailing

    public init(
        leftWingWidth: CGFloat,
        physicalNotchWidth: CGFloat,
        rightWingWidth: CGFloat,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leftWingWidth = leftWingWidth
        self.physicalNotchWidth = physicalNotchWidth
        self.rightWingWidth = rightWingWidth
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Left Wing: Sized strictly to `leftWingWidth`, hugging its content
            HStack(spacing: 5) {
                leading
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(width: max(0, leftWingWidth), alignment: .center)
            .clipped()

            // Physical Hardware Notch Dead-Zone Cutoff (exact camera housing width)
            Spacer(minLength: physicalNotchWidth)
                .frame(width: physicalNotchWidth)

            // Right Wing: Sized strictly to `rightWingWidth`, hugging its content
            HStack(spacing: 5) {
                trailing
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .frame(width: max(0, rightWingWidth), alignment: .center)
            .clipped()
        }
    }
}

/// Renders the Alcove-inspired bright coral-red calibration card at the top of the screen
/// when the user drags the "Notch width", "Notch height", or "Hover exit distance" sliders in Settings.
public struct NotchTuningCalibrationOverlayView: View {
    public let axis: NotchTuningAxis
    public let valuePx: Int

    public init(axis: NotchTuningAxis, valuePx: Int) {
        self.axis = axis
        self.valuePx = valuePx
    }

    private var formattedValue: String {
        if axis == .exitMargin {
            return "\(valuePx) px"
        }
        return valuePx > 0 ? "+\(valuePx)" : "\(valuePx)"
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack {
                if axis == .width {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.black.opacity(0.85))
                    Spacer()
                    Text(formattedValue)
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.black.opacity(0.9))
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.black.opacity(0.85))
                } else if axis == .height {
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.black.opacity(0.85))
                    Spacer()
                    Text(formattedValue)
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.black.opacity(0.9))
                } else {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.black.opacity(0.85))
                    Spacer()
                    Text("Exit Zone: \(formattedValue)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.black.opacity(0.9))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 5)
        }
    }
}

public struct NotchCanvasView: View {
    @ObservedObject public var coordinator: NotchStateCoordinator
    @ObservedObject public var geometryMonitor: ScreenGeometryMonitor
    public var defaultExpandedContent: () -> AnyView

    public init(
        coordinator: NotchStateCoordinator,
        geometryMonitor: ScreenGeometryMonitor,
        defaultExpandedContent: @escaping () -> AnyView
    ) {
        self.coordinator = coordinator
        self.geometryMonitor = geometryMonitor
        self.defaultExpandedContent = defaultExpandedContent
    }

    public var body: some View {
        let geo = geometryMonitor.activeGeometry
        let rawBaseSize = geo.notchFrame.size
        let tunedBaseSize = coordinator.tunedBaseNotchSize(for: rawBaseSize)
        let layout = coordinator.targetLayout(
            for: rawBaseSize,
            hasPhysicalNotch: geo.hasPhysicalNotch
        )
        let isCalibratingNotchSize = (coordinator.activeTuningAxis == .width || coordinator.activeTuningAxis == .height)
        let earRadius: CGFloat = coordinator.posture == .expandedCard ? 16 : 11
        let bottomRadius: CGFloat = coordinator.posture == .expandedCard ? 26 : 13

        let fillColor: Color = isCalibratingNotchSize
            ? Color(red: 1.0, green: 0.30, blue: 0.38)
            : Color(nsColor: .black)

        ZStack(alignment: .top) {
            Color.clear

            ZStack(alignment: .top) {
                // Pure #000000 Pitch-Black Hardware Bezel Fill (or Coral Calibration Fill while tuning in Settings)
                NotchSilhouetteShape(
                    topEarRadius: earRadius,
                    bottomCornerRadius: bottomRadius
                )
                .fill(fillColor)
                .overlay(
                    NotchSilhouetteShape(
                        topEarRadius: earRadius,
                        bottomCornerRadius: bottomRadius
                    )
                    .strokeBorder(
                        Color.white.opacity(coordinator.showContrastOutline && coordinator.posture != .resting ? 0.16 : 0.0),
                        lineWidth: 1.0
                    )
                )
                .shadow(
                    color: Color.black.opacity(coordinator.posture == .expandedCard ? 0.45 : 0.0),
                    radius: 18,
                    x: 0,
                    y: 8
                )

                // Active Foreground Content Layer
                if !isCalibratingNotchSize {
                    notchContentLayer(
                        baseNotchSize: tunedBaseSize,
                        layout: layout,
                        earRadius: earRadius,
                        hasPhysicalNotch: geo.hasPhysicalNotch
                    )
                    .padding(.horizontal, earRadius)
                }
            }
            .frame(width: layout.totalWidth + (earRadius * 2), height: layout.height, alignment: .top)
            .clipShape(
                NotchSilhouetteShape(
                    topEarRadius: earRadius,
                    bottomCornerRadius: bottomRadius
                )
            )
            .contentShape(
                NotchSilhouetteShape(
                    topEarRadius: earRadius,
                    bottomCornerRadius: bottomRadius
                )
            )
            .overlay(alignment: .bottom) {
                if let tuningAxis = coordinator.activeTuningAxis, isCalibratingNotchSize {
                    let val = tuningAxis == .width
                        ? Int(coordinator.notchWidthOffsetPx.rounded())
                        : Int(coordinator.notchHeightOffsetPx.rounded())
                    HStack(spacing: 5) {
                        Image(systemName: tuningAxis == .width ? "arrow.left.and.right" : "arrow.up.and.down")
                            .font(.system(size: 10, weight: .bold))
                        Text(val > 0 ? "+\(val) px" : "\(val) px")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(.black.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(red: 1.0, green: 0.30, blue: 0.38))
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    )
                    .offset(y: 22)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .top)))
                }
            }
            .offset(x: layout.horizontalCenterOffset, y: 0)
            .animation(
                coordinator.posture == .resting ? IslandSprings.collapse : IslandSprings.expand,
                value: layout
            )
            .onTapGesture {
                coordinator.handleNotchClicked()
            }
        }
        .frame(
            width: NotchGeometry.canvasWidth,
            height: NotchGeometry.canvasHeight,
            alignment: .top
        )
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func notchContentLayer(
        baseNotchSize: CGSize,
        layout: NotchLayoutGeometry,
        earRadius: CGFloat,
        hasPhysicalNotch: Bool
    ) -> some View {
        let notchDeadZoneWidth: CGFloat = hasPhysicalNotch ? baseNotchSize.width : 24

        switch coordinator.posture {
        case .resting:
            if !hasPhysicalNotch || coordinator.notchWidthOffsetPx > 0 || coordinator.notchHeightOffsetPx > 0 {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyView()
            }

        case .compactWings:
            if let activity = coordinator.persistentActivity {
                NotchSplitWingContainer(
                    leftWingWidth: layout.leftWingWidth,
                    physicalNotchWidth: notchDeadZoneWidth,
                    rightWingWidth: layout.rightWingWidth
                ) {
                    activity.compactLeadingView
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.5)),
                                removal: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.5))
                            )
                        )
                } trailing: {
                    activity.compactTrailingView
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.5)),
                                removal: .move(edge: .leading).combined(with: .opacity).combined(with: .scale(scale: 0.5))
                            )
                        )
                }
                .frame(height: layout.height)
            }

        case .transientHUD:
            if let hud = coordinator.activeTransientHUD, let hudView = hud.hudView {
                hudView
                    .environment(\.notchDeadZoneWidth, notchDeadZoneWidth)
                    .environment(\.notchWingSizes, NotchWingSizes(leftWidth: layout.leftWingWidth, rightWidth: layout.rightWingWidth))
                    .frame(height: layout.height)
                    .transition(
                        .opacity.combined(with: .scale(scale: 0.88, anchor: .top))
                    )
            }

        case .expandedCard:
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: hasPhysicalNotch ? max(baseNotchSize.height + 2, 36) : 14)

                if let expanded = coordinator.persistentActivity?.expandedView {
                    expanded
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    defaultExpandedContent()
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.bottom, 22)
            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
        }
    }
}

private struct NotchDeadZoneWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 188
}

private struct NotchWingSizesKey: EnvironmentKey {
    static let defaultValue = NotchWingSizes(leftWidth: 82, rightWidth: 82)
}

public extension EnvironmentValues {
    var notchDeadZoneWidth: CGFloat {
        get { self[NotchDeadZoneWidthKey.self] }
        set { self[NotchDeadZoneWidthKey.self] = newValue }
    }

    var notchWingSizes: NotchWingSizes {
        get { self[NotchWingSizesKey.self] }
        set { self[NotchWingSizesKey.self] = newValue }
    }
}
