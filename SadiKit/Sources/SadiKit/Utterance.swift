import Foundation

/// One spoken contribution after the echo filter, ready to display.
/// SPEC §9.
public struct Utterance: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public let source: Source
    public var speaker: Speaker
    public let text: String
    public let startedAt: Date
    public let endedAt: Date
    public let embedding: [Float]?
    public let asrConfidence: Float?

    public init(
        id: UUID = UUID(),
        source: Source,
        speaker: Speaker,
        text: String,
        startedAt: Date,
        endedAt: Date,
        embedding: [Float]? = nil,
        asrConfidence: Float? = nil
    ) {
        self.id = id
        self.source = source
        self.speaker = speaker
        self.text = text
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.embedding = embedding
        self.asrConfidence = asrConfidence
    }
}

public enum Source: String, Hashable, Sendable, Codable {
    case mic
    case system
}

/// Speaker identity for an `Utterance`. SPEC §8.1.
public enum Speaker: Hashable, Sendable, Codable {
    case you                       // mic, call mode
    case them                      // system, single far-end speaker
    case remote(Int)               // system, multi-speaker (1-indexed)
    case localSpeaker(Int)         // mic-only mode, multi-speaker (1-indexed)
    case named(String, UUID)       // persistent identity from voiceprint book
}
