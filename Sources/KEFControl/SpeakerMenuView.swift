import AppKit
import SwiftUI

struct SpeakerMenuView: View {
    private let groupedShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject var appState: AppState

    @State private var sliderVolume: Double = 0
    @State private var isDraggingVolume = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerSection
            subtleDivider

            if appState.isConnected {
                connectedContent
            } else {
                disconnectedContent
            }

            subtleDivider
            footerActions
        }
        .padding(16)
        .frame(width: 336)
        .onChange(of: appState.displayedVolume) { _, newValue in
            if !isDraggingVolume {
                sliderVolume = Double(newValue)
            }
        }
        .onAppear {
            appState.setVolumeHUDSuppressed(true)
            sliderVolume = Double(appState.displayedVolume)
        }
        .onDisappear {
            appState.setVolumeHUDSuppressed(false)
        }
    }

    private var subtleDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.18))
            .frame(height: 1)
    }

    private var connectedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            primaryControlsSection

            if appState.status == .powerOn {
                volumeSection

                if appState.isPlaying, let nowPlaying = appState.nowPlaying, nowPlaying.hasInfo {
                    nowPlayingSection(nowPlaying)
                }

                if appState.source == .wifi || appState.source == .bluetooth {
                    playbackSection
                }
            } else {
                standbySection
            }
        }
    }

    private var disconnectedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color(nsColor: .selectedControlColor).opacity(0.12))
                        .frame(width: 42, height: 42)

                    Image(systemName: appState.connectionError == nil ? "hifispeaker" : "wifi.exclamationmark")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(disconnectedTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(disconnectedMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                if appState.speakerMAC != nil {
                    Button("Wake Speaker") {
                        appState.wakeSpeaker()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.isBusy)
                }

                Button(appState.connectionError == nil ? "Retry" : "Try Again") {
                    appState.startConnection()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(appState.isBusy)
            }

            if appState.isBusy {
                Label("Waking speaker…", systemImage: "bolt.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if appState.discovery.isSearching {
                Label("Searching for speakers…", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)

                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if appState.isConnected, let host = appState.currentHost {
                    Label(host, systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
            statusBadge
        }
    }

    private var primaryControlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Power")
                        .font(.subheadline)
                    Text(appState.status == .powerOn ? "Speaker is ready" : "Speaker is in standby")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if appState.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                Toggle("Power", isOn: Binding(
                    get: { appState.status == .powerOn },
                    set: { _ in appState.togglePower() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(appState.isBusy)
            }

            if appState.status == .powerOn {
                subtleDivider

                LabeledContent {
                    Picker("Source", selection: Binding(
                        get: { appState.source },
                        set: { appState.setSource($0) }
                    )) {
                        ForEach(SpeakerSource.inputSources) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 138)
                    .disabled(appState.isBusy)
                } label: {
                    Text("Source")
                        .font(.subheadline)
                }
                .font(.subheadline)
            }
        }
    }

    private var volumeSection: some View {
        groupedSection {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("Volume")
                Spacer()
                Text("\(Int(sliderVolume))")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Image(systemName: volumeIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                Slider(value: $sliderVolume, in: 0...100, step: 5) { editing in
                    isDraggingVolume = editing
                    if !editing {
                        appState.commitVolume(Int(sliderVolume))
                    }
                }
                .disabled(appState.isBusy || appState.status != .powerOn)
            }
        }
    }

    private func nowPlayingSection(_ info: NowPlayingInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Now Playing")

            if let title = info.title {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }

            if let artist = info.artist {
                Text(artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let album = info.album {
                Text(album)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var playbackSection: some View {
        groupedSection {
            sectionLabel("Playback")

            HStack(spacing: 8) {
                Spacer()

                playbackButton(systemName: "backward.fill") {
                    appState.previousTrack()
                }

                playbackButton(systemName: appState.isPlaying ? "pause.fill" : "play.fill") {
                    appState.togglePlayPause()
                }
                .disabled(appState.isBusy)

                playbackButton(systemName: "forward.fill") {
                    appState.nextTrack()
                }

                Spacer()
            }
        }
    }

    private var standbySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Standby")

            Text("Turn the speaker on to choose a source, adjust volume, or control playback.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footerActions: some View {
        HStack(spacing: 12) {
            Button("Settings") {
                showSettingsFrontmost()
            }

            Spacer()

            Button("Quit KEFControl") {
                NSApplication.shared.terminate(nil)
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }

    private func showSettingsFrontmost() {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            _ = bringSettingsWindowToFront()
        }
    }

    @MainActor
    private func bringSettingsWindowToFront() -> Bool {
        guard let settingsWindow = NSApp.windows.reversed().first(where: isLikelySettingsWindow) else {
            return false
        }

        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func isLikelySettingsWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible, !window.isMiniaturized else { return false }
        guard window.canBecomeKey, window.level == .normal else { return false }

        let className = String(describing: type(of: window))
        let title = window.title.lowercased()
        return className.contains("Settings") || title.contains("settings") || title.isEmpty
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            if appState.isBusy {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(statusBadgeColor)
                    .frame(width: 8, height: 8)
            }

            Text(statusBadgeText)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.16))
                .background(.thinMaterial, in: Capsule(style: .continuous))
        )
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.18), lineWidth: 1)
        }
    }

    private var statusBadgeText: String {
        if appState.isBusy {
            return "Updating"
        }
        if !appState.isConnected {
            if appState.discovery.isSearching {
                return "Searching"
            }
            return appState.connectionError == nil ? "Offline" : "Error"
        }
        return appState.status == .powerOn ? "On" : "Standby"
    }

    private var statusBadgeColor: Color {
        if !appState.isConnected {
            return appState.connectionError == nil ? .gray : .orange
        }
        return appState.status == .powerOn ? .green : .gray
    }

    private var headerTitle: String {
        if appState.isConnected {
            return appState.speakerName.isEmpty ? "KEF Speaker" : appState.speakerName
        }
        return "KEF Control"
    }

    private var headerSubtitle: String {
        if appState.isConnected {
            if !appState.speakerModel.isEmpty {
                return appState.speakerModel
            }
            return "Connected"
        }

        if let error = appState.connectionError, !error.isEmpty {
            return error
        }

        return appState.discovery.isSearching
            ? "Looking for speakers on your network"
            : "Menu bar controls for your KEF speaker"
    }

    private var disconnectedTitle: String {
        if appState.discovery.isSearching {
            return "Searching for speakers"
        }
        if appState.connectionError != nil {
            return "Connection issue"
        }
        return "No speaker connected"
    }

    private var disconnectedMessage: String {
        if let error = appState.connectionError, !error.isEmpty {
            return error
        }
        if appState.discovery.isSearching {
            return "KEFControl is scanning the local network for compatible speakers."
        }
        return "Retry the connection or wake the last known speaker to get back to playback quickly."
    }

    private var volumeIcon: String {
        if sliderVolume == 0 {
            return "speaker.slash.fill"
        } else if sliderVolume < 33 {
            return "speaker.wave.1.fill"
        } else if sliderVolume < 66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func groupedSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            groupedShape
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.14))
                .background(.thinMaterial, in: groupedShape)
        )
        .overlay {
            groupedShape
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.14), lineWidth: 1)
        }
    }

    private func playbackButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
