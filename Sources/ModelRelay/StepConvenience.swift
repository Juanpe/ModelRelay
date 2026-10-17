extension Step {
    /// Adds a durable approval boundary. Use WorkflowExecutor.start/resume;
    /// ordinary run rejects approval gates rather than silently ignoring them.
    /// Gates inside blocks are not supported; gate the containing block.
    public func requiringApproval(_ reason: String) -> Step {
        var copy = self
        copy.approval = reason
        return copy
    }

    /// Opts into a native conversation or a selected-value handoff.
    public func withContext(_ context: StepContext) -> Step {
        var copy = self
        copy.context = context
        return copy
    }

    /// Narrows execution for this step/block and propagates local-only data.
    public func withPolicy(_ policy: WorkflowExecutionPolicy) -> Step {
        var copy = self
        copy.policy = (copy.policy ?? .unrestricted).combined(with: policy)
        return copy
    }

    /// A free-text model step. The model must be registered in the executor's catalog.
    public static func prompt(
        _ name: String,
        _ instruction: String,
        input: String? = nil,
        model: ModelID,
        fallback: ModelID? = nil
    ) -> Step {
        Step(name, .prompt(instruction: instruction), input: input, model: model, fallback: fallback)
    }

    /// An extraction step whose fields form a guided-generation schema.
    public static func extract(
        _ name: String,
        instruction: String,
        input: String? = nil,
        model: ModelID,
        fallback: ModelID? = nil,
        @FieldBuilder fields: () -> [Field]
    ) -> Step {
        Step(name, .extract(instruction: instruction, fields: fields()), input: input, model: model, fallback: fallback)
    }

    /// A classification step that returns exactly one of `labels`.
    public static func classify(
        _ name: String,
        _ instruction: String,
        labels: [String],
        input: String? = nil,
        model: ModelID,
        fallback: ModelID? = nil
    ) -> Step {
        Step(name, .classify(instruction: instruction, labels: labels), input: input, model: model, fallback: fallback)
    }

    /// Substitutes earlier values into text without invoking a model.
    public static func template(_ name: String, _ text: String, input: String? = nil) -> Step {
        Step(name, .template(text), input: input)
    }

    /// An agent step, isolated by default. Use withContext to opt into history.
    public static func agent(
        _ name: String,
        _ instruction: String,
        tools: [AgentTool] = [],
        kits: [String]? = nil,
        input: String? = nil,
        model: ModelID,
        fallback: ModelID? = nil
    ) -> Step {
        Step(name, .agent(instruction: instruction, tools: tools, kits: kits), input: input, model: model, fallback: fallback)
    }

    /// Answers typed questions using a decision model or guided generation.
    public static func decide(
        _ name: String,
        questions: [Question],
        input: String? = nil,
        model: ModelID,
        fallback: ModelID? = nil
    ) -> Step {
        Step(name, .decide(questions: questions), input: input, model: model, fallback: fallback)
    }

    /// An HTTP request; the executor supplies transport, secrets and write policy.
    public static func request(_ name: String, _ request: HTTPRequest, input: String? = nil) -> Step {
        Step(name, .request(request), input: input)
    }

    /// Builds both branches as data; the executor chooses a branch at execution time.
    public static func ifEquals(
        _ name: String,
        reference: String,
        value: String,
        input: String? = nil,
        @WorkflowBuilder then: () -> [Step],
        @WorkflowBuilder otherwise: () -> [Step] = { [] }
    ) -> Step {
        Step(name, .ifEquals(reference: reference, value: value, then: then(), otherwise: otherwise()), input: input)
    }

    /// Builds a runtime switch with an optional default branch.
    public static func switchOn(
        _ name: String,
        reference: String,
        cases: [SwitchCase],
        input: String? = nil,
        @WorkflowBuilder otherwise: () -> [Step] = { [] }
    ) -> Step {
        Step(name, .switchOn(reference: reference, cases: cases, otherwise: otherwise()), input: input)
    }

    /// Builds a parallel block. Children run on the same input snapshot.
    public static func parallel(_ name: String, input: String? = nil, @WorkflowBuilder steps: () -> [Step]) -> Step {
        Step(name, .parallel(steps()), input: input)
    }

    /// Reads an image using a vision model or Apple's text recognition.
    public static func readImage(
        _ name: String,
        instruction: String = "",
        input: String? = nil,
        model: ModelID,
        fallback: ModelID? = nil
    ) -> Step {
        Step(name, .readImage(instruction: instruction), input: input, model: model, fallback: fallback)
    }

    /// Runs trusted developer code once. The body is not serializable and
    /// receives values only, never the executor's secrets or transports.
    public static func custom(
        _ name: String,
        input: String? = nil,
        body: @escaping @Sendable (CustomStepContext) async throws -> Value
    ) -> Step {
        Step(name, .custom(CustomStepBody(body)), input: input)
    }

    /// Calls one named tool without asking a model to select it.
    public static func useTool(
        _ name: String,
        kit: String,
        tool: String,
        arguments: [String: String] = [:],
        input: String? = nil
    ) -> Step {
        Step(name, .useTool(kit: kit, tool: tool, arguments: arguments), input: input)
    }
}
