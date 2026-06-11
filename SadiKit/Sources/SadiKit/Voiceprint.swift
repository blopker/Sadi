import Foundation
import Observation

/// One named speaker the user has enrolled. Per SPEC §8.2 the centroid
/// embedding is maintained via running average over the sample count, and
/// `modelVersion` is used to invalidate prints whose embedding came from a
/// different model release than the one currently loaded.
public struct Voiceprint: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var embedding: [Float]
    public var sampleCount: Int
    public var modelVersion: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        embedding: [Float],
        sampleCount: Int = 1,
        modelVersion: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.sampleCount = sampleCount
        self.modelVersion = modelVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Persistent voiceprint book. Lives on disk as JSON at the URL the host
/// passes in; reads on init, atomic writes (.tmp + rename) on every mutation.
///
/// The matcher uses cosine distance (since embeddings are L2-normalized from
/// FluidAudio that reduces to `1 - dot(a, b)`). `matchThreshold` defaults to
/// the conservative 0.55 SPEC §8.2 calls for; tighter than the echo filter's
/// 0.65 to bias against false-name matches.
@Observable
@MainActor
public final class VoiceprintBook {
    public private(set) var prints: [Voiceprint]
    public var matchThreshold: Float = 0.55

    private let storeURL: URL
    private let modelVersion: String

    /// Result of a lookup: the best-matching print and the cosine distance.
    public struct Match: Sendable {
        public let voiceprint: Voiceprint
        public let distance: Float
    }

    public init(storeURL: URL, modelVersion: String) {
        self.storeURL = storeURL
        self.modelVersion = modelVersion
        self.prints = VoiceprintBook.load(from: storeURL)
    }

    // MARK: - Matching

    /// Return the best match for an embedding if its cosine distance is below
    /// `matchThreshold`. Voiceprints stamped with a different `modelVersion`
    /// are skipped (SPEC §8.2: cross-version comparisons aren't meaningful).
    public func match(embedding: [Float]) -> Match? {
        guard !embedding.isEmpty else { return nil }
        var best: Match?
        for vp in prints where vp.modelVersion == modelVersion && vp.embedding.count == embedding.count {
            let d = VoiceprintBook.cosineDistance(embedding, vp.embedding)
            if d < (best?.distance ?? .infinity) {
                best = Match(voiceprint: vp, distance: d)
            }
        }
        guard let candidate = best, candidate.distance < matchThreshold else { return nil }
        return candidate
    }

    // MARK: - Enrollment / update

    /// Create a new voiceprint from an embedding. If `name` already exists
    /// (case-insensitive), updates that voiceprint via running average and
    /// returns its id.
    @discardableResult
    public func enroll(name: String, embedding: [Float]) throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!trimmed.isEmpty, "Voiceprint name cannot be empty")

        if let idx = prints.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            update(at: idx, embedding: embedding)
            try persist()
            return prints[idx].id
        }
        let vp = Voiceprint(
            name: trimmed,
            embedding: embedding,
            sampleCount: 1,
            modelVersion: modelVersion
        )
        prints.append(vp)
        try persist()
        return vp.id
    }

    /// Running-average update of an existing voiceprint.
    public func update(id: UUID, embedding: [Float]) throws {
        guard let idx = prints.firstIndex(where: { $0.id == id }) else { return }
        update(at: idx, embedding: embedding)
        try persist()
    }

    public func rename(id: UUID, to newName: String) throws {
        guard let idx = prints.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!trimmed.isEmpty)
        prints[idx].name = trimmed
        prints[idx].updatedAt = Date()
        try persist()
    }

    public func delete(id: UUID) throws {
        prints.removeAll { $0.id == id }
        try persist()
    }

    private func update(at idx: Int, embedding: [Float]) {
        let n = prints[idx].sampleCount
        let old = prints[idx].embedding
        precondition(old.count == embedding.count, "Embedding dimension mismatch")
        var merged = [Float](repeating: 0, count: old.count)
        let weight = Float(n)
        for i in 0..<old.count {
            merged[i] = (old[i] * weight + embedding[i]) / Float(n + 1)
        }
        prints[idx].embedding = merged
        prints[idx].sampleCount = n + 1
        prints[idx].updatedAt = Date()
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> [Voiceprint] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let prints = try? JSONDecoder().decode([Voiceprint].self, from: data) else { return [] }
        return prints
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(prints)
        // `.atomic` is a temp-file write + rename(2) under the hood: a partial
        // write can never replace a good file, and — unlike a manual
        // remove + move — there is no instant where the book is missing from
        // disk for a crash to land in.
        try data.write(to: storeURL, options: [.atomic])
    }

    // MARK: - Distance

    /// Cosine distance over two equal-length [Float] vectors.
    /// `0` = identical direction, `1` = orthogonal, `2` = opposite.
    /// Pure math — `nonisolated` so off-main passes (re-attribution sweeps)
    /// can score embeddings without hopping to the main actor.
    public nonisolated static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        guard denom > 0 else { return 1 }
        return 1 - (dot / denom)
    }
}
