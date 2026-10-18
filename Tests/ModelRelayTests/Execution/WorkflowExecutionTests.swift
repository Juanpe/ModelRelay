import Foundation
import Testing
@testable import ModelRelay

@Suite(.timeLimit(.minutes(1))) struct WorkflowExecutionTests {
    @Test func resultCanBeAwaitedWithoutConsumingOrReexecutingTheStream() async throws {
        let workflow = Workflow(name: "Buffered") {
            for index in 0 ..< 200 {
                Step.template("step\(index)", "{{input}}")
            }
        }
        let execution = WorkflowExecutor().execute(workflow, input: .text("value"))
        let report = try await execution.result
        let sameReport = try await execution.result
        #expect(sameReport.executionID == report.executionID)
        var events: [WorkflowExecutionEvent] = []
        var records: [StepRecord] = []
        for try await update in execution.updates {
            switch update {
            case let .event(event): events.append(event)
            case let .step(record): records.append(record)
            }
        }
        #expect(records == report.records)
        #expect(records.count == 200)
        #expect(events.first?.kind == .executionStarted)
        #expect(events.last?.kind == .executionCompleted)
        #expect(events.map(\.sequence) == Array(1 ... events.count))
        #expect(events.filter { $0.kind == .executionStarted }.count == 1)
        #expect(report.output == .text("value"))
    }

    @Test func partialRecordsAndTheOriginalErrorReachBothConsumers() async throws {
        let model = ScriptedModel("model", replies: [nil])
        let workflow = Workflow(name: "Fails") {
            Step.template("first", "saved")
            Step.prompt("second", "Fail", model: "model")
        }
        let execution = WorkflowExecutor(catalog: .scripted(["model": model])).execute(workflow, input: .null)
        var records: [StepRecord] = []
        var kinds: [WorkflowExecutionEvent.Kind] = []
        do {
            for try await update in execution.updates {
                switch update {
                case let .event(event): kinds.append(event.kind)
                case let .step(record): records.append(record)
                }
            }
            Issue.record("expected stream failure")
        } catch let RelayError.operationFailed(step, failure) {
            #expect(step == "second")
            #expect(failure.rootCause is ScriptedModel.Failure)
        }
        #expect(records.map(\.step) == ["first", "second"])
        #expect(records.last?.failureInfo != nil)
        #expect(kinds.last == .executionFailed)
        do {
            _ = try await execution.result
            Issue.record("expected result failure")
        } catch let RelayError.operationFailed(step, failure) {
            #expect(step == "second")
            #expect(failure.rootCause is ScriptedModel.Failure)
        }
        #expect(model.callCount == 1)
    }

    @Test func cancellingAResultWaiterAlsoCancelsExecution() async throws {
        let (started, start) = AsyncStream<Void>.makeStream()
        let workflow = Workflow(name: "Result cancellation") {
            Step.custom("slow") { _ in
                start.yield(); start.finish()
                try await Task.sleep(for: .seconds(10))
                return .null
            }
        }
        let execution = WorkflowExecutor().execute(workflow, input: .null)
        let waiter = Task { try await execution.result }
        for await _ in started {
            break
        }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await #expect(throws: CancellationError.self) { try await execution.result }
    }

    @Test func updatesAreANativeThrowingStream() async throws {
        let workflow: Workflow = .init(name: "Native updates") { Step.template("result", "ok") }
        let execution: WorkflowExecution<WorkflowExecutionReport> = WorkflowExecutor().execute(workflow, input: .null)
        let updates: AsyncThrowingStream<WorkflowExecutionUpdate, any Error> = execution.updates
        var iterator: AsyncThrowingStream<WorkflowExecutionUpdate, any Error>.AsyncIterator = updates.makeAsyncIterator()
        var records: [StepRecord] = []

        while let update = try await iterator.next() {
            if case let .step(record) = update { records.append(record) }
        }

        #expect(records.map(\.value) == [.text("ok")])
        #expect(try await execution.result.output == .text("ok"))
    }

    @Test func progressCanBeReadBeforeTheExecutionFinishes() async throws {
        let (release, continuation) = AsyncStream<Void>.makeStream()
        let workflow = Workflow(name: "Live") {
            Step.template("first", "ready")
            Step.custom("wait") { _ in
                for await _ in release {
                    break
                }
                return .text("done")
            }
        }
        let execution = WorkflowExecutor().execute(workflow, input: .null)
        defer { execution.cancel(); continuation.finish() }
        for try await update in execution.updates {
            if case let .step(record) = update, record.step == "first" {
                #expect(record.value == .text("ready"))
                continuation.yield(); continuation.finish()
            }
        }
        #expect(try await execution.result.output == .text("done"))
    }

    @Test func concurrentExecutionsDoNotMixProgressOrResults() async throws {
        let workflow = Workflow(name: "Independent") { Step.template("result", "{{input}}") }
        let executor = WorkflowExecutor()
        let first = executor.execute(workflow, input: .text("one"))
        let second = executor.execute(workflow, input: .text("two"))
        let firstReport = try await first.result
        let secondReport = try await second.result
        #expect(firstReport.executionID != secondReport.executionID)
        #expect(firstReport.output == .text("one"))
        #expect(secondReport.output == .text("two"))
        for (execution, report) in [(first, firstReport), (second, secondReport)] {
            for try await update in execution.updates {
                if case let .event(event) = update { #expect(event.executionID == report.executionID) }
            }
        }
    }

    @Test @MainActor func updatesCanBeConsumedOnTheUIActor() async throws {
        let workflow = Workflow(name: "UI") { Step.template("result", "ok") }
        let execution = WorkflowExecutor().execute(workflow, input: .null)
        var steps: [String] = []
        for try await update in execution.updates {
            if case let .step(record) = update { steps.append(record.step) }
        }
        #expect(steps == ["result"])
        #expect(try await execution.result.output == .text("ok"))
    }

    @Test func cancellingANativeModelDoesNotSelectFallback() async throws {
        let primary = ScriptedModel("primary", replies: ["<hang>"])
        let backup = ScriptedModel("backup", replies: ["unused"])
        let workflow = Workflow(name: "Native cancellation") {
            Step.prompt("ask", "Q", model: "primary", fallback: "backup")
        }
        let execution = WorkflowExecutor(catalog: .scripted(["primary": primary, "backup": backup]))
            .execute(workflow, input: .null)
        defer { execution.cancel() }
        await #expect(throws: CancellationError.self) {
            for try await update in execution.updates {
                if case let .event(event) = update, event.kind == .modelStarted { execution.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await execution.result }
        #expect(backup.callCount == 0)
    }

    @Test func parallelRecordsArriveLiveButTheReportKeepsDeclarationOrder() async throws {
        let (release, continuation) = AsyncStream<Void>.makeStream()
        let workflow = Workflow(name: "Parallel") {
            Step.parallel("both") {
                Step.custom("first") { _ in
                    for await _ in release {
                        break
                    }
                    return .text("one")
                }
                Step.template("second", "two")
            }
        }
        let execution = WorkflowExecutor().execute(workflow, input: .null)
        defer { execution.cancel(); continuation.finish() }
        var steps: [String] = []
        var sequence: [Int] = []
        for try await update in execution.updates {
            switch update {
            case let .step(record):
                steps.append(record.step)
                if record.step == "second" { continuation.yield(); continuation.finish() }
            case let .event(event): sequence.append(event.sequence)
            }
        }
        #expect(steps == ["second", "first"])
        #expect(sequence == Array(1 ... sequence.count))
        #expect(try await execution.result.records.map(\.step) == ["first", "second"])
    }
}
