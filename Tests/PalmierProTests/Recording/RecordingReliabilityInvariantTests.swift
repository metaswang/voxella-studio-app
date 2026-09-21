import CoreMedia
import Foundation
import Testing
@testable import PalmierPro

@Suite("Recording timeout gate")
struct RecordingTimeoutTests {
    @Test func timeoutReturnsWithoutWaitingForHungOperation() async {
        let started = ContinuousClock.now
        await #expect(throws: RecordingError.captureFailed("Recording timed out.")) {
            try await RecordingTimeout.withTimeout(seconds: 0.05) {
                try await Task.sleep(for: .milliseconds(400))
                return "late"
            }
        }
        let elapsed = started.duration(to: ContinuousClock.now)
        #expect(elapsed < .milliseconds(200))
    }

    @Test func gateResumesOnlyOnce() async throws {
        let gate = RecordingOnceGate<Int>()
        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            gate.arm(continuation)
            #expect(gate.resume(returning: 1))
            #expect(!gate.resume(returning: 2))
            #expect(!gate.resume(throwing: RecordingError.cancelled))
        }
        #expect(value == 1)
        #expect(gate.isResumed)
    }
}

@Suite("Recording journal recovery")
struct RecordingJournalRecoveryTests {
    @Test func failedAndInProgressCandidatesAreRecoveredAndGrouped() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionA = UUID().uuidString
        let sessionB = UUID().uuidString
        let inProgress = directory.appendingPathComponent("a.m4a")
        let failed = directory.appendingPathComponent("a-seg1.m4a")
        let other = directory.appendingPathComponent("b.m4a")
        let garbageManifest = directory.appendingPathComponent("broken.recording.json")
        try Data("not-audio".utf8).write(to: inProgress)
        try Data("not-audio".utf8).write(to: failed)
        try Data("not-audio".utf8).write(to: other)
        try Data("{not json".utf8).write(to: garbageManifest)

        #expect(RecordingSessionManifest.write(RecordingSessionManifest(
            sessionID: sessionA,
            startedAt: Date().addingTimeInterval(-10),
            outputPath: inProgress.path,
            mode: "audioOnly",
            backend: "microphone",
            deviceID: nil,
            status: RecordingSessionManifest.inProgress,
            segments: [
                RecordingJournalSegment(
                    index: 0,
                    path: inProgress.path,
                    globalStart: 0,
                    localDuration: 10,
                    status: RecordingSessionManifest.inProgress,
                    didAppendMedia: true,
                    didAppendVideo: false,
                    didAppendMicrophone: true,
                    didAppendSystemAudio: false
                )
            ]
        )))
        #expect(RecordingSessionManifest.write(RecordingSessionManifest(
            sessionID: sessionA,
            startedAt: Date(),
            outputPath: failed.path,
            mode: "audioOnly",
            backend: "microphone",
            deviceID: nil,
            status: RecordingSessionManifest.failed,
            segments: [
                RecordingJournalSegment(
                    index: 1,
                    path: failed.path,
                    globalStart: 10,
                    localDuration: 5,
                    status: RecordingSessionManifest.failed,
                    didAppendMedia: true,
                    didAppendVideo: false,
                    didAppendMicrophone: true,
                    didAppendSystemAudio: false
                )
            ]
        )))
        #expect(RecordingSessionManifest.write(RecordingSessionManifest(
            sessionID: sessionB,
            startedAt: Date().addingTimeInterval(-1),
            outputPath: other.path,
            mode: "audioOnly",
            backend: "microphone",
            deviceID: nil,
            status: RecordingSessionManifest.pendingImport
        )))

        let recovered = RecordingSessionManifest.recoverInterruptedSessions(in: directory)
        #expect(recovered.count == 2)
        let first = recovered.first { $0.sessionID == sessionA }
        #expect(first?.urls.count == 2)
        #expect(recovered.contains { $0.sessionID == sessionB })

        RecordingSessionManifest.markRegistered(sessionID: sessionB, in: directory)
        let afterCancel = RecordingSessionManifest.recoverInterruptedSessions(in: directory)
        #expect(afterCancel.count == 1)
        #expect(!afterCancel.contains { $0.sessionID == sessionB })

        RecordingSessionManifest.markRegistered(sessionID: sessionA, in: directory)
        #expect(RecordingSessionManifest.recoverInterruptedSessions(in: directory).isEmpty)
    }
}

@Suite("Recording health state machine")
struct RecordingHealthStateMachineTests {
    @Test func restartSuccessWithoutSamplesFailsBeforeUnboundedRetries() {
        var machine = RecordingHealthMachine()
        let started: TimeInterval = 0
        #expect(machine.evaluate(at: 6, startedAt: started, enabled: true) == .restartCapture("receipt stall"))
        for tick in 0..<20 {
            machine.noteRestartAttempt(at: 6 + TimeInterval(tick))
        }
        #expect(machine.evaluate(at: 21, startedAt: started, enabled: true) == .fail("no samples before deadline"))
        #expect(machine.phase == .failed)
        #expect(machine.restartCount >= 8)
    }

    @Test func aSingleSampleDoesNotResetTheFailureDeadline() {
        var machine = RecordingHealthMachine()
        let started: TimeInterval = 0
        _ = machine.evaluate(at: 6, startedAt: started, enabled: true)
        machine.noteReceived(at: 6.2)
        #expect(machine.phase == .awaitingSamples)
        #expect(machine.failureDeadline != nil)
        let decision = machine.evaluate(at: 21, startedAt: started, enabled: true)
        #expect(decision == .fail("no samples before deadline"))
    }

    @Test func writerBackpressureDoesNotRestartCapture() {
        var machine = RecordingHealthMachine()
        for i in 0..<RecordingCaptureHealth.recoveredSampleCount {
            machine.noteReceived(at: TimeInterval(i) * 0.02)
            machine.noteCommitted(at: TimeInterval(i) * 0.02)
        }
        #expect(machine.phase == .healthy)
        let now: TimeInterval = 18
        machine.noteReceived(at: now)
        machine.noteWriterNotReady(at: now - RecordingCaptureHealth.writerBackpressureTimeout)
        let decision = machine.evaluate(at: now, startedAt: 0, enabled: true)
        #expect(decision == .rolloverWriter("writer backpressure"))
    }
}

@Suite("Recording commit cursor")
struct RecordingCommitCursorTests {
    @Test func partialSilenceCommitDoesNotRewindPTS() {
        var cursor = RecordingAudioCursor()
        let first = CMTime(seconds: 1, preferredTimescale: 48_000)
        let planned = cursor.plan(samplePTS: first, gapThreshold: 0.05)
        #expect(planned.silenceFrom == nil)
        cursor.commit(start: first, frames: 24_000, sampleRate: 48_000)

        let late = CMTime(seconds: 2.5, preferredTimescale: 48_000)
        let gap = cursor.plan(samplePTS: late, gapThreshold: 0.05)
        #expect(gap.silenceFrom != nil)
        cursor.commit(start: gap.silenceFrom!, frames: 24_000, sampleRate: 48_000)
        #expect(abs((cursor.nextPTS?.seconds ?? 0) - 2.0) < 0.001)

        let next = cursor.plan(samplePTS: late, gapThreshold: 0.05)
        #expect(next.silenceFrom != nil)
        #expect(abs((next.silenceFrom?.seconds ?? 0) - 2.0) < 0.001)
        #expect(next.commitPTS.seconds > 2.0)
    }

    @Test func muteWithoutCommitDoesNotAdvanceHealth() {
        var progress = RecordingTrackProgress()
        progress.noteReceived(at: 5, pts: CMTime(seconds: 1, preferredTimescale: 48_000))
        #expect(progress.lastAppendedUptime == 0)
        #expect(progress.lastCommittedPTS == nil)
    }
}

@Suite("Recording device selection")
struct RecordingDeviceSelectionTests {
    @Test func explicitMicrophoneIsNotReplacedWhenMissingFromEnumeration() {
        let current = RecordingMicrophoneSource.device(id: "usb-mic")
        let resolved = RecordingAudioDeviceEnumerator.resolvedMicrophone(
            current,
            devices: [RecordingAudioDevice(id: "built-in", name: "MacBook Pro Microphone")],
            defaultDeviceID: "built-in"
        )
        #expect(resolved == current)
    }
}

@Suite("Recording finish isolation")
struct RecordingFinishIsolationTests {
    @Test func oldFinishContextCannotClaimANewSession() {
        let sessionA = UUID()
        let sessionB = UUID()
        let operationA = UUID()
        let diagnostics = RecordingSessionDiagnostics(microphone: nil, systemAudio: nil)
        let context = RecordingFinishContext(
            sessionID: sessionA,
            operationID: operationA,
            captureGeneration: 1,
            mode: .salvage,
            writer: nil,
            outputURL: nil,
            includesVideo: false,
            audioTrackCount: 1,
            didAppendMedia: true,
            didAppendVideo: false,
            didAppendMicrophone: true,
            didAppendSystemAudio: false,
            segments: [],
            diagnostics: diagnostics,
            stopReason: .timedOut
        )
        #expect(context.matches(sessionID: sessionA, operationID: operationA))
        #expect(!context.matches(sessionID: sessionB, operationID: operationA))
        #expect(context.markWriterFinalized())
        #expect(!context.markWriterFinalized())
        #expect(context.resume(.failure(RecordingError.cancelled)))
        #expect(!context.resume(.failure(RecordingError.emptyRecording)))
    }
}
