import Darwin
import Foundation
import Network

struct DiscoveredSpeaker: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let host: String
    let macAddress: String?
}

@MainActor
final class KEFDiscovery: ObservableObject {
    @Published var speakers: [DiscoveredSpeaker] = []
    @Published var isSearching = false

    private var httpBrowser: NWBrowser?
    private var raopBrowser: NWBrowser?
    // MAC addresses discovered from RAOP service names, keyed by speaker name
    private var discoveredMACs: [String: String] = [:]

    func startDiscovery() {
        speakers = []
        discoveredMACs = [:]
        isSearching = true

        let params = NWParameters()
        params.includePeerToPeer = true

        // Browse _raop._tcp to get MAC addresses. RAOP service names are formatted
        // as "AABBCCDDEEFF@Speaker Name" where the prefix is the MAC address.
        raopBrowser = NWBrowser(for: .bonjour(type: "_raop._tcp", domain: nil), using: params)
        raopBrowser?.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint {
                    let upper = name.uppercased()
                    if upper.contains("LSX") || upper.contains("LS50") || upper.contains("LS60") || upper.contains("KEF") {
                        // Extract MAC from "AABBCCDDEEFF@Speaker Name"
                        if let atIdx = name.firstIndex(of: "@") {
                            let rawMAC = String(name[name.startIndex..<atIdx])
                            if rawMAC.count == 12, rawMAC.allSatisfy(\.isHexDigit) {
                                // Format as AA:BB:CC:DD:EE:FF
                                let mac = stride(from: 0, to: 12, by: 2).map { i in
                                    let start = rawMAC.index(rawMAC.startIndex, offsetBy: i)
                                    let end = rawMAC.index(start, offsetBy: 2)
                                    return String(rawMAC[start..<end])
                                }.joined(separator: ":")
                                let speakerName = String(name[name.index(after: atIdx)...])
                                Task { @MainActor in
                                    self?.discoveredMACs[speakerName] = mac
                                }
                            }
                        }
                    }
                }
            }
        }
        raopBrowser?.start(queue: .global())

        // Browse _http._tcp to find the speaker's HTTP API endpoint.
        // KEF speakers don't advertise a KEF-specific service type, but they do
        // register as _http._tcp (their control API runs on port 80). We filter
        // results by name to find KEF models.
        httpBrowser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: params)
        httpBrowser?.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                if case .service(let name, let type, let domain, _) = result.endpoint {
                    let upper = name.uppercased()
                    if upper.contains("LSX") || upper.contains("LS50") || upper.contains("LS60") || upper.contains("KEF") {
                        self?.resolveService(name: name, type: type, domain: domain)
                    }
                }
            }
        }
        httpBrowser?.start(queue: .global())

        // Auto-stop after 10 seconds
        Task {
            try? await Task.sleep(for: .seconds(10))
            stopDiscovery()
        }
    }

    func stopDiscovery() {
        httpBrowser?.cancel()
        httpBrowser = nil
        raopBrowser?.cancel()
        raopBrowser = nil
        isSearching = false
    }

    /// Resolve a Bonjour service to an IPv4 address using dns_sd APIs.
    ///
    /// NWConnection's IP resolution can return IPv6-only on some networks,
    /// so we use DNSServiceResolve to get the actual .local hostname, then
    /// getaddrinfo to look up the IPv4 address.
    nonisolated private func resolveService(name: String, type: String, domain: String) {
        DispatchQueue.global().async { [weak self] in
            guard let hostname = Self.resolveServiceHostname(name: name, type: type, domain: domain) else {
                return
            }
            guard let ipv4 = Self.resolveToIPv4(hostname) else {
                return
            }

            Task { @MainActor in
                guard let self else { return }
                let mac = self.discoveredMACs[name]
                if !self.speakers.contains(where: { $0.host == ipv4 }) {
                    self.speakers.append(
                        DiscoveredSpeaker(id: name, name: name, host: ipv4, macAddress: mac)
                    )
                }
            }
        }
    }

    /// Use DNSServiceResolve to get the .local hostname for a Bonjour service.
    nonisolated private static func resolveServiceHostname(name: String, type: String, domain: String) -> String? {
        class Box { var value: String? }
        let box = Box()
        var sdRef: DNSServiceRef?

        let callback: DNSServiceResolveReply = {
            _, _, _, errorCode, _, hosttarget, _, _, _, context in
            guard errorCode == kDNSServiceErr_NoError,
                  let hosttarget,
                  let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            box.value = String(cString: hosttarget)
        }

        let err = DNSServiceResolve(
            &sdRef, 0, 0,
            name, type, domain,
            callback,
            Unmanaged.passUnretained(box).toOpaque()
        )
        guard err == kDNSServiceErr_NoError, let sdRef else { return nil }
        defer { DNSServiceRefDeallocate(sdRef) }

        // Wait for the resolve callback (up to 5 seconds)
        let fd = DNSServiceRefSockFD(sdRef)
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&pfd, 1, 5000) > 0 {
            DNSServiceProcessResult(sdRef)
        }

        return box.value
    }

    /// Use getaddrinfo to resolve a hostname to an IPv4 address.
    nonisolated private static func resolveToIPv4(_ hostname: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &result) == 0, let addr = result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(
            addr.pointee.ai_addr, socklen_t(addr.pointee.ai_addrlen),
            &buf, socklen_t(buf.count),
            nil, 0, NI_NUMERICHOST
        ) == 0 else { return nil }

        return String(cString: buf)
    }
}

// MARK: - Wake-on-LAN

/// Send a Wake-on-LAN magic packet to wake a sleeping network device.
func sendWakeOnLAN(macAddress: String) -> Bool {
    // Parse MAC address (accepts "AA:BB:CC:DD:EE:FF" or "AA-BB-CC-DD-EE-FF")
    let hex = macAddress
        .replacingOccurrences(of: ":", with: "")
        .replacingOccurrences(of: "-", with: "")
    guard hex.count == 12 else { return false }

    var macBytes = [UInt8]()
    var index = hex.startIndex
    for _ in 0..<6 {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else { return false }
        macBytes.append(byte)
        index = next
    }

    // Magic packet: 6x 0xFF + 16x MAC address
    var packet = [UInt8](repeating: 0xFF, count: 6)
    for _ in 0..<16 {
        packet.append(contentsOf: macBytes)
    }

    // Send as UDP broadcast on port 9
    let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard sock >= 0 else { return false }
    defer { close(sock) }

    var broadcast: Int32 = 1
    setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(9).bigEndian
    addr.sin_addr.s_addr = INADDR_BROADCAST

    let sent = packet.withUnsafeBytes { buf in
        withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(sock, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    return sent == packet.count
}

