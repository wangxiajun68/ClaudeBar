import Foundation
import Combine

@MainActor
final class FreeModelGatewayStore: ObservableObject {
    static let shared = FreeModelGatewayStore()
    @Published private(set) var pool = FreeModelPool()
    @Published private(set) var loading = true
    @Published private(set) var saving = false
    @Published private(set) var discovering = false
    @Published private(set) var snapshot = FreeModelGateway.Snapshot()
    @Published private(set) var connections: [CodexProvider] = []
    @Published var error: String?
    private let storage = FreeModelPoolStorage(url: FilePaths.freeModelPoolFile)
    private weak var providers: CodexProviderStore?
    private weak var claude: ProviderStore?
    private var providerObserver: AnyCancellable?
    private var claudeObserver: AnyCancellable?
    private var schedule: Task<Void, Never>?
    private var discovery: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private var stopped = false
    private var loadedSuccessfully = false

    func start(providers: CodexProviderStore, claude: ProviderStore) {
        guard startup == nil else { return }
        self.providers = providers
        self.claude = claude
        stopped = false
        providerObserver = providers.$providers.dropFirst().sink { [weak self] _ in
            // Published emits before assignment; resolve providers next turn.
            Task { @MainActor [weak self] in await self?.syncRuntime() }
        }
        claudeObserver = claude.$providers.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in await self?.syncRuntime() }
        }
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await storage.load()
                guard !Task.isCancelled, !stopped else { return }
                pool = loaded; loadedSuccessfully = true
            } catch {
                self.error = "读取网关配置失败，原文件已保留；请检查配置文件后重启。"
            }
            loading = false
            await syncRuntime()
            reschedule()
        }
    }

    func stop() {
        stopped = true
        startup?.cancel(); discovery?.cancel(); schedule?.cancel()
        providerObserver?.cancel()
        claudeObserver?.cancel()
        providerObserver = nil
        schedule = nil; discovery = nil
    }

    func change(_ edit: (inout FreeModelPool) -> Void) {
        guard !loading, !saving, loadedSuccessfully, !stopped else { return }
        var next = pool
        edit(&next)
        guard let message = next.validationError else {
            saving = true
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await storage.save(next)
                    guard !stopped else { saving = false; return }
                    pool = next; error = nil
                    await syncRuntime()
                    reschedule()
                } catch { self.error = "保存网关配置失败，修改未生效。" }
                saving = false
            }
            return
        }
        error = message
    }

    private func syncRuntime() async {
        guard !stopped else { return }
        var available = providers?.providers ?? []
        for provider in claude?.providers ?? [] where !available.contains(where: { $0.id == provider.id }) {
            var converted = ProviderBridge.toCodex(provider)
            converted.id = provider.id
            available.append(converted)
        }
        if connections != available { connections = available }
        let endpoints = available.compactMap { provider -> FreeModelGateway.Endpoint? in
            // Remote credentials only travel over TLS. Do not create a route
            // back into the local proxy, or use an Anthropic-only connection.
            guard let url = URLComponents(string: provider.baseURL), url.scheme == "https",
                  url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  !LocalProxyAddress.isLoopback(provider.baseURL) else { return nil }
            return .init(id: provider.id, name: provider.name, baseURL: provider.baseURL, apiKey: provider.apiKey)
        }
        await FreeModelGateway.shared.configure(pool, endpoints: endpoints)
    }

    /// One owned timer sleeps until discovery is due; no polling while disabled.
    private func reschedule() {
        schedule?.cancel(); schedule = nil
        guard loadedSuccessfully, pool.discoveryEnabled, !stopped else { return }
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !stopped else { return }
                let due = (pool.discoveredAt ?? .distantPast).addingTimeInterval(Double(pool.refreshHours) * 3600)
                let delay = max(1, due.timeIntervalSinceNow)
                if delay > 1 {
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                discover()
                // Failure backoff avoids an expired schedule retrying in a loop.
                do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
            }
        }
    }

    func discover() {
        guard discovery == nil, !loading, loadedSuccessfully, !stopped else { return }
        discovering = true
        let selected = connections.first { $0.id == pool.openRouterProviderID }
        let key = selected.flatMap { FreeModelPool.isOpenRouter($0.baseURL) ? $0.apiKey : nil } ?? ""
        discovery = Task { [weak self] in
            guard let self else { return }
            defer { discovering = false; discovery = nil }
            do {
                let catalog = try await GatewayNetwork.shared.catalog(apiKey: key)
                guard !Task.isCancelled, !stopped else { return }
                // User edits can be in flight. Wait for their durable write,
                // then merge into the latest configuration, never a stale copy.
                while saving { try await Task.sleep(for: .milliseconds(50)) }
                guard !Task.isCancelled else { return }
                var next = pool
                next.catalog = catalog; next.discoveredAt = Date()
                for index in next.members.indices where next.members[index].discovered {
                    if let current = catalog.first(where: { $0.id == next.members[index].model }) {
                        let enabled = next.members[index].enabled
                        let difficulties = next.members[index].difficulties
                        next.members[index] = current.member(providerID: next.members[index].providerID)
                        next.members[index].enabled = enabled
                        next.members[index].difficulties = difficulties
                    }
                }
                if next.automaticallyJoin, let id = next.openRouterProviderID,
                   connections.contains(where: { $0.id == id && FreeModelPool.isOpenRouter($0.baseURL) }) {
                    for model in catalog where next.members.count < 200 {
                        let member = model.member(providerID: id)
                        if !next.members.contains(where: { $0.id == member.id }) { next.members.append(member) }
                    }
                }
                saving = true
                defer { saving = false }
                try await storage.save(next)
                guard !stopped else { return }
                pool = next; error = nil
                await syncRuntime()
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, !stopped else { return }
                self.error = (error as? GatewayFailure)?.localizedDescription ?? "模型发现失败，请检查网络；上次目录已保留。"
            }
        }
    }

    func add(_ model: FreeModelPool.CatalogModel) {
        guard let id = pool.openRouterProviderID else { error = "请先选择 OpenRouter 凭据。"; return }
        change { value in
            let member = model.member(providerID: id)
            if !value.members.contains(where: { $0.id == member.id }) { value.members.append(member) }
        }
    }

    func refreshStatus() async {
        let value = await FreeModelGateway.shared.snapshot()
        if value != snapshot { snapshot = value }
    }
    func resetHealth() {
        Task { await FreeModelGateway.shared.resetHealth(); await refreshStatus() }
    }
}
