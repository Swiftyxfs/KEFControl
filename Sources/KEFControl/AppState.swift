import SwiftUI

@MainActor
final class AppState: ObservableObject {
    // Connection
    @Published var isConnected = false
    @Published var connectionError: String?
    @Published var currentHost: String?

    // Speaker state
    @Published var speakerName: String = ""
    @Published var speakerModel: String = ""
    @Published var firmwareVersion: String = ""
    @Published var status: SpeakerStatus = .standby
    @Published var source: SpeakerSource = .wifi
    @Published var volume: Int = 0
    @Published var isPlaying = false
    @Published var nowPlaying: NowPlayingInfo?

    // Busy state — set during actions that take time to reflect
    @Published var isBusy = false

    // Settings (persisted)
    @AppStorage("manualIP") var manualIP: String = ""
    @AppStorage("useAutoDiscovery") var useAutoDiscovery: Bool = true

    // Discovery
    let discovery = KEFDiscovery()

    // Internal
    private var speaker: KEFSpeakerAPI?
    private var pollTask: Task<Void, Never>?

    init() {
        startConnection()
    }

    // MARK: - Connection

    func startConnection() {
        disconnect()

        if !manualIP.isEmpty {
            connect(to: manualIP)
        } else if useAutoDiscovery {
            discovery.startDiscovery()
            Task {
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if let first = discovery.speakers.first {
                        connect(to: first.host)
                        return
                    }
                }
                // No speaker found after 10 seconds
            }
        }
    }

    func connect(to host: String) {
        disconnect()
        let api = KEFSpeakerAPI(host: host)
        self.speaker = api
        self.currentHost = host

        Task {
            let reachable = await api.testConnection()
            if reachable {
                isConnected = true
                connectionError = nil
                await refresh()
                startPolling()
            } else {
                isConnected = false
                connectionError = "Cannot reach speaker at \(host)"
                speaker = nil
                currentHost = nil
            }
        }
    }

    func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        speaker = nil
        isConnected = false
        currentHost = nil
        connectionError = nil
        speakerName = ""
        speakerModel = ""
        firmwareVersion = ""
        status = .standby
        source = .wifi
        volume = 0
        isPlaying = false
        nowPlaying = nil
        isBusy = false
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                await refresh()
            }
        }
    }

    func refresh() async {
        guard let speaker else { return }

        do {
            async let s = speaker.getStatus()
            async let src = speaker.getSource()
            async let vol = speaker.getVolume()
            async let name = speaker.getSpeakerName()
            async let mf = speaker.getModelAndFirmware()

            self.status = try await s
            self.source = try await src
            self.volume = try await vol
            self.speakerName = try await name
            let modelFw = try await mf
            self.speakerModel = modelFw.model
            self.firmwareVersion = modelFw.firmware

            if self.status == .powerOn {
                self.isPlaying = (try? await speaker.getIsPlaying()) ?? false
                if self.isPlaying {
                    self.nowPlaying = try? await speaker.getNowPlayingInfo()
                } else {
                    self.nowPlaying = nil
                }
            } else {
                self.isPlaying = false
                self.nowPlaying = nil
            }
        } catch {
            if !(await speaker.testConnection()) {
                isConnected = false
                connectionError = "Lost connection to speaker"
            }
        }
    }

    /// Poll rapidly until the expected condition is met, or timeout.
    private func waitForState(timeout: Duration = .seconds(8), condition: @escaping () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(400))
            await refresh()
            if condition() { return }
        }
    }

    // MARK: - Actions

    func commitVolume(_ newVolume: Int) {
        volume = newVolume
        guard let speaker else { return }
        Task {
            try? await speaker.setVolume(newVolume)
        }
    }

    func setSource(_ newSource: SpeakerSource) {
        guard let speaker else { return }
        let oldSource = source
        isBusy = true
        Task {
            try? await speaker.setSource(newSource)
            await waitForState { self.source == newSource || self.source != oldSource }
            // Speaker may take a moment to settle the per-source volume
            try? await Task.sleep(for: .milliseconds(500))
            await refresh()
            isBusy = false
        }
    }

    func togglePower() {
        guard let speaker else { return }
        let wasPoweredOn = status == .powerOn
        isBusy = true
        Task {
            if wasPoweredOn {
                try? await speaker.shutdown()
                await waitForState { self.status == .standby }
            } else {
                try? await speaker.powerOn()
                await waitForState { self.status == .powerOn }
            }
            isBusy = false
        }
    }

    func togglePlayPause() {
        guard let speaker else { return }
        let wasPlaying = isPlaying
        isBusy = true
        Task {
            try? await speaker.togglePlayPause()
            await waitForState(timeout: .seconds(4)) { self.isPlaying != wasPlaying }
            isBusy = false
        }
    }

    func nextTrack() {
        guard let speaker else { return }
        Task {
            try? await speaker.nextTrack()
            try? await Task.sleep(for: .milliseconds(500))
            await refresh()
        }
    }

    func previousTrack() {
        guard let speaker else { return }
        Task {
            try? await speaker.previousTrack()
            try? await Task.sleep(for: .milliseconds(500))
            await refresh()
        }
    }
}
