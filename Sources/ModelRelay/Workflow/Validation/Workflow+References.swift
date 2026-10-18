import Foundation

/// A reference that cannot be resolved on every path reaching its step.
public struct WorkflowReferenceIssue: Hashable, Sendable {
    public let step: String
    public let reference: String
}

extension Workflow {
    /// Steps whose results are available before `name`. Parallel siblings run
    /// on the same snapshot; conditional siblings are mutually exclusive.
    public func availableSteps(before name: String) -> [Step] {
        Self.find(name, in: steps, available: []) ?? []
    }

    /// Renames a result and updates its references atomically. Literal text,
    /// secret names and tool arguments are left intact.
    @discardableResult
    public mutating func renameStep(from oldName: String, to newName: String) -> Bool {
        let all = Self.flatten(steps)
        guard all.contains(where: { $0.name == oldName }),
              !all.contains(where: { $0.name == newName }),
              !["input", "secret", "args"].contains(newName), !newName.isEmpty,
              newName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return false }
        steps = steps.map { Self.rename($0, from: oldName, to: newName) }
        if output == oldName { output = newName }
        return true
    }

    /// Unavailable inputs, conditions, template values and explicit outputs.
    /// Request responses have dynamic fields, so only their base is checked.
    public var referenceIssues: [WorkflowReferenceIssue] {
        var issues: [WorkflowReferenceIssue] = []
        for step in Self.flatten(steps) {
            let available = Set(availableSteps(before: step.name).map(\.name) + ["input"])
            var refs = step.input.map { [$0] } ?? []
            if case let .handoff(values) = step.context { refs += values }
            switch step.kind {
            case let .ifEquals(reference, _, _, _), let .switchOn(reference, _, _): refs.append(reference)
            default: break
            }
            for (text, allowsSecrets, allowsArguments) in Self.templates(in: step) {
                refs += Self.tokens(in: text).filter {
                    !(allowsSecrets && $0.hasPrefix("secret.")) && !(allowsArguments && $0.hasPrefix("args."))
                }
            }
            for ref in Set(refs).sorted() {
                let base = ref.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
                if !available.contains(base) { issues.append(.init(step: step.name, reference: ref)) }
            }
        }
        if let output, !Set(Self.exported(steps).map(\.name)).contains(output) {
            issues.append(.init(step: "Output", reference: output))
        }
        return issues
    }

    private static func find(_ name: String, in steps: [Step], available initial: [Step]) -> [Step]? {
        var available = initial
        for step in steps {
            if step.name == name { return available }
            switch step.kind {
            case let .parallel(children):
                // Each child starts with the same available values.
                for child in children {
                    if let found = find(name, in: [child], available: available) { return found }
                }
                available += children
            case let .ifEquals(_, _, then, otherwise):
                for branch in [then, otherwise] {
                    if let found = find(name, in: branch, available: available) { return found }
                }
            case let .switchOn(_, cases, otherwise):
                for branch in cases.map(\.steps) + [otherwise] {
                    if let found = find(name, in: branch, available: available) { return found }
                }
            default: break
            }
            available.append(step)
        }
        return nil
    }

    private static func exported(_ steps: [Step]) -> [Step] {
        steps.flatMap { step in
            if case let .parallel(children) = step.kind { return children + [step] }
            return [step]
        }
    }

    private static func flatten(_ steps: [Step]) -> [Step] {
        steps.flatMap { step in
            let children: [Step] = switch step.kind {
            case let .ifEquals(_, _, then, otherwise): then + otherwise
            case let .switchOn(_, cases, otherwise): cases.flatMap(\.steps) + otherwise
            case let .parallel(steps): steps
            default: []
            }
            return [step] + flatten(children)
        }
    }

    private static func tokens(in text: String) -> [String] { Template.references(in: text) }

    static func templates(in step: Step) -> [(String, Bool, Bool)] {
        func request(_ request: HTTPRequest, arguments: Bool) -> [(String, Bool, Bool)] {
            ([request.url, request.body ?? ""] + request.headers.map(\.value)).map { ($0, true, arguments) }
        }
        switch step.kind {
        case let .prompt(text), let .extract(text, _), let .classify(text, _), let .template(text),
             let .readImage(text):
            return [(text, false, false)]
        case let .agent(text, tools, _):
            return [(text, false, false)] + tools.flatMap { request($0.request, arguments: true) }
        case let .request(value): return request(value, arguments: false)
        case let .decide(questions): return questions.map { ($0.instructions, false, false) }
        case let .useTool(_, _, arguments): return arguments.values.map { ($0, false, false) }
        default: return []
        }
    }

    private static func rename(_ step: Step, from old: String, to new: String) -> Step {
        func reference(_ text: String) -> String {
            if text == old { return new }
            if text.hasPrefix(old + ".") { return new + text.dropFirst(old.count) }
            return text
        }
        func template(_ text: String) -> String {
            var rest = Substring(text), result = ""
            while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
                result += rest[..<open.lowerBound]
                let token = String(rest[open.upperBound ..< close.lowerBound])
                let trimmed = token.trimmingCharacters(in: .whitespaces)
                let replaced = reference(trimmed)
                result += "{{" + (replaced == trimmed ? token : token.replacingOccurrences(of: trimmed, with: replaced)) + "}}"
                rest = rest[close.upperBound...]
            }
            return result + rest
        }
        func request(_ value: HTTPRequest) -> HTTPRequest {
            var copy = value
            copy.url = template(copy.url)
            copy.body = copy.body.map(template)
            copy.headers = copy.headers.map { .init($0.name, template($0.value)) }
            return copy
        }
        func children(_ list: [Step]) -> [Step] { list.map { rename($0, from: old, to: new) } }
        var copy = step
        if copy.name == old { copy.name = new }
        copy.input = copy.input.map(reference)
        if case let .handoff(values) = copy.context { copy.context = .handoff(values.map(reference)) }
        switch copy.kind {
        case let .prompt(text): copy.kind = .prompt(instruction: template(text))
        case let .extract(text, fields): copy.kind = .extract(instruction: template(text), fields: fields)
        case let .classify(text, labels): copy.kind = .classify(instruction: template(text), labels: labels)
        case let .template(text): copy.kind = .template(template(text))
        case let .readImage(text): copy.kind = .readImage(instruction: template(text))
        case let .useTool(kit, tool, arguments):
            copy.kind = .useTool(kit: kit, tool: tool, arguments: arguments.mapValues(template))
        case .custom:
            // Compiled closures cannot be inspected or rewritten. Only the
            // step name and explicit input reference above can be renamed.
            break
        case let .request(value): copy.kind = .request(request(value))
        case let .agent(text, tools, kits):
            copy.kind = .agent(instruction: template(text), tools: tools.map { tool in
                var tool = tool
                tool.request = request(tool.request)
                return tool
            }, kits: kits)
        case let .decide(questions):
            copy.kind = .decide(questions: questions.map { question in
                var question = question
                question.instructions = template(question.instructions)
                return question
            })
        case let .ifEquals(value, expected, then, otherwise):
            copy.kind = .ifEquals(reference: reference(value), value: expected, then: children(then), otherwise: children(otherwise))
        case let .switchOn(value, cases, otherwise):
            copy.kind = .switchOn(reference: reference(value), cases: cases.map { .init($0.value, steps: children($0.steps)) }, otherwise: children(otherwise))
        case let .parallel(list): copy.kind = .parallel(children(list))
        }
        return copy
    }
}
