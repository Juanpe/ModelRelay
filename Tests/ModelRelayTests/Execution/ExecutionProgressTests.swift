import Foundation
import Testing
@testable import ModelRelay

@Suite struct ExecutionProgressTests {
    @Test func recordsAndMetadataUseTheSameContinuation() async throws {
        let execution: WorkflowExecution<String> = .init { updates in
            let control: ExecutionControl = .init(workflowID: UUID(), limits: .unlimited, updates: updates)
            defer { control.finish() }

            control.emit(.executionStarted)
            control.emit(StepRecord(step: "first", value: .text("value"), model: nil, usedFallback: false, duration: .zero, skipped: false))
            control.emit(.executionCompleted)

            return "done"
        }
        var received: [String] = []

        for try await update in execution.updates {
            switch update {
            case let .event(event): received.append(event.kind.rawValue)
            case let .step(record): received.append(record.step)
            }
        }

        #expect(received == ["executionStarted", "first", "executionCompleted"])
        #expect(try await execution.result == "done")
    }

    @Test func finishingControlDetachesProgressWithoutClosingTheStream() async throws {
        let (updates, continuation): (
            AsyncThrowingStream<WorkflowExecutionUpdate, any Error>,
            AsyncThrowingStream<WorkflowExecutionUpdate, any Error>.Continuation
        ) = AsyncThrowingStream<WorkflowExecutionUpdate, any Error>.makeStream()
        let control: ExecutionControl = .init(workflowID: UUID(), limits: .unlimited, updates: continuation)
        let record: StepRecord = .init(step: "late", value: .null, model: nil, usedFallback: false, duration: .zero, skipped: false)

        control.emit(.executionStarted)
        control.finish()
        control.emit(record)
        control.emit(.executionCompleted)

        let marker: StepRecord = .init(step: "owner", value: .null, model: nil, usedFallback: false, duration: .zero, skipped: false)
        switch continuation.yield(.step(marker)) {
        case .enqueued: break
        default: Issue.record("Only the execution owner should close its stream")
        }
        continuation.finish()
        var received: [String] = []

        for try await update in updates {
            switch update {
            case let .event(event): received.append(event.kind.rawValue)
            case let .step(record): received.append(record.step)
            }
        }

        #expect(received == ["executionStarted", "owner"])
    }
}
