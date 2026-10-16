import Foundation

/// A chain of steps from one input to one output. Steps run top to bottom;
/// `if` and `parallel` are blocks that contain steps, so a workflow is a tree,
/// never a free graph. That keeps it easy to show as a list and easy to run.
public struct Workflow: Codable, Sendable, Hashable, Identifiable {
    public static let currentSchemaVersion = 1

    public var id: UUID
    public var name: String
    public var steps: [Step]
    /// Which step's value is the workflow's result. Nil: the last step's.
    public var output: String?
    public var schemaVersion: Int

    public init(id: UUID = UUID(), name: String, steps: [Step], output: String? = nil) {
        self.id = id
        self.name = name
        self.steps = steps
        self.output = output
        self.schemaVersion = Self.currentSchemaVersion
    }
}

/// One step. `name` identifies its result for later steps and templates
/// (`{{extract.total}}`), so names are unique within a workflow.
public struct Step: Codable, Sendable, Hashable {
    public var name: String
    public var kind: Kind
    /// Where the step reads its text from. Nil: the previous step's result
    /// (or the workflow input for the first step).
    public var input: String?
    /// The model to use, and an optional second model tried once if the first
    /// fails or returns invalid output. Steps that need no model ignore both.
    public var model: ModelID?
    public var fallback: ModelID?
    /// Nil means isolated. Sharing requires an explicit run-local conversation.
    public var context: StepContext?
    /// Optional restrictions; they cannot weaken the executor or a parent block.
    public var policy: WorkflowExecutionPolicy?
    /// Pause before this top-level step in a recoverable execution. This is
    /// separate from WritePolicy: approving a step never grants tool permission.
    public var approval: String?

    public init(_ name: String, _ kind: Kind, input: String? = nil, model: ModelID? = nil, fallback: ModelID? = nil,
                context: StepContext? = nil, policy: WorkflowExecutionPolicy? = nil, approval: String? = nil) {
        self.name = name
        self.kind = kind
        self.input = input
        self.model = model
        self.fallback = fallback
        self.context = context
        self.policy = policy
        self.approval = approval
    }

    public indirect enum Kind: Codable, Sendable, Hashable {
        /// Free text answer. The instruction may use templates.
        case prompt(instruction: String)
        /// A dictionary with the given fields, generated with a guided schema.
        case extract(instruction: String, fields: [Field])
        /// Exactly one of the labels.
        case classify(instruction: String, labels: [String])
        /// Text built from earlier results; no model. `{{input}}`, `{{step}}`,
        /// `{{step.field}}`. Substitution only: nothing is evaluated.
        case template(String)
        /// Runs `then` when the referenced value equals `value`, else `otherwise`.
        /// The block's result is the result of the branch that ran.
        case ifEquals(reference: String, value: String, then: [Step], otherwise: [Step])
        /// A model that may call the given tools (HTTP requests) before
        /// answering in text. At most `AgentTool.maxCallsPerStep` calls.
        /// `kits` names reusable `ToolKit`s (by id) whose tools are added to
        /// `tools`; the executor is given the kits.
        /// Isolated by default; opt into native history with StepContext.
        /// Tools and permissions are resolved again for every step.
        case agent(instruction: String, tools: [AgentTool], kits: [String]? = nil)
        /// Answers typed questions about the text (yes/no, one of, score) in
        /// one go. A `DecisionModel` also gives probabilities; a language model
        /// answers with a guided schema. The result has one field per question.
        case decide(questions: [Question])
        /// Calls an HTTP API. A JSON response becomes fields (`{{step.field}}`),
        /// anything else text. No model; never retried.
        case request(HTTPRequest)
        /// Runs the steps of the first case whose value equals the referenced
        /// value (ignoring case and surrounding spaces), else `otherwise`. The
        /// block's result is the result of the branch that ran.
        case switchOn(reference: String, cases: [SwitchCase], otherwise: [Step])
        /// Runs the steps concurrently on the same input. The block's result is a
        /// dictionary keyed by step name: this is the "merge".
        case parallel([Step])
        /// Sends an image (the step's input must be `Value.image`) with the
        /// instruction to a model that can see images, and returns its text.
        /// An empty instruction asks for all the text in the image.
        /// `ModelID.appleTextRecognition` reads it on device without a model.
        case readImage(instruction: String)
        /// Trusted Swift code supplied by the developer, never model output.
        /// Custom bodies are in-memory only and cannot be encoded or decoded.
        case custom(CustomStepBody)
        /// Calls one tool of a tool set (by kit id) with arguments built
        /// from templates, without a model choosing anything. Tools that
        /// change something need the write policy's permission.
        case useTool(kit: String, tool: String, arguments: [String: String])
    }
}

/// One path of a `switchOn` step.
public struct SwitchCase: Codable, Sendable, Hashable {
    public var value: String
    public var steps: [Step]

    public init(_ value: String, steps: [Step] = []) {
        self.value = value
        self.steps = steps
    }
}

/// Identifies a model, resolved at run time by a `ModelCatalog`.
/// Examples: `apple.on-device`, `apple.private-cloud`, `mlx:mlx-community/Qwen3-1.7B-4bit`.
public struct ModelID: Codable, Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    /// Encoded as a plain string: `"model": "apple.on-device"`.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let appleOnDevice: ModelID = "apple.on-device"
    public static let applePrivateCloud: ModelID = "apple.private-cloud"
    /// Apple's on-device text recognition (Vision): reads the text in an
    /// image exactly as written, and nothing else. Only for `readImage` steps.
    public static let appleTextRecognition: ModelID = "apple.text-recognition"
}
