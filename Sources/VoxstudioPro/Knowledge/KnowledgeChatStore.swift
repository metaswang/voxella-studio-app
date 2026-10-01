import Foundation

/// Local conversation/message persistence for Knowledge QA.
/// File-backed JSON keeps P0 simple; SQLite can replace later without UI changes.
actor KnowledgeChatStore {
    static let shared = KnowledgeChatStore()

    private let rootURL: URL
    private var conversations: [KnowledgeConversation] = []
    private var messagesByConversation: [UUID: [KnowledgeMessage]] = [:]
    private var loaded = false

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.rootURL = base
                .appendingPathComponent("VoxStudio", isDirectory: true)
                .appendingPathComponent("KnowledgeChat", isDirectory: true)
        }
    }

    func ensureLoaded() throws {
        guard !loaded else { return }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        conversations = try loadJSON([KnowledgeConversation].self, named: "conversations.json") ?? []
        let messageFiles = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in messageFiles where url.lastPathComponent.hasPrefix("messages.") && url.pathExtension == "json" {
            let name = url.deletingPathExtension().lastPathComponent
            let idString = String(name.dropFirst("messages.".count))
            guard let id = UUID(uuidString: idString),
                  let messages = try loadJSON([KnowledgeMessage].self, from: url)
            else { continue }
            messagesByConversation[id] = messages.sorted { $0.createdAt < $1.createdAt }
        }
        loaded = true
    }

    func conversation(for scope: KnowledgeQAScope) throws -> KnowledgeConversation {
        try ensureLoaded()
        if let existing = conversations.first(where: { $0.scope == scope }) {
            return existing
        }
        let title: String
        switch scope {
        case .all:
            title = "All knowledge"
        case .session:
            title = "Session chat"
        case let .sessions(ids):
            title = "\(ids.count) sessions chat"
        }
        let created = KnowledgeConversation(scope: scope, title: title)
        conversations.insert(created, at: 0)
        try persistConversations()
        return created
    }

    func messages(for conversationID: UUID) throws -> [KnowledgeMessage] {
        try ensureLoaded()
        return messagesByConversation[conversationID] ?? []
    }

    func append(_ message: KnowledgeMessage) throws {
        try ensureLoaded()
        var list = messagesByConversation[message.conversationID] ?? []
        list.append(message)
        messagesByConversation[message.conversationID] = list
        if let index = conversations.firstIndex(where: { $0.id == message.conversationID }) {
            conversations[index].updatedAt = message.createdAt
            let moved = conversations.remove(at: index)
            conversations.insert(moved, at: 0)
        }
        try persistMessages(conversationID: message.conversationID)
        try persistConversations()
    }

    func updateMessage(id: UUID, conversationID: UUID, content: String, citations: [KnowledgeSourceRef], isStreaming: Bool) throws {
        try ensureLoaded()
        guard var list = messagesByConversation[conversationID],
              let index = list.firstIndex(where: { $0.id == id })
        else { return }
        list[index].content = content
        list[index].citations = citations
        list[index].isStreaming = isStreaming
        messagesByConversation[conversationID] = list
        if let cIndex = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[cIndex].updatedAt = .now
        }
        try persistMessages(conversationID: conversationID)
        try persistConversations()
    }

    func clear(conversationID: UUID) throws {
        try ensureLoaded()
        messagesByConversation[conversationID] = []
        try persistMessages(conversationID: conversationID)
    }

    func removeMessage(id: UUID, conversationID: UUID) throws {
        try ensureLoaded()
        guard var list = messagesByConversation[conversationID] else { return }
        list.removeAll { $0.id == id }
        messagesByConversation[conversationID] = list
        try persistMessages(conversationID: conversationID)
    }

    private func persistConversations() throws {
        try writeJSON(conversations, named: "conversations.json")
    }

    private func persistMessages(conversationID: UUID) throws {
        let messages = messagesByConversation[conversationID] ?? []
        try writeJSON(messages, named: "messages.\(conversationID.uuidString).json")
    }

    private func loadJSON<T: Decodable>(_ type: T.Type, named: String) throws -> T? {
        let url = rootURL.appendingPathComponent(named)
        return try loadJSON(type, from: url)
    }

    private func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.knowledge.decode(type, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, named: String) throws {
        let url = rootURL.appendingPathComponent(named)
        let data = try JSONEncoder.knowledge.encode(value)
        try data.write(to: url, options: .atomic)
    }
}

private extension JSONEncoder {
    static let knowledge: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let knowledge: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
