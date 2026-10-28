# 🗺 ModelRelay API map

Find the API for a need, then open the linked guide. Paths are relative to
the ModelRelay checkout of the app's resolved version (see SKILL.md, step 2).
Read signatures in `Sources/` before calling anything not shown in a guide.

## 🎯 Steps

| You need… | Step | Guide |
| --- | --- | --- |
| Generated text | `Step.prompt("summary", "Summarize.", model: .appleOnDevice)` | `Documentation/Usage.md#step-types` |
| Typed fields | `Step.extract("expense", instruction: "…", model:) { Field(…) }` | `README.md#usage` |
| Lists of records | `Field("lines", .list(.object([Field(…)])))` | `Documentation/Usage.md#nested-fields` |
| One label | `Step.classify("kind", "…", labels: […], model:)` | `Documentation/Usage.md#composition` |
| Yes/no, choices, scores | `Step.decide("ticket", questions: [Question(…)], model:)` | `Documentation/Usage.md#decision-models` |
| An answer that may call tools | `Step.agent("answer", "…", tools: [AgentTool(…)], model:)` | `Documentation/Usage.md#http-requests-and-agent-tools` |
| Text from an image | `Step.readImage("receipt", model: .appleTextRecognition)` | `Documentation/Usage.md#images` |
| Text built from earlier results | `Step.template("result", "{{summary}}")` | `Documentation/Usage.md#values-and-input` |
| An HTTP call | `Step.request("weather", HTTPRequest(url: "…"))` | `Documentation/Usage.md#http-requests-and-agent-tools` |
| One named tool, no model | `Step.useTool("file", kit: "issues", tool: "create_issue")` | `Documentation/Usage.md#mcp-tools-and-oauth` |
| App logic in Swift | `Step.custom("normalized") { context in … }` | `Documentation/Usage.md#custom-swift` |
| A runtime branch | `Step.ifEquals` / `Step.switchOn` with `SwitchCase` | `Documentation/Usage.md#composition` |
| Independent work at once | `Step.parallel("analysis") { … }` | `README.md#advanced` |

`Field` kinds and `Question` answers are described next to their recipes.
Steps read the previous result by default; select another with `input:`.

## 🧷 Step modifiers

| You need… | Modifier | Guide |
| --- | --- | --- |
| Shared native history | `.withContext(.conversation("writer"))` | `Documentation/ContextAndPolicies.md#three-context-modes` |
| Selected results for another model | `.withContext(.handoff(["draft"]))` | `Documentation/ContextAndPolicies.md#three-context-modes` |
| A stricter policy for one step | `.withPolicy(.readOnly)` | `Documentation/ContextAndPolicies.md#execution-policies` |
| A person reviews before a step | `.requiringApproval("Review before sending")` | `Documentation/Recovery.md#define-once-review-later` |

## 🧠 Models

| Provider | Register | Guide |
| --- | --- | --- |
| Apple on-device, Private Cloud Compute, OCR | Built in: `.appleOnDevice`, `.applePrivateCloud`, `.appleTextRecognition` | `Documentation/Models.md#apple` |
| OpenAI, Anthropic | `OpenResponsesLanguageModel`, `AnthropicLanguageModel` | `Documentation/Models.md#cloud` |
| OpenAI-compatible servers | `OpenAILanguageModel` with a base URL | `Documentation/Models.md#compatible-servers` |
| Ollama | `OllamaLanguageModel`, registered as `.remote` | `Documentation/Models.md#ollama` |
| Jev decisions | `CloudModels.jev` with `DecisionsAPIModel` | `Documentation/Models.md#jev` |
| MLX in-process | `ModelCatalog().registeringMLXModels()` and `MLXModels` | `Documentation/Models.md#mlx` |
| Several in one workflow | One catalog ID per model | `Documentation/Models.md#mix-models` |

Package setup for each product: `Documentation/Models.md#setup` and
`README.md#installation`.

## 🔌 Host integrations

| The app supplies | Type | Guide |
| --- | --- | --- |
| Model factories | `ModelCatalog` | `Documentation/Integration.md#ownership-and-entry-points` |
| HTTP transport | `RequestPerformer` or `URLSessionRequestPerformer` | `Documentation/Usage.md#http-requests-and-agent-tools` |
| Credentials | `SecretProvider` with `{{secret.NAME}}` | `Documentation/Usage.md#http-requests-and-agent-tools` |
| Write decisions | `WritePolicy` | `Documentation/ContextAndPolicies.md#execution-policies` |
| Reusable tools | `ToolKit`, `AgentTool`, `ToolServer` | `Documentation/Usage.md#http-requests-and-agent-tools` |
| Tools written in Swift | `HostToolKit`, `HostTool` | `Documentation/Usage.md#host-tools` |
| MCP access | `MCPConnector`, `MCPSignIn` | `Documentation/Integration.md#mcp-and-oauth` |
| Durable review state | `WorkflowExecutionCheckpointStore` | `Documentation/Recovery.md#storage-contract-atomic-durable-compare-and-swap` |

## ▶️ Running and observing

| You need… | API | Guide |
| --- | --- | --- |
| The final result | `WorkflowExecutor.run` and `WorkflowExecutionReport` | `README.md#usage` |
| Live progress | `execute`, then `updates` and `result` on `WorkflowExecution` | `Documentation/ExecutionSafety.md#metadata-only-execution-events` |
| Early diagnostics | `validate`, `WorkflowValidationIssue` | `Documentation/ExecutionSafety.md#validation-before-execution` |
| Budgets | `WorkflowExecutionLimits`, `report.usage` | `Documentation/ExecutionSafety.md#global-limits-and-usage` |
| Typed failures | `RelayError`, `WorkflowOperationFailure` | `Documentation/ExecutionSafety.md#structured-failures-and-retained-causes` |
| Pause and continue | `start`, `resume`, `startExecution`, `resumeExecution` | `Documentation/Recovery.md#entry-points` |
| Reconcile an interrupted step | `confirmCompletion` | `Documentation/Recovery.md#interrupted-operations-and-side-effects` |
| Privacy labels | `WorkflowExecutionPolicy`, `report.outputDataAccess` | `Documentation/ContextAndPolicies.md#privacy-propagation` |
