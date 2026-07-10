import Foundation
import Observation
import OSLog
import SadiKit

/// Serial queue for post-recording transcript work: the post-stop finalize
/// pass, user-requested full reruns, and voiceprint re-attribution sweeps.
///
/// One job runs at a time — finalize/rerun share the ANE with the live
/// pipeline, so model jobs are deferred while a recording is in progress
/// (`isCaptureBusy`) and re-drained when it stops. Re-attribution is pure
/// JSON I/O and runs regardless.
///
/// Scheduling is disk-driven, not memory-driven: a stop stamps
/// `needsFinalize: true` into `session.json`, and `drainPendingFromDisk()`
/// turns whatever the disk says is owed into queued jobs. A quit mid-finalize
/// therefore loses nothing — the next launch drains the same flag.
@Observable
@MainActor
final class TranscriptionJobs {
    enum Kind: Equatable {
        case finalize(URL)
        case rerun(URL)
        case reattribute

        var sessionID: String? {
            switch self {
            case .finalize(let dir), .rerun(let dir): dir.lastPathComponent
            case .reattribute: nil
            }
        }
    }

    struct ActiveJob: Equatable {
        let kind: Kind
        var phase: String
    }

    /// The job currently running, with its progress phase — drives the
    /// detail screen's "Finalizing…" banner and edit locking.
    private(set) var active: ActiveJob?
    /// Session id of the most recently completed session-scoped job. Views
    /// showing that session's transcript observe this to reload.
    private(set) var lastCompletedSessionID: String?
    private(set) var lastError: String?

    private let modelHost: ModelHost
    private let voiceprints: VoiceprintBook
    /// Injected by the app so model jobs can defer while recording.
    var isCaptureBusy: @MainActor () -> Bool = { false }

    private var queue: [Kind] = []
    /// The task executing `active` — kept so a user cancel can reach into the
    /// running pipeline (which checks cancellation between stages and per
    /// ASR segment).
    private var runTask: Task<Void, Never>?

    nonisolated private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "jobs")

    init(modelHost: ModelHost, voiceprints: VoiceprintBook) {
        self.modelHost = modelHost
        self.voiceprints = voiceprints
    }

    /// True when a model job for this session is queued or running — the
    /// detail screen locks editing and the Rerun button while it is.
    func isBusy(sessionID: String) -> Bool {
        if active?.kind.sessionID == sessionID { return true }
        return queue.contains { $0.sessionID == sessionID }
    }

    var isRunningModelJob: Bool {
        if case .reattribute = active?.kind { return false }
        return active != nil
    }

    // MARK: - Enqueue

    func enqueueRerun(directory: URL) {
        enqueue(.rerun(directory))
    }

    /// Cheap embeddings-only sweep: re-match every saved non-manual utterance
    /// against the current voiceprint book. Called after an enrollment so the
    /// new name spreads to past recordings without touching audio or models.
    func enqueueReattribution() {
        enqueue(.reattribute)
    }

    /// Scan the recordings root for finalized sessions still owing their
    /// finalize pass and queue them, oldest first. Call sites: models ready
    /// at launch, and each recording stop.
    func drainPendingFromDisk() async {
        let pending = await Task.detached(priority: .utility) {
            Self.sessionsNeedingFinalize()
        }.value
        for dir in pending { enqueue(.finalize(dir)) }
    }

    private func enqueue(_ kind: Kind) {
        guard active?.kind != kind, !queue.contains(kind) else { return }
        queue.append(kind)
        pump()
    }

    /// Cancel this session's model job: unqueue it if it hasn't started, or
    /// cancel the running pipeline if it has (the pass aborts within about a
    /// second and writes nothing — the existing transcript is untouched).
    /// A cancelled *finalize* is still owed on disk (`needsFinalize` stays
    /// set), so it will reappear on the next drain; a cancelled rerun is
    /// simply gone until requested again.
    func cancel(sessionID: String) {
        queue.removeAll { $0.sessionID == sessionID }
        if active?.kind.sessionID == sessionID {
            runTask?.cancel()
        }
    }

    // MARK: - Pump

    private func pump() {
        guard active == nil, !queue.isEmpty else { return }
        // Model jobs wait for the models and an idle capture; re-attribution
        // needs neither. Pick the first runnable job (re-attribution can
        // overtake a deferred finalize while recording).
        let modelJobsRunnable = modelHost.state == .ready && !isCaptureBusy()
        guard let index = queue.firstIndex(where: { kind in
            if case .reattribute = kind { return true }
            return modelJobsRunnable
        }) else { return }

        let kind = queue.remove(at: index)
        active = ActiveJob(kind: kind, phase: "Starting…")
        runTask = Task {
            await self.run(kind)
            self.active = nil
            self.runTask = nil
            if let id = kind.sessionID { self.lastCompletedSessionID = id }
            self.pump()
        }
    }

    private func run(_ kind: Kind) async {
        switch kind {
        case .finalize(let dir), .rerun(let dir):
            let mode: OfflinePipeline.Mode = {
                if case .rerun = kind { return .rerun }
                return .finalize
            }()
            do {
                let outcome = try await OfflinePipeline.run(
                    mode: mode,
                    sessionDirectory: dir,
                    modelHost: modelHost,
                    voiceprints: voiceprints,
                    llmConfig: LLMSettings.currentIfConfigured(),
                    progress: { [weak self] phase in self?.active?.phase = phase }
                )
                lastError = nil
                Self.log.notice(
                    "\(mode.rawValue, privacy: .public) \(dir.lastPathComponent, privacy: .public): \(outcome.utteranceCount) utterances"
                )
            } catch is CancellationError {
                Self.log.notice(
                    "\(mode.rawValue, privacy: .public) \(dir.lastPathComponent, privacy: .public) cancelled by user"
                )
            } catch {
                lastError = String(describing: error)
                Self.log.error(
                    "\(mode.rawValue, privacy: .public) \(dir.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
                // A failed finalize leaves needsFinalize set; it will be
                // retried on the next drain (launch or stop).
            }
        case .reattribute:
            active?.phase = "Updating speaker names…"
            let changed = await Self.reattribute(
                prints: voiceprints.prints, threshold: voiceprints.matchThreshold)
            if changed > 0 {
                Self.log.notice("Re-attribution updated \(changed) utterances")
                // Any open detail view should reload; reuse the completion
                // signal with a sentinel covering "anything may have changed".
                lastCompletedSessionID = "*"
            }
        }
    }

    // MARK: - Disk scans (off main)

    nonisolated private static func sessionsNeedingFinalize() -> [URL] {
        guard let root = try? SessionPaths.recordingsRoot() else { return [] }
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = Session.dateDecodingStrategy
        var pending: [URL] = []
        for dir in dirs {
            let url = dir.appending(path: "session.json", directoryHint: .notDirectory)
            guard let data = try? Data(contentsOf: url),
                  let session = try? decoder.decode(Session.self, from: data),
                  session.needsFinalize == true,
                  session.endedAt != nil
            else { continue }
            pending.append(dir)
        }
        return pending.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Re-attribution

    /// Re-match saved transcripts against the book — `@concurrent` so the
    /// directory scan stays off the main actor. Only non-manual utterances
    /// with embeddings move; nothing is ever un-named (no match → label
    /// kept). Each document rewrite goes through the file coordinator so it
    /// cannot race a manual pin. Returns the number of utterances updated.
    @concurrent
    nonisolated private static func reattribute(prints: [Voiceprint], threshold: Float) async -> Int {
        guard !prints.isEmpty, let root = try? SessionPaths.recordingsRoot() else { return 0 }
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return 0 }

        var totalChanged = 0
        for dir in dirs {
            do {
                if let (_, changed) = try await TranscriptDocumentFileCoordinator.shared.update(
                    directory: dir,
                    { doc -> (TranscriptDocument, Int)? in
                        let result = reattributed(
                            doc.utterances, prints: prints, threshold: threshold)
                        guard result.changed > 0 else { return nil }
                        return (doc.replacingUtterances(result.utterances), result.changed)
                    })
                {
                    totalChanged += changed
                }
            } catch {
                // Preserve the previous file on write failure; the next
                // re-attribution pass can retry from the same source document.
            }
        }
        return totalChanged
    }

    /// Pure re-matching pass over one document's utterances. System rows
    /// first, so the mic pass can apply the cross-track sanity guard against
    /// final system labels. Returns the rewritten rows and how many changed.
    nonisolated private static func reattributed(
        _ original: [Utterance], prints: [Voiceprint], threshold: Float
    ) -> (utterances: [Utterance], changed: Int) {
        var utterances = original
        var changed = 0

        func bestMatch(for embedding: [Float]) -> Voiceprint? {
            var best: (vp: Voiceprint, d: Float)?
            for vp in prints
            where vp.modelVersion == ModelHost.embeddingModelVersion
                && vp.embedding.count == embedding.count {
                let d = VoiceprintBook.cosineDistance(embedding, vp.embedding)
                if d < (best?.d ?? .infinity) { best = (vp, d) }
            }
            guard let best, best.d < threshold else { return nil }
            return best.vp
        }

        for pass in 0...1 {
            let source: Source = pass == 0 ? .system : .mic
            let systemUtterances =
                pass == 0 ? [] : utterances.filter { $0.source == .system }
            for i in utterances.indices where utterances[i].source == source {
                let u = utterances[i]
                guard u.assignmentKind != .manual, let embedding = u.embedding,
                      let match = bestMatch(for: embedding)
                else { continue }
                // A mic row matching a far-end identity without system
                // overlap is a mis-match, not bleed; leave it alone rather
                // than renaming the local user (SpeakerSanity).
                if source == .mic,
                   SpeakerSanity.isImplausibleMicMatch(
                       u, voiceprintID: match.id, systemUtterances: systemUtterances) {
                    continue
                }
                let newSpeaker = Speaker.named(match.name, match.id)
                if u.speaker != newSpeaker || u.assignmentKind != .matched {
                    utterances[i].speaker = newSpeaker
                    utterances[i].assignmentKind = .matched
                    changed += 1
                }
            }
        }
        return (utterances, changed)
    }
}
