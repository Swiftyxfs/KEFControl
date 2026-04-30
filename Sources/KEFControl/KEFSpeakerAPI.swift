import Foundation

struct NowPlayingInfo {
    var title: String?
    var artist: String?
    var album: String?
    var coverURL: String?
    var serviceID: String?

    var hasInfo: Bool {
        title != nil || artist != nil
    }
}

enum SpeakerSource: String, CaseIterable, Identifiable {
    case wifi, bluetooth, tv, optical, coaxial, analog, usb

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wifi: "WiFi"
        case .bluetooth: "Bluetooth"
        case .tv: "TV"
        case .optical: "Optical"
        case .coaxial: "Coaxial"
        case .analog: "Analog"
        case .usb: "USB"
        }
    }

    static var inputSources: [SpeakerSource] {
        [.wifi, .bluetooth, .tv, .optical, .coaxial, .analog, .usb]
    }
}

enum SpeakerStatus: String {
    case powerOn
    case standby
}

enum KEFError: LocalizedError {
    case invalidResponse
    case connectionFailed
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid response from speaker"
        case .connectionFailed: "Could not connect to speaker"
        case .apiError(let message): message
        }
    }
}

final class KEFSpeakerAPI: Sendable {
    private static let postSetDataModels: Set<String> = ["LS50WII", "LSXII", "LSXIILT"]
    private static let modelAliases: [String: String] = [
        "LS50W2": "LS50WII",
        "LSX2": "LSXII",
        "LSX2LT": "LSXIILT",
    ]

    let host: String
    private let session: URLSession

    init(host: String) {
        self.host = host
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        self.session = URLSession(configuration: config)
    }

    // MARK: - Low-level API

    private func getData(path: String, roles: String = "value") async throws -> [[String: Any]] {
        guard var components = URLComponents(string: "http://\(host)/api/getData") else {
            throw KEFError.connectionFailed
        }
        components.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "roles", value: roles),
        ]
        guard let url = components.url else { throw KEFError.connectionFailed }
        let (data, _) = try await session.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw KEFError.invalidResponse
        }
        return json
    }

    private func setData(path: String, roles: String = "value", value: [String: Any]) async throws {
        if try await usesPostForSetData() {
            try await postSetData(path: path, roles: roles, value: value)
        } else {
            try await getSetData(path: path, roles: roles, value: value)
        }
    }

    private func getSetData(path: String, roles: String, value: [String: Any]) async throws {
        guard var components = URLComponents(string: "http://\(host)/api/setData") else {
            throw KEFError.connectionFailed
        }
        let valueData = try JSONSerialization.data(withJSONObject: value)
        guard let valueString = String(data: valueData, encoding: .utf8) else {
            throw KEFError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "roles", value: roles),
            URLQueryItem(name: "value", value: valueString),
        ]
        guard let url = components.url else { throw KEFError.connectionFailed }
        let (data, _) = try await session.data(from: url)
        try validateSetDataResponse(data)
    }

    private func postSetData(path: String, roles: String, value: [String: Any]) async throws {
        guard let url = URL(string: "http://\(host)/api/setData") else {
            throw KEFError.connectionFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "path": path,
            "roles": roles,
            "value": value,
        ])

        let (data, _) = try await session.data(for: request)
        try validateSetDataResponse(data)
    }

    private func validateSetDataResponse(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let response = try JSONSerialization.jsonObject(with: data)
        if let responseObject = response as? [String: Any],
           let error = responseObject["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Speaker rejected command"
            throw KEFError.apiError(message)
        }
    }

    private func usesPostForSetData() async throws -> Bool {
        let model = try await getModelAndFirmware().model
        let normalizedModel = Self.modelAliases[model] ?? model
        return Self.postSetDataModels.contains(normalizedModel)
    }

    // MARK: - Read

    func getStatus() async throws -> SpeakerStatus {
        let data = try await getData(path: "settings:/kef/host/speakerStatus")
        let raw = data[0]["kefSpeakerStatus"] as? String ?? "standby"
        return SpeakerStatus(rawValue: raw) ?? .standby
    }

    func getSource() async throws -> SpeakerSource {
        let data = try await getData(path: "settings:/kef/play/physicalSource")
        let raw = data[0]["kefPhysicalSource"] as? String ?? "standby"
        return SpeakerSource(rawValue: raw) ?? .wifi
    }

    func getVolume() async throws -> Int {
        let data = try await getData(path: "player:volume")
        return data[0]["i32_"] as? Int ?? 0
    }

    func getSpeakerName() async throws -> String {
        let data = try await getData(path: "settings:/deviceName")
        return data[0]["string_"] as? String ?? "KEF Speaker"
    }

    /// Returns (model, firmwareVersion) from a single API call.
    func getModelAndFirmware() async throws -> (model: String, firmware: String) {
        let data = try await getData(path: "settings:/releasetext")
        let raw = data[0]["string_"] as? String ?? ""
        let parts = raw.components(separatedBy: "_")
        let model = parts.first ?? raw
        let firmware = parts.count > 1 ? parts[1] : raw
        return (model, firmware)
    }

    func getPlayerData() async throws -> [String: Any] {
        let data = try await getData(path: "player:player/data")
        return data[0]
    }

    func getIsPlaying() async throws -> Bool {
        let data = try await getPlayerData()
        return (data["state"] as? String) == "playing"
    }

    func getNowPlayingInfo() async throws -> NowPlayingInfo {
        let data = try await getPlayerData()
        let trackRoles = data["trackRoles"] as? [String: Any] ?? [:]
        let mediaData = trackRoles["mediaData"] as? [String: Any] ?? [:]
        let metadata = mediaData["metaData"] as? [String: Any] ?? [:]

        return NowPlayingInfo(
            title: trackRoles["title"] as? String,
            artist: metadata["artist"] as? String,
            album: metadata["album"] as? String,
            coverURL: trackRoles["icon"] as? String,
            serviceID: metadata["serviceID"] as? String
        )
    }

    // MARK: - Write

    func setVolume(_ volume: Int) async throws {
        let clamped = max(0, min(100, volume))
        try await setData(
            path: "player:volume",
            value: ["type": "i32_", "i32_": clamped]
        )
    }

    func setSource(_ source: SpeakerSource) async throws {
        try await setData(
            path: "settings:/kef/play/physicalSource",
            value: ["type": "kefPhysicalSource", "kefPhysicalSource": source.rawValue]
        )
    }

    func powerOn() async throws {
        try await setData(
            path: "settings:/kef/play/physicalSource",
            value: ["type": "kefPhysicalSource", "kefPhysicalSource": "powerOn"]
        )
    }

    func shutdown() async throws {
        try await setData(
            path: "settings:/kef/play/physicalSource",
            value: ["type": "kefPhysicalSource", "kefPhysicalSource": "standby"]
        )
    }

    func togglePlayPause() async throws {
        try await setData(
            path: "player:player/control",
            roles: "activate",
            value: ["control": "pause"]
        )
    }

    func nextTrack() async throws {
        try await setData(
            path: "player:player/control",
            roles: "activate",
            value: ["control": "next"]
        )
    }

    func previousTrack() async throws {
        try await setData(
            path: "player:player/control",
            roles: "activate",
            value: ["control": "previous"]
        )
    }

    func testConnection() async -> Bool {
        do {
            _ = try await getStatus()
            return true
        } catch {
            return false
        }
    }
}
