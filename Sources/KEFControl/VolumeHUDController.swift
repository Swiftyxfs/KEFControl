import AppKit
import SwiftUI

private enum VolumeHUDLayout {
    static let width: CGFloat = 236
    static let height: CGFloat = 78
    static let topInset: CGFloat = 10
    static let trailingInset: CGFloat = 14
    static let visibleDuration: Duration = .seconds(1)
    static let fadeDuration: TimeInterval = 0.18
}

@MainActor
final class VolumeHUDController {
    private let model = VolumeHUDModel()
    private var dismissTask: Task<Void, Never>?
    private var presentationID = 0
    private lazy var panel: NSPanel = makePanel()

    func show(title: String, volume: Int) {
        presentationID += 1
        let currentPresentationID = presentationID
        model.title = title
        model.volume = volume
        positionPanel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: VolumeHUDLayout.visibleDuration)
            } catch {
                return
            }
            guard currentPresentationID == self.presentationID else { return }
            await self.fadeOut(presentationID: currentPresentationID)
        }
    }

    func hide() {
        presentationID += 1
        dismissTask?.cancel()
        dismissTask = nil
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private func fadeOut(presentationID: Int) async {
        await NSAnimationContext.runAnimationGroup { context in
            context.duration = VolumeHUDLayout.fadeDuration
            panel.animator().alphaValue = 0
        }
        guard presentationID == self.presentationID else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: VolumeHUDLayout.width, height: VolumeHUDLayout.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: VolumeHUDView(model: model))
        return panel
    }

    private func positionPanel() {
        let frame = panel.frame
        guard let screen = fallbackScreen else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.maxX - frame.width - VolumeHUDLayout.trailingInset
        let y = visibleFrame.maxY - frame.height - VolumeHUDLayout.topInset
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private var fallbackScreen: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
    }
}

@MainActor
private final class VolumeHUDModel: ObservableObject {
    @Published var title = "KEF"
    @Published var volume = 0
}

private struct VolumeHUDView: View {
    @ObservedObject var model: VolumeHUDModel
    private let hudShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center) {
                Text(displayTitle)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineSpacing(0)
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text("\(model.volume)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.94))
            }
            .frame(height: 24)

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.70))

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.14))
                            .frame(height: 5)

                        Capsule()
                            .fill(.white.opacity(0.60))
                            .frame(width: max(6, geometry.size.width * CGFloat(model.volume) / 100), height: 5)

                        Circle()
                            .fill(.white.opacity(0.98))
                            .frame(width: 8, height: 8)
                            .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                            .offset(x: knobOffset(for: geometry.size.width))
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 10)

                Image(systemName: trailingVolumeIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(width: 16)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 13)
        .frame(width: VolumeHUDLayout.width, height: VolumeHUDLayout.height)
        .background(background)
        .overlay {
            hudShape
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .clipShape(hudShape)
    }

    private var displayTitle: String {
        let trimmed = model.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "KEF" }

        return switch trimmed.uppercased() {
        case "LSXII":
            "LSX II"
        case "LS50WII":
            "LS50 WII"
        default:
            trimmed
        }
    }

    private var trailingVolumeIcon: String {
        if model.volume == 0 {
            "speaker.slash.fill"
        } else if model.volume < 33 {
            "speaker.wave.1.fill"
        } else if model.volume < 66 {
            "speaker.wave.2.fill"
        } else {
            "speaker.wave.3.fill"
        }
    }

    private var background: some View {
        hudShape
            .fill(Color.black.opacity(0.28))
            .background(.ultraThinMaterial, in: hudShape)
            .shadow(color: .black.opacity(0.20), radius: 12, x: 0, y: 8)
    }

    private func knobOffset(for width: CGFloat) -> CGFloat {
        let progress = min(max(CGFloat(model.volume) / 100, 0), 1)
        let knobWidth: CGFloat = 8
        return min(max(width * progress - (knobWidth / 2), 0), width - knobWidth)
    }
}
