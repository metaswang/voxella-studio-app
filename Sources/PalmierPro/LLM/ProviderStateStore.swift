import CryptoKit
import Foundation
import Observation

struct ProviderConnectionRecord: Codable, Equatable, Sendable {
    let providerID: UUID
    let identity: String
    let testedAt: Date
    let error: String?
    let isRateLimited: Bool

    static func identity(profile: LLMProviderProfile, key: String) -> String {
        let endpoint = profile.normalizedBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let digest = SHA256.hash(data: Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return endpoint + "|" + digest
    }
}

/// Provider diagnostics have their own database, so rebuilding the knowledge index
/// cannot erase a completed connection test. Credentials never enter this database.
actor ProviderStateStore {
    static let shared = ProviderStateStore()
    private let url: URL
    private var database: SessionSQLite?
    private var connectionTokens: [UUID: UUID] = [:]

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoxStudio/AIService.sqlite")
    }

    private func db() throws -> SessionSQLite {
        if let database { return database }
        let result = try SessionSQLite(url: url)
        try result.execute("CREATE TABLE IF NOT EXISTS provider_state (provider_id TEXT NOT NULL, category TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY (provider_id, category));")
        database = result
        return result
    }

    func load<T: Decodable & Sendable>(_ type: T.Type, providerID: UUID, category: String) throws -> T? {
        let rows = try db().query("SELECT payload FROM provider_state WHERE provider_id = ? AND category = ?", binds: [.text(providerID.uuidString), .text(category)])
        guard let data = rows.first?.blob("payload") else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    func save<T: Encodable & Sendable>(_ value: T, providerID: UUID, category: String) throws {
        let data = try JSONEncoder().encode(value)
        try db().run("INSERT INTO provider_state (provider_id, category, payload) VALUES (?, ?, ?) ON CONFLICT(provider_id, category) DO UPDATE SET payload = excluded.payload", binds: [.text(providerID.uuidString), .text(category), .blob(data)])
    }

    func remove(providerID: UUID) throws {
        try db().run("DELETE FROM provider_state WHERE provider_id = ?", binds: [.text(providerID.uuidString)])
    }

    func beginConnection(providerID: UUID, token: UUID, invalidate: Bool = false) throws {
        connectionTokens[providerID] = token
        if invalidate { try db().run("DELETE FROM provider_state WHERE provider_id = ? AND category = 'connection'", binds: [.text(providerID.uuidString)]) }
    }

    func saveConnection(_ record: ProviderConnectionRecord, token: UUID) throws {
        guard connectionTokens[record.providerID] == token else { return }
        try save(record, providerID: record.providerID, category: "connection")
    }
}

@Observable @MainActor
final class ProviderConnectivityStore {
    static let shared = ProviderConnectivityStore()
    private(set) var states: [UUID: ProviderConnectionState] = [:]
    private(set) var records: [UUID: ProviderConnectionRecord] = [:]
    private(set) var persistenceError: String?
    private var attempts: [UUID: UUID] = [:]
    private var invalidations: [UUID: Task<Void, Never>] = [:]
    private var refreshID = UUID()
    private let database: ProviderStateStore
    private let tester: LLMProviderConnectivityTester

    init(database: ProviderStateStore = .shared, tester: LLMProviderConnectivityTester = .init()) {
        self.database = database
        self.tester = tester
    }

    func refresh(settings: LLMSettingsStore) async {
        let token = UUID()
        refreshID = token
        for profile in settings.providers {
            do {
                await invalidations[profile.id]?.value
                let key = try await settings.loadAPIKey(for: profile.id) ?? ""
                let record = try await database.load(ProviderConnectionRecord.self, providerID: profile.id, category: "connection")
                guard token == refreshID else { return }
                let identity = ProviderConnectionRecord.identity(profile: profile, key: key)
                let currentKey = try await settings.loadAPIKey(for: profile.id) ?? ""
                guard let current = settings.provider(id: profile.id),
                      ProviderConnectionRecord.identity(profile: current, key: currentKey) == identity,
                      token == refreshID else { continue }
                if let record, record.identity == identity {
                    records[profile.id] = record
                    if attempts[profile.id] == nil { states[profile.id] = state(record) }
                } else {
                    records[profile.id] = nil
                    if attempts[profile.id] == nil { states[profile.id] = .untested }
                    if record != nil, attempts[profile.id] == nil { try await database.beginConnection(providerID: profile.id, token: UUID(), invalidate: true) }
                }
            } catch {
                persistenceError = error.localizedDescription
            }
        }
    }

    func invalidate(_ providerID: UUID) {
        attempts[providerID] = nil
        states[providerID] = .untested
        records[providerID] = nil
        let previous = invalidations[providerID]
        invalidations[providerID] = Task {
            await previous?.value
            do { try await database.beginConnection(providerID: providerID, token: UUID(), invalidate: true) }
            catch { persistenceError = error.localizedDescription }
        }
    }

    func test(profile: LLMProviderProfile, key: String, settings: LLMSettingsStore) async {
        let token = UUID()
        attempts[profile.id] = token
        states[profile.id] = .testing
        await invalidations[profile.id]?.value
        guard attempts[profile.id] == token else { return }
        do { try await database.beginConnection(providerID: profile.id, token: token) }
        catch { persistenceError = error.localizedDescription }
        let identity = ProviderConnectionRecord.identity(profile: profile, key: key)
        var failure: String?
        var limited = false
        do {
            try await tester.test(profile: profile, apiKey: key)
        } catch is CancellationError {
            guard attempts[profile.id] == token else { return }
            attempts[profile.id] = nil
            states[profile.id] = records[profile.id].map(state) ?? .untested
            return
        } catch {
            failure = error.localizedDescription.replacingOccurrences(of: key.isEmpty ? "\u{0}" : key, with: "[redacted]")
            limited = (error as? LLMProviderConnectionError) == .rateLimited
        }
        guard attempts[profile.id] == token, let current = settings.provider(id: profile.id) else { return }
        do {
            let currentKey = try await settings.loadAPIKey(for: profile.id) ?? ""
            guard attempts[profile.id] == token,
                  identity == ProviderConnectionRecord.identity(profile: current, key: currentKey) else {
                invalidate(profile.id)
                return
            }
            let record = ProviderConnectionRecord(providerID: profile.id, identity: identity, testedAt: Date(), error: failure, isRateLimited: limited)
            try await database.saveConnection(record, token: token)
            guard attempts[profile.id] == token else { return }
            records[profile.id] = record
            states[profile.id] = state(record)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
            states[profile.id] = .failed(error.localizedDescription, isRateLimited: false)
        }
        if attempts[profile.id] == token { attempts[profile.id] = nil }
    }

    private func state(_ record: ProviderConnectionRecord) -> ProviderConnectionState {
        record.error.map { .failed($0, isRateLimited: record.isRateLimited) } ?? .connected
    }
}
