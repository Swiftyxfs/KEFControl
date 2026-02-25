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
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 300)
        .onAppear {
            ipField = appState.manualIP
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
