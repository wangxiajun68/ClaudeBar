import Foundation

/// Public, credential-free CLI contract. The host owns all agent scanning.
struct CLISnapshot: Codable {
    static let schemaVersion = 1
    static let fileName = "cli-status.json"
    static let pages = ["dashboard", "sessions", "providers", "connectors", "usage", "traffic", "vpn", "settings", "help"]

    var schemaVersion = Self.schemaVersion
    var channel: String
    var appVersion: String
    var pid: Int
    var updatedAt: Date
    var sessions: [Session]
    var usage: Usage
    var providers: [Provider]
    var quota: [Quota]
    var quotaLoading: Bool
    var vpn: VPN
    var proxy: Proxy
    var connectors: [Connector]
    var connectorsScanned: Bool
    var connectorsLoading: Bool
    var charge: Charge
    var greeting: String? = nil
    var weather: Weather? = nil
    var weatherLoading: Bool? = nil
    var weatherNote: String? = nil

    struct Session: Codable {
        var id: String
        var agent: String
        var pid: Int?
        var status: String
        var model: String
        var project: String
        var activity: String
        var contextTokens: Int?
        var contextLimit: Int?
        var contextPercent: Double?
        var isSubagent: Bool
        var parentID: String?
    }
    struct Usage: Codable {
        var period: String
        var tokens: Int
        var todayTokens: Int
        var todayCalls: Int
        var loading: Bool
        var models: [Model]
        struct Model: Codable { var model: String; var tokens: Int }
    }
    struct Provider: Codable { var agent: String; var name: String; var active: Bool; var model: String }
    struct Quota: Codable { var label: String; var usedPercent: Double; var resetsAt: Date? }
    struct VPN: Codable {
        var state: String
        var enabled: Bool
        var systemProxy: Bool
        var tun: Bool
        var node: String?
        var coreVersion: String?
        var mixedPort: Int
    }
    struct Proxy: Codable { var running: Bool; var port: Int }
    struct Connector: Codable { var name: String; var kind: String; var platforms: [String]; var enabled: Bool? }
    struct Charge: Codable { var mode: String; var limit: Int; var status: String; var supported: Bool? }

    struct Weather: Codable {
        var place: String
        var temperatureC: Double
        var feelsLikeC: Double
        var condition: String
        var highC: Double
        var lowC: Double
        var humidity: Int
        var windKph: Double
        var windDirection: String
        var sunrise: String
        var sunset: String
        var rainChance: Int
        var observedAt: Date
        var fetchedAt: Date?
        var timezone: String
        var source: String
        var forecast: [Day]
        struct Day: Codable { var date: Date; var highC: Double; var lowC: Double; var rainChance: Int? }
    }

    /// Reading does not create directories or inspect the Widget/TCC containers.
    static func fileURL(home: URL, appName: String) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true).appendingPathComponent(fileName)
    }
}
