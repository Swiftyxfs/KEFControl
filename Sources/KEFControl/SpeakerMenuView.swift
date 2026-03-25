import SwiftUI

struct SpeakerMenuView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings

    @State private var sliderVolume: Double = 0
    @State private var isDraggingVolume = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !appState.isConnected {
                disconnectedView
            } else {
                connectedView
            }

            Divider()

            Button("Settings...") {
                openSettings()
                // Bring the settings window to front — needed for accessory apps
                NSApplication.shared.activate(ignoringOtherApps: true)
            }

            Button("Quit KEFControl") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
        .onChange(of: appState.displayedVolume) { _, newValue in
            if !isDraggingVolume {
                sliderVolume = Double(newValue)
            }
        }
        .onAppear {
            sliderVolume = Double(appState.displayedVolume)
        }
    }

    // MARK: - Disconnected

    private var disconnectedView: some View {
        VStack(spacing: 8) {
            Image(systemName: "hifispeaker")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)

            if let error = appState.connectionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if appState.discovery.isSearching {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching for speakers...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No speaker connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                if appState.speakerMAC != nil {
                    Button("Wake Speaker") {
                        appState.wakeSpeaker()
                    }
                    .controlSize(.small)
                    .disabled(appState.isBusy)
                }

                Button("Retry") {
                    appState.startConnection()
                }
                .controlSize(.small)
            }

            if appState.isBusy {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waking speaker...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Connected

    private var connectedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.speakerName)
                        .font(.headline)
                    Text(appState.speakerModel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }

            Divider()

            // Power
            HStack {
                Toggle(isOn: Binding(
                    get: { appState.status == .powerOn },
                    set: { _ in appState.togglePower() }
                )) {
                    Text("Power")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(appState.isBusy)

                if appState.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if appState.status == .powerOn {
                // Source
                HStack {
                    Text("Source")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { appState.source },
                        set: { appState.setSource($0) }
                    )) {
                        ForEach(SpeakerSource.inputSources) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    .disabled(appState.isBusy)
                }

                volumeControl

                // Now playing
                if appState.isPlaying, let np = appState.nowPlaying, np.hasInfo {
                    Divider()
                    nowPlayingView(np)
                }

                // Playback controls
                if appState.source == .wifi || appState.source == .bluetooth {
                    playbackControls
                }
            }
        }
    }

    // MARK: - Components

    private var statusBadge: some View {
        HStack(spacing: 4) {
            if appState.isBusy {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(appState.status == .powerOn ? .green : .gray)
                    .frame(width: 8, height: 8)
            }
            Text(appState.status == .powerOn ? "On" : "Standby")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var volumeControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Volume")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: volumeIcon)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)

                Slider(value: $sliderVolume, in: 0...100, step: 5) { editing in
                    isDraggingVolume = editing
                    if !editing {
                        appState.commitVolume(Int(sliderVolume))
                    }
                }

                Text("\(Int(sliderVolume))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 32, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
        )
    }

    private var volumeIcon: String {
        if sliderVolume == 0 {
            "speaker.slash.fill"
        } else if sliderVolume < 33 {
            "speaker.wave.1.fill"
        } else if sliderVolume < 66 {
            "speaker.wave.2.fill"
        } else {
            "speaker.wave.3.fill"
        }
    }

    private func nowPlayingView(_ info: NowPlayingInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = info.title {
                Text(title)
                    .font(.callout.bold())
                    .lineLimit(1)
            }
            if let artist = info.artist {
                HStack(spacing: 0) {
                    Text(artist)
                    if let album = info.album {
                        Text(" — \(album)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 16) {
            Spacer()
            Button(action: { appState.previousTrack() }) {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.plain)

            Button(action: { appState.togglePlayPause() }) {
                Image(systemName: appState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(appState.isBusy)

            Button(action: { appState.nextTrack() }) {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }
}
