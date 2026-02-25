import Foundation
import Network

struct DiscoveredSpeaker: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let host: String
}

@MainActor
final class KEFDiscovery: ObservableObject {
    @Published var speakers: [DiscoveredSpeaker] = []
    @Published var isSearching = false

    private var browser: NWBrowser?

    func startDiscovery() {
        speakers = []
        isSearching = true

        let params = NWParameters()
        params.includePeerToPeer = true

        // KEF speakers don't advertise a KEF-specific service type, but they do
        // register as _http._tcp (their control API runs on port 80). We filter
        // results by name to find KEF models.
        browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: params)

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint {
                    let upper = name.uppercased()
                    if upper.contains("LSX") || upper.contains("LS50") || upper.contains("LS60") || upper.contains("KEF") {
                        self?.resolveEndpoint(result.endpoint, name: name)
                    }
                }
            }
        }

        browser?.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in
                    self?.isSearching = false
                }
            }
        }

        browser?.start(queue: .global())

        // Auto-stop after 10 seconds
        Task {
            try? await Task.sleep(for: .seconds(10))
            stopDiscovery()
        }
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    nonisolated private func resolveEndpoint(_ endpoint: NWEndpoint, name: String) {
        // Force IPv4 to get a clean IP address for HTTP URLs
        let tcp = NWProtocolTCP.Options()
        let params = NWParameters(tls: nil, tcp: tcp)
        if let ipOpts = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOpts.version = .v4
        }

        let connection = NWConnection(to: endpoint, using: params)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let path = connection.currentPath,
                   let remote = path.remoteEndpoint,
                   case .hostPort(let host, _) = remote
                {
                    // Strip interface scope (e.g. "10.0.2.168%en13" → "10.0.2.168")
                    let hostStr = "\(host)".components(separatedBy: "%").first ?? "\(host)"
                    // Only use IPv4 addresses (no colons)
                    guard !hostStr.contains(":") else {
                        connection.cancel()
                        return
                    }
                    Task { @MainActor in
                        guard let self else { return }
                        if !self.speakers.contains(where: { $0.host == hostStr }) {
                            self.speakers.append(
                                DiscoveredSpeaker(id: name, name: name, host: hostStr)
                            )
                        }
                    }
                }
                connection.cancel()
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: .global())
    }
}
