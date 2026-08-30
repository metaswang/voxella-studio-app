import Foundation

protocol TextEmbeddingProvider: Sendable {
    func encodeText(_ text: String) async throws -> [Float]
}

struct SearchService: Sendable {
    var store: SessionIndexStore
    var embeddings: (any TextEmbeddingProvider)?

    func sessionSearch(query: String, filter: SessionSearchFilter = .init()) async throws -> [SessionCard] {
        let lexical = try await store.searchLexical(
            query: query,
            kinds: [.sessionCard, .transcriptChunk],
            filter: filter
        )
        let fusedIDs = ReciprocalRankFusion.fuse(rankings: [lexical.map(\.sessionID)])
        var vectorHits: [SessionSearchHit] = []
        if let embeddings, let vector = try? await embeddings.encodeText(query) {
            vectorHits = (try? await store.searchVector(vector: vector, modality: .text, filter: filter)) ?? []
        }
        let ranked = ReciprocalRankFusion.fuse(
            rankings: [lexical.map(\.sessionID), vectorHits.map(\.sessionID)]
        )
        let order = ranked.isEmpty ? fusedIDs : ranked
        var cards: [SessionCard] = []
        for id in order.prefix(filter.limit) {
            guard var card = try await store.sessionCard(id: id) else { continue }
            let hit = lexical.first { $0.sessionID == id } ?? vectorHits.first { $0.sessionID == id }
            card.matchSource = hit?.kind == .sessionCard ? "summary" : (hit?.matchSource ?? "transcript")
            card.snippet = hit?.snippet ?? card.summaryExcerpt
            cards.append(card)
        }
        return cards
    }

    func sessionGet(id: UUID) async throws -> SessionCard? {
        try await store.sessionCard(id: id)
    }

    func sessionSummary(id: UUID) async throws -> (title: String, tag: String?, markdown: String?)? {
        guard let card = try await store.sessionCard(id: id) else { return nil }
        return (card.title, card.tag, card.summaryMarkdown)
    }

    func speakerList(id: UUID) async throws -> [SessionSpeaker] {
        try await store.speakers(sessionID: id)
    }

    func transcriptSearch(
        query: String,
        filter: SessionSearchFilter = .init(),
        words: [TranscriptionWord] = []
    ) async throws -> [SessionSearchHit] {
        try await hybridSearch(
            query: query,
            kinds: [.transcriptChunk],
            modalities: [.text],
            filter: filter,
            words: words
        )
    }

    func transcriptContext(
        sessionID: UUID,
        start: Double,
        end: Double,
        pad: Double = 8,
        words: [TranscriptionWord] = []
    ) async throws -> [SessionSearchHit] {
        let padded = max(0, min(pad, 30))
        let hits = try await store.contextUnits(
            sessionID: sessionID,
            kind: .transcriptChunk,
            start: start - padded,
            end: end + padded
        )
        return hits.map { hydrate($0, words: words, terms: []) }
    }

    func subtitleSearch(
        query: String,
        filter: SessionSearchFilter = .init(),
        words: [TranscriptionWord] = []
    ) async throws -> [SessionSearchHit] {
        try await hybridSearch(
            query: query,
            kinds: [.subtitleCue],
            modalities: [.text],
            filter: filter,
            words: words
        )
    }

    func subtitleContext(
        sessionID: UUID,
        start: Double,
        end: Double,
        pad: Double = 2
    ) async throws -> [SessionSearchHit] {
        try await store.contextUnits(
            sessionID: sessionID,
            kind: .subtitleCue,
            start: start - pad,
            end: end + pad
        )
    }

    func subtitleList(sessionID: UUID) async throws -> [SessionSearchHit] {
        try await store.subtitleList(sessionID: sessionID)
    }

    func clipSearch(
        query: String,
        filter: SessionSearchFilter = .init(),
        words: [TranscriptionWord] = []
    ) async throws -> [SessionSearchHit] {
        var modalities: [SessionIndexModality] = [.mixed, .video]
        if let modality = filter.modality {
            modalities = [modality]
        }
        return try await hybridSearch(
            query: query,
            kinds: [.mediaClip],
            modalities: modalities,
            filter: filter,
            words: words
        )
    }

    func resolveClip(sessionID: UUID, start: Double, end: Double) async throws -> ClipCandidate? {
        try await store.resolveClip(sessionID: sessionID, start: start, end: end)
    }

    func search(
        query: String,
        filter: SessionSearchFilter = .init(),
        words: [TranscriptionWord] = []
    ) async throws -> [SessionSearchHit] {
        let sessions = try await sessionSearch(query: query, filter: filter)
        let transcripts = try await transcriptSearch(query: query, filter: filter, words: words)
        let clips = try await clipSearch(query: query, filter: filter, words: words)
        let fused = ReciprocalRankFusion.fuse(
            rankings: [transcripts.map(\.unitID), clips.map(\.unitID)]
        )
        let byID = Dictionary(uniqueKeysWithValues: (transcripts + clips).map { ($0.unitID, $0) })
        var hits = fused.compactMap { byID[$0] }
        if hits.isEmpty {
            hits = transcripts
        }
        if sessions.isEmpty { return Array(hits.prefix(filter.limit)) }
        return Array(hits.prefix(filter.limit))
    }

    private func hybridSearch(
        query: String,
        kinds: [SessionIndexUnitKind],
        modalities: [SessionIndexModality],
        filter: SessionSearchFilter,
        words: [TranscriptionWord]
    ) async throws -> [SessionSearchHit] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let lexical = try await store.searchLexical(query: query, kinds: kinds, filter: filter)
        var vectorHits: [SessionSearchHit] = []
        if let embeddings, let vector = try? await embeddings.encodeText(query) {
            for modality in modalities {
                let hits = (try? await store.searchVector(
                    vector: vector,
                    modality: modality,
                    filter: filter
                )) ?? []
                vectorHits.append(contentsOf: hits.filter { kinds.contains($0.kind) || $0.kind == .mediaClip })
            }
        }
        let fused = ReciprocalRankFusion.fuse(
            rankings: [lexical.map(\.unitID), vectorHits.map(\.unitID)]
        )
        var byID: [Int: SessionSearchHit] = [:]
        for hit in lexical + vectorHits {
            byID[hit.unitID] = hit
        }
        return fused.prefix(filter.limit).compactMap { id in
            byID[id].map { hydrate($0, words: words, terms: terms) }
        }
    }

    private func hydrate(
        _ hit: SessionSearchHit,
        words: [TranscriptionWord],
        terms: [String]
    ) -> SessionSearchHit {
        guard let start = hit.start, let end = hit.end, !words.isEmpty else { return hit }
        var copy = hit
        copy.quoteSpan = WordSpanMapper.quoteSpan(
            overlapping: start ... end,
            matching: terms,
            in: words
        )
        return copy
    }
}
