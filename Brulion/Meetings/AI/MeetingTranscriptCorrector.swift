import Foundation
import os

/// "Poprawiaj transkrypt przez AI": the meeting's lines go to the AI in batches
/// (`MeetingCorrectionPrompt`, the instructions `MeetingPrompts.correctionSystem`), and the lines
/// it fixed come back as changed segments, each only when `TranscriptFixGuard` finds the fix
/// safe (in trials the 1.5B damaged 62 of 306 clean lines without it, none with it). A batch
/// that fails keeps its lines; only when every batch fails does the call throw.
actor MeetingTranscriptCorrector {
    /// Batches in flight at once: a local model server answers one request at a time.
    static let parallelBatches = 1

    private let chat: MeetingChat

    init(session: URLSession = HTTP.meetingLLMSession, routes: any AIRouteProviding) {
        chat = MeetingChat(session: session, routes: routes)
    }

    /// The fixed lines of one batch's answer that `MeetingCorrectionPrompt` accepts and
    /// `TranscriptFixGuard` finds safe for the glossary.
    static func safeChanges(in batch: [MeetingSegmentRecord], reply: String, glossary: [String]) -> [MeetingSegmentRecord] {
        let original = Dictionary(batch.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        return MeetingCorrectionPrompt.changes(in: batch, reply: reply).filter { changed in
            guard let before = original[changed.id] else { return false }
            return TranscriptFixGuard.isSafe(original: before, fixed: changed.text, glossary: glossary)
        }
    }

    /// The fixed segments (only those that changed) and the model that fixed them. Runs on the
    /// small correction model (`MeetingAITask.transcriptCorrection`).
    func correct(meeting: MeetingRecord, segments: [MeetingSegmentRecord], glossary: [String]) async throws -> (changes: [MeetingSegmentRecord], model: String) {
        let route = try await chat.route(for: .transcriptCorrection)
        var model = route.model
        let system = MeetingAIInstructions.system(for: .transcriptCorrection)
        let batches = MeetingCorrectionPrompt.batches(segments)
        guard !batches.isEmpty else { return ([], model) }
        let started = ContinuousClock.now
        let chat = self.chat
        let title = meeting.title

        var changes: [MeetingSegmentRecord] = []
        var failures: [any Error] = []
        var servedModel: String?
        await withTaskGroup(of: Result<([MeetingSegmentRecord], String), any Error>.self) { group in
            var next = 0
            func addNext() {
                guard next < batches.count else { return }
                let batch = batches[next]
                next += 1
                group.addTask {
                    do {
                        let reply = try await chat.complete(
                            task: .transcriptCorrection,
                            system: system,
                            user: MeetingCorrectionPrompt.user(title: title, glossary: glossary, batch: batch),
                            maxTokens: MeetingCorrectionPrompt.maxTokens(for: batch)
                        )
                        return .success((Self.safeChanges(in: batch, reply: reply.text, glossary: glossary), reply.model))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for _ in 0..<Self.parallelBatches {
                addNext()
            }
            for await result in group {
                switch result {
                case .success(let (fixed, served)):
                    changes += fixed
                    servedModel = servedModel ?? served
                case .failure(let error):
                    failures.append(error)
                }
                addNext()
            }
        }

        if failures.count == batches.count, let first = failures.first {
            throw first
        }
        if !failures.isEmpty {
            Log.enhancement.error("Meeting transcript fix: \(failures.count, privacy: .public) of \(batches.count, privacy: .public) batches failed")
        }
        model = servedModel ?? model
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        Log.enhancement.info("Meeting transcript fix: \(changes.count, privacy: .public) line(s) in \(ms, privacy: .public) ms with \(model, privacy: .public)")
        return (changes, model)
    }
}

/// After a meeting (with "Poprawiaj transkrypt przez AI" on), and for "Popraw transkrypt przez
/// AI" in the details: stores the fixed lines (each keeps its earlier text for "Przywróć") and
/// names the model on the meeting. Runs after the cloud transcript and the speaker labels,
/// before the AI notes, so the notes read the fixed text.
struct MeetingCorrectionProcessor: MeetingPostProcessing {
    let database: Database
    let corrector: MeetingTranscriptCorrector
    let isEnabled: @Sendable () async -> Bool
    /// Dictionary terms; the speaker names typed on the meeting and the calendar's participants
    /// are added to them.
    let vocabulary: @Sendable () async -> [String]

    /// Prefix of the meeting's `transcriptError` when the AI fix failed.
    static var errorPrefix: String { String(localized: "Poprawki AI: ") }

    /// Dictionary terms, then the speaker names typed on the meeting, then the participants from
    /// the calendar event, each once: the names the AI should spell right.
    static func glossary(vocabulary: [String], meeting: MeetingRecord) -> [String] {
        var seen = Set<String>()
        return (vocabulary + meeting.speakerNames.values.sorted() + meeting.participants)
            .filter { seen.insert($0).inserted }
    }

    func process(meetingID: UUID) async {
        guard await isEnabled() else { return }
        await run(meetingID: meetingID)
    }

    @discardableResult
    func run(meetingID: UUID) async -> Bool {
        let meeting: MeetingRecord
        let segments: [MeetingSegmentRecord]
        do {
            guard let found = try await database.meeting(id: meetingID) else { return false }
            meeting = found
            segments = try await database.segments(meetingID: meetingID)
        } catch {
            Log.data.error("Meeting transcript fix could not read the meeting: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let glossary = Self.glossary(vocabulary: await vocabulary(), meeting: meeting)
        let prefix = Self.errorPrefix
        do {
            let (changes, model) = try await corrector.correct(meeting: meeting, segments: segments, glossary: glossary)
            try await database.updateSegments(changes)
            try await database.modifyMeeting(id: meetingID) { record in
                record.transcriptAIModel = model
                if record.transcriptError?.hasPrefix(prefix) == true {
                    record.transcriptError = nil
                }
            }
            return true
        } catch {
            Log.enhancement.error("Meeting transcript fix failed: \(error.localizedDescription, privacy: .public)")
            let message = prefix + error.localizedDescription
            try? await database.modifyMeeting(id: meetingID) { $0.transcriptError = message }
            return false
        }
    }
}
