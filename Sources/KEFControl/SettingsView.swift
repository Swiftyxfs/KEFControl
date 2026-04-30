import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var ipField: String = ""
    @State private var testResult: TestResult?

    enum TestResult {
        case testing
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            Section("Connection") {
                Toggle("Auto-discover speakers (mDNS)", isOn: $appState.useAutoDiscovery)
                    .onChange(of: appState.useAutoDiscovery) { _, _ in
                        appState.startConnection()
                    }

                HStack {
                    Text("Speaker IP")
                    TextField("192.168.1.42", text: $ipField)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { applyIP() }
                    Button("Connect") { applyIP() }
                        .disabled(ipField.isEmpty)
                }

                if let result = testResult {
                    switch result {
                    case .testing:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Testing connection...")
                                .foregroundStyle(.secondary)
                        }
                    case .success(let name):
                        Label("Connected to \(name)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }

                if appState.isConnected, let host = appState.currentHost {
                    HStack {
                        Label("Currently connected to \(host)", systemImage: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Disconnect") {
                            appState.disconnect()
                            appState.manualIP = ""
                            ipField = ""
                            testResult = nil
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Discovered Speakers") {
                if appState.discovery.isSearching {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Scanning...")
                            .foregroundStyle(.secondary)
                    }
                }

                if appState.discovery.speakers.isEmpty && !appState.discovery.isSearching {
                    Text("No speakers found on the network")
                        .foregroundStyle(.secondary)
                }

                ForEach(appState.discovery.speakers) { speaker in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(speaker.name)
                                .font(.body)
                            Text(speaker.host)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Use") {
                            ipField = speaker.host
                            applyIP()
                        }
                        .controlSize(.small)
                    }
                }

                Button("Rescan") {
                    appState.discovery.startDiscovery()
                }
                .controlSize(.small)
            }

            Section("Volume Keys") {
                Toggle("Control speaker volume with keyboard volume keys", isOn: $appState.useVolumeKeys)

                HStack {
                    Label(mediaKeyStatusTitle, systemImage: mediaKeyStatusIcon)
                        .foregroundStyle(mediaKeyStatusColor)
                    Spacer()
                    Button("Refresh Status") {
                        appState.refreshMediaKeyAccessStatus()
                    }
                    .controlSize(.small)
                    .disabled(!appState.useVolumeKeys)
                }

                Text(appState.mediaKeyAccessMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.useVolumeKeys && appState.mediaKeyAccessState != .working {
                    Button(mediaKeyActionTitle) {
                        appState.requestMediaKeyAccess()
                    }
                    .controlSize(.small)
                }

                Text("macOS tracks media-key listening permission per app identity, so the Xcode-built app may need approval separately from swift run.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 300)
        .onAppear {
            ipField = appState.manualIP
            appState.refreshMediaKeyAccessStatus()
        }
    }

    private var mediaKeyStatusTitle: String {
        if !appState.useVolumeKeys {
            return "Off"
        }

        return switch appState.mediaKeyAccessState {
        case .unknown:
            "Checking"
        case .working:
            "Working"
        case .permissionNeeded:
            "Permission Needed"
        case .permissionDenied:
            "Permission Denied"
        case .failedToActivate:
            "Failed to Activate"
        }
    }

    private var mediaKeyStatusIcon: String {
        if !appState.useVolumeKeys {
            return "speaker.slash"
        }

        return switch appState.mediaKeyAccessState {
        case .unknown:
            "questionmark.circle"
        case .working:
            "checkmark.circle.fill"
        case .permissionNeeded:
            "hand.raised.circle"
        case .permissionDenied:
            "exclamationmark.triangle.fill"
        case .failedToActivate:
            "xmark.circle.fill"
        }
    }

    private var mediaKeyStatusColor: Color {
        if !appState.useVolumeKeys {
            return .secondary
        }

        return switch appState.mediaKeyAccessState {
        case .unknown:
            .secondary
        case .working:
            .green
        case .permissionNeeded, .permissionDenied:
            .orange
        case .failedToActivate:
            .red
        }
    }

    private var mediaKeyActionTitle: String {
        switch appState.mediaKeyAccessState {
        case .permissionNeeded:
            "Enable Media Key Access"
        case .permissionDenied:
            "Retry Permission Request"
        case .failedToActivate:
            "Retry Media Key Setup"
        case .unknown, .working:
            "Request Media Key Access"
        }
    }

    private func applyIP() {
        let ip = ipField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else { return }

        testResult = .testing
        let api = KEFSpeakerAPI(host: ip)

        Task {
            let ok = await api.testConnection()
            if ok {
                let name = (try? await api.getSpeakerName()) ?? ip
                testResult = .success(name)
                appState.manualIP = ip
                appState.connect(to: ip)
            } else {
                testResult = .failure("Cannot reach speaker at \(ip)")
            }
        }
    }
}
