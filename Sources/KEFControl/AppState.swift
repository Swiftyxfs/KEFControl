import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum MediaKeyAccessState {
        case unknown
        case working
        case permissionNeeded
        case permissionDenied
        case failedToActivate
    }

    private enum MediaKey {
        static let eventType = 14
        static let eventSubtype = 8
        static let volumeUp = 0
        static let volumeDown = 1
        static let keyDownState = 0xA
        static let repeatMask = 0x1
        static let volumeStep = 5
    }

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
    @Published private(set) var displayedVolume: Int = 0
    @Published var isPlaying = false
    @Published var nowPlaying: NowPlayingInfo?

    // Busy state — set during actions that take time to reflect
    @Published var isBusy = false

    // Settings (persisted)
    @AppStorage("manualIP") var manualIP: String = ""
    @AppStorage("useAutoDiscovery") var useAutoDiscovery: Bool = true
    @AppStorage("useVolumeKeys") var useVolumeKeys: Bool = true {
        didSet {
            refreshMediaKeyAccessStatus()
        }
    }
    @AppStorage("hasRequestedMediaKeyAccess") private var hasRequestedMediaKeyAccess = false

    // Discovery
    let discovery = KEFDiscovery()

    // Internal
    private var speaker: KEFSpeakerAPI?
    private var pollTask: Task<Void, Never>?
    private var pendingCommittedVolume: Int?
    private var pendingVolumeResetTask: Task<Void, Never>?
    private var mediaKeyEventTap: CFMachPort?
    private var mediaKeyRunLoopSource: CFRunLoopSource?
    private let volumeHUD = VolumeHUDController()
    private var isVolumeHUDSuppressed = false

    @Published private(set) var mediaKeyAccessState: MediaKeyAccessState = .unknown
    @Published private(set) var mediaKeyAccessMessage = ""

    init() {
        refreshMediaKeyAccessStatus()
        startConnection()
    }

    func setVolumeHUDSuppressed(_ suppressed: Bool) {
        isVolumeHUDSuppressed = suppressed
        if suppressed {
            volumeHUD.hide()
        }
    }

    func refreshMediaKeyAccessStatus() {
        guard useVolumeKeys else {
            invalidateMediaKeyEventTap()
            mediaKeyAccessState = .unknown
            mediaKeyAccessMessage = "Volume keys will control macOS system volume."
            return
        }

        let hasListenAccess = CGPreflightListenEventAccess()

        guard hasListenAccess else {
            invalidateMediaKeyEventTap()
            mediaKeyAccessState = hasRequestedMediaKeyAccess ? .permissionDenied : .permissionNeeded
            mediaKeyAccessMessage = hasRequestedMediaKeyAccess
                ? "KEFControl still does not have permission to listen for media keys. macOS tracks this per app build, so the Xcode-built app may need approval separately from swift run."
                : "Allow KEFControl to listen for media keys so volume up/down can control your speaker."
            return
        }

        if mediaKeyEventTap == nil {
            installMediaKeyEventTap()
        }

        if mediaKeyEventTap != nil {
            mediaKeyAccessState = .working
            mediaKeyAccessMessage = "Media-key control is active for this app build."
            return
        }

        mediaKeyAccessState = .failedToActivate
        if !AXIsProcessTrusted() {
            mediaKeyAccessMessage = "Listening permission appears granted, but the media-key event tap still failed to start. macOS accessibility trust may also be affecting this launch context."
        } else {
            mediaKeyAccessMessage = "Listening permission appears granted, but the media-key event tap still failed to activate. Try refreshing or relaunching the app."
        }
    }

    func requestMediaKeyAccess() {
        hasRequestedMediaKeyAccess = true
        _ = CGRequestListenEventAccess()
        refreshMediaKeyAccessStatus()
    }

    deinit {
        if let mediaKeyRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), mediaKeyRunLoopSource, .commonModes)
        }
        if let mediaKeyEventTap {
            CFMachPortInvalidate(mediaKeyEventTap)
        }
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
        displayedVolume = 0
        isPlaying = false
        nowPlaying = nil
        isBusy = false
        clearPendingVolume(keepDisplayedVolume: false)
        volumeHUD.hide()
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
            let refreshedVolume = try await vol
            self.volume = refreshedVolume
            syncDisplayedVolume(with: refreshedVolume)
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
        let clampedVolume = max(0, min(100, newVolume))
        volume = clampedVolume
        displayedVolume = clampedVolume
        pendingCommittedVolume = clampedVolume
        pendingVolumeResetTask?.cancel()
        pendingVolumeResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            if self.pendingCommittedVolume == clampedVolume {
                self.clearPendingVolume()
            }
        }

        guard let speaker else { return }
        if !isVolumeHUDSuppressed {
            volumeHUD.show(
                title: volumeHUDTitle,
                volume: clampedVolume
            )
        }
        Task {
            do {
                try await speaker.setVolume(clampedVolume)
                try? await Task.sleep(for: .milliseconds(400))
                await refresh()
            } catch {
                clearPendingVolume()
                await refresh()
                connectionError = error.localizedDescription
            }
        }
    }

    private func adjustVolume(by delta: Int) {
        commitVolume(displayedVolume + delta)
    }

    private var volumeHUDTitle: String {
        speakerModel.isEmpty ? speakerName : speakerModel
    }

    func setSource(_ newSource: SpeakerSource) {
        guard let speaker else { return }
        let oldSource = source
        clearPendingVolume()
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

    // MARK: - Wake-on-LAN

    private func syncDisplayedVolume(with remoteVolume: Int) {
        if let pendingCommittedVolume {
            if remoteVolume == pendingCommittedVolume {
                clearPendingVolume()
            } else {
                displayedVolume = pendingCommittedVolume
            }
        } else {
            displayedVolume = remoteVolume
        }
    }

    private func clearPendingVolume(keepDisplayedVolume: Bool = true) {
        pendingCommittedVolume = nil
        pendingVolumeResetTask?.cancel()
        pendingVolumeResetTask = nil
        if keepDisplayedVolume {
            displayedVolume = volume
        }
    }

    private func installMediaKeyEventTap() {
        guard mediaKeyEventTap == nil else { return }

        let eventMask = CGEventMask(1 << MediaKey.eventType)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let appState = Unmanaged<AppState>.fromOpaque(userInfo).takeUnretainedValue()
                return appState.handleMediaKeyEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        mediaKeyEventTap = eventTap
        mediaKeyRunLoopSource = runLoopSource
    }

    private func invalidateMediaKeyEventTap() {
        if let mediaKeyRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), mediaKeyRunLoopSource, .commonModes)
            self.mediaKeyRunLoopSource = nil
        }
        if let mediaKeyEventTap {
            CFMachPortInvalidate(mediaKeyEventTap)
            self.mediaKeyEventTap = nil
        }
    }

    private func handleMediaKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let mediaKeyEventTap {
                CGEvent.tapEnable(tap: mediaKeyEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard isConnected, status == .powerOn else {
            return Unmanaged.passUnretained(event)
        }
        guard let delta = mediaKeyDelta(for: event) else {
            return Unmanaged.passUnretained(event)
        }

        adjustVolume(by: delta)
        return nil
    }

    private func mediaKeyDelta(for event: CGEvent) -> Int? {
        guard let nsEvent = NSEvent(cgEvent: event) else { return nil }
        guard nsEvent.subtype.rawValue == MediaKey.eventSubtype else { return nil }

        let data = Int(nsEvent.data1)
        let keyCode = (data & 0xFFFF0000) >> 16
        let keyFlags = data & 0x0000FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == MediaKey.keyDownState
        let isRepeat = (keyFlags & MediaKey.repeatMask) != 0

        guard isKeyDown || isRepeat else { return nil }

        switch keyCode {
        case MediaKey.volumeUp:
            return MediaKey.volumeStep
        case MediaKey.volumeDown:
            return -MediaKey.volumeStep
        default:
            return nil
        }
    }

    /// The MAC address of the discovered (or connected) speaker, if known.
    var speakerMAC: String? {
        // Check discovered speakers for a MAC
        if let first = discovery.speakers.first, let mac = first.macAddress {
            return mac
        }
        return nil
    }

    func wakeSpeaker() {
        guard let mac = speakerMAC else { return }
        isBusy = true
        Task {
            _ = sendWakeOnLAN(macAddress: mac)
            // Wait for the speaker to boot, then try connecting
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(1))
                if let host = currentHost ?? discovery.speakers.first?.host {
                    let api = KEFSpeakerAPI(host: host)
                    if await api.testConnection() {
                        connect(to: host)
                        isBusy = false
                        return
                    }
                }
            }
            isBusy = false
            connectionError = "Speaker did not wake up"
        }
    }
}
