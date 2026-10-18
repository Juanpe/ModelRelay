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
