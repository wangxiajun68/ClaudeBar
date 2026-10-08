import Foundation

/// One bounded, off-main write in flight; newer ticks replace pending values.
/// The CLI gets a heartbeat even when unchanged sessions would dedupe a widget.
enum CLISnapshotPublisher {
    private static let queue = DispatchQueue(label: "claudebar.cli-snapshot", qos: .utility)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: (CLISnapshot, URL)?
    nonisolated(unsafe) private static var writing = false

    static func submit(_ snapshot: CLISnapshot, to file: URL) {
        lock.lock()
        pending = (snapshot, file)
        guard !writing else { lock.unlock(); return }
        writing = true
        lock.unlock()
        queue.async {
            while true {
                lock.lock()
                let next = pending
                pending = nil
                if next == nil { writing = false }
                lock.unlock()
                guard let (value, destination) = next else { return }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = .sortedKeys
                do {
                    try PrivateFileWriter.write(encoder.encode(value), to: destination)
                } catch {
                    // Never log session payloads or credentials on a disk failure.
                    NSLog("ClaudeBar CLI snapshot write failed (%@)", String(describing: type(of: error)))
                }
            }
        }
    }
}

extension ProviderStore {
    @MainActor func publishCLISnapshot() {
        let prefs = AppPreferences.shared
        let vpn = VpnManager.shared
        let connectors = ConnectorManager.shared
        let charge = BatteryChargeController.shared
        let claudeRows = aliveSessions.map { s in
            CLISnapshot.Session(id: s.sessionId, agent: "claude", pid: s.pid,
                status: s.isWaiting ? "waiting" : (s.isBusy ? "busy" : "idle"), model: s.model,
                project: s.projectFolder, activity: s.isWaiting ? "Awaiting confirmation" : s.currentActivity,
                contextTokens: s.contextTokens, contextLimit: s.contextLimit,
                contextPercent: s.contextLimit > 0 ? s.contextRatio * 100 : nil,
                isSubagent: false, parentID: nil)
        }
        let cursorRows = aliveCursorSessions.map { s in
            CLISnapshot.Session(id: s.composerId, agent: "cursor", pid: nil,
                status: s.isWaiting ? "waiting" : (s.isBusy ? "busy" : "idle"), model: "",
                project: s.projectFolder, activity: s.isWaiting ? "Awaiting confirmation" : s.currentActivity,
                contextTokens: nil, contextLimit: nil,
                contextPercent: s.contextPercent >= 0 ? s.contextPercent : nil,
                isSubagent: false, parentID: nil)
        }
        let externalRows = externalSessions.filter(\.isAlive).map { s in
            CLISnapshot.Session(id: s.sessionId, agent: "codex", pid: nil,
                status: s.isWaiting ? "waiting" : (s.isActive ? "busy" : "idle"), model: s.model,
                project: s.projectFolder, activity: s.currentActivity,
                contextTokens: s.contextTokens, contextLimit: s.contextLimit,
                contextPercent: s.contextLimit > 0 ? s.contextRatio * 100 : nil,
                isSubagent: s.isSubagent, parentID: s.parentThreadId)
        }
        let providerRows = providers.map { p in
            CLISnapshot.Provider(agent: "claude", name: p.name, active: p.id == activeProviderID,
                model: p.id == activeProviderID ? (currentEnv?.ANTHROPIC_MODEL ?? "") : "")
        } + (peer?.providers.map { p in
            CLISnapshot.Provider(agent: "codex", name: p.name, active: p.id == peer?.activeProviderID,
                model: p.id == peer?.activeProviderID ? (peer?.configuredModel ?? "") : "")
        } ?? [])
        let vpnState: String
        switch vpn.state {
        case .idle: vpnState = "idle"
        case .missingCore: vpnState = "missingCore"
        case .starting: vpnState = "starting"
        case .running: vpnState = "running"
        case .failed: vpnState = "failed" // Error bodies may carry remote addresses or core log lines.
        }
        let weather = WeatherStore.shared
        let snapshot = CLISnapshot(channel: BuildChannel.name,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            pid: Int(ProcessInfo.processInfo.processIdentifier), updatedAt: Date(),
            sessions: claudeRows + cursorRows + externalRows,
            usage: .init(period: UsageStats.compactLabel(for: usagePeriod, reference: usageReferenceDate),
                tokens: totalUsageTokens, todayTokens: todayUsage.tokens, todayCalls: todayUsage.calls,
                loading: usageLoading, models: usageStats.map { .init(model: $0.model, tokens: $0.totalTokens) }),
            providers: providerRows,
            quota: peer?.quotaWindows.map { .init(label: $0.label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) } ?? [],
            quotaLoading: peer?.quotaLoading ?? false,
            vpn: .init(state: vpnState, enabled: prefs.vpnEnabled,
                systemProxy: prefs.vpnSystemProxyEnabled, tun: prefs.vpnTunEnabled,
                node: vpn.liveLeafName, coreVersion: vpn.coreVersion, mixedPort: prefs.vpnMixedPort),
            proxy: .init(running: peer?.proxyRunning ?? false, port: BuildChannel.proxyPort),
            connectors: connectors.records.map { .init(name: $0.name, kind: $0.kind.rawValue,
                platforms: $0.platforms.map(\.rawValue), enabled: $0.enabled) },
            connectorsScanned: connectors.hasScanned, connectorsLoading: connectors.isLoading,
            charge: .init(mode: charge.mode.label, limit: Int(charge.threshold),
                status: charge.statusText, supported: charge.supported),
            runMode: AppPresentation.performanceMode ? "performance" : "desktop",
            greeting: GreetingPhrase.resolve(prefs.greetingSelection, custom: prefs.greetingCustomText,
                date: Date(), language: prefs.greetingLanguage).script,
            weather: weather.reading.map { r in
                .init(place: r.place, temperatureC: r.temperatureC, feelsLikeC: r.feelsLikeC,
                    condition: r.conditionText, highC: r.highC, lowC: r.lowC, humidity: r.humidity,
                    windKph: r.windKph, windDirection: r.windDirection, sunrise: r.sunrise, sunset: r.sunset,
                    rainChance: r.rainChance, observedAt: r.observedAt, fetchedAt: weather.fetchedAt,
                    timezone: r.timezone, source: r.source, forecast: r.forecast.map {
                        .init(date: $0.date, highC: $0.high, lowC: $0.low, rainChance: $0.rainChance)
                    })
            }, weatherLoading: weather.loading, weatherNote: weather.note)
        CLISnapshotPublisher.submit(snapshot, to: FilePaths.appSupportDir.appendingPathComponent(CLISnapshot.fileName))
    }
}
