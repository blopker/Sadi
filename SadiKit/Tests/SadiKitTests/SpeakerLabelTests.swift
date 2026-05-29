import Testing
@testable import SadiKit

@Suite("Speaker.remoteLabel")
struct SpeakerLabelTests {
    @Test("single far-end cluster is .them")
    func singleCluster() {
        #expect(Speaker.remoteLabel(forCluster: 0, among: [0]) == .them)
        // Cluster id is arbitrary; one distinct speaker is still .them.
        #expect(Speaker.remoteLabel(forCluster: 7, among: [7]) == .them)
    }

    @Test("no clusters seen yet is .them")
    func emptyClusters() {
        #expect(Speaker.remoteLabel(forCluster: nil, among: []) == .them)
        #expect(Speaker.remoteLabel(forCluster: 3, among: []) == .them)
    }

    @Test("two clusters number by ascending cluster id")
    func twoClusters() {
        let clusters: Set<Int> = [0, 1]
        #expect(Speaker.remoteLabel(forCluster: 0, among: clusters) == .remote(1))
        #expect(Speaker.remoteLabel(forCluster: 1, among: clusters) == .remote(2))
    }

    @Test("rank follows sorted cluster id, not insertion or magnitude")
    func sparseClusterIds() {
        // Diarizer cluster ids need not be contiguous; rank is by sort order.
        let clusters: Set<Int> = [5, 2, 9]
        #expect(Speaker.remoteLabel(forCluster: 2, among: clusters) == .remote(1))
        #expect(Speaker.remoteLabel(forCluster: 5, among: clusters) == .remote(2))
        #expect(Speaker.remoteLabel(forCluster: 9, among: clusters) == .remote(3))
    }

    @Test("nil cluster amid multiple speakers falls back to .them")
    func nilClusterMultiSpeaker() {
        // A segment the diarizer couldn't pin keeps the conservative .them.
        #expect(Speaker.remoteLabel(forCluster: nil, among: [0, 1]) == .them)
    }

    @Test("a cluster not in the set falls back to .them")
    func unknownCluster() {
        // Defensive: a cluster id absent from the seen set has no rank.
        #expect(Speaker.remoteLabel(forCluster: 4, among: [0, 1]) == .them)
    }

    @Test("retroactive relabel: them → remote(N) when a second cluster appears")
    func retroactiveFlip() {
        // First only cluster 0 has spoken: .them.
        #expect(Speaker.remoteLabel(forCluster: 0, among: [0]) == .them)
        // Cluster 1 then speaks; re-deriving over the grown set promotes the
        // earlier cluster-0 utterances to .remote(1).
        let grown: Set<Int> = [0, 1]
        #expect(Speaker.remoteLabel(forCluster: 0, among: grown) == .remote(1))
        #expect(Speaker.remoteLabel(forCluster: 1, among: grown) == .remote(2))
    }
}
