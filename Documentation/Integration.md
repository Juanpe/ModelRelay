# Integrating ModelRelay

ModelRelay is an SDK for Apple-platform clients: a command-line tool, service,
test target or application can use the same workflow engine. No particular
client application's identity or infrastructure is required.

## Ownership and entry points

The host builds a `Workflow`, supplies a `Value`, and calls
`WorkflowExecutor.run` with optional policy, limits and observers. The executor returns a
`WorkflowExecutionReport` or throws an error. Declarative workflows, steps
and fields are `Codable` data; creating them never calls a model or tool.
Developer-supplied `Step.custom` bodies run
only during execution, and make their containing workflow definition
non-serializable. Hosts can rebuild it in Swift and restore separate
recoverable execution state.

The core owns execution order, value substitution, branching, fallback and
step records. The host chooses these integrations:

| Contract | Host responsibility | Optional implementation |
| --- | --- | --- |
| `ModelCatalog` factory | Choose a native AnyLanguageModel and manage resources | AnyLanguageModel providers; `ModelRelayMLX` presets |
| `RequestPerformer` | Send prepared HTTP requests | `ModelRelayHTTP` |
| `SecretProvider` | Retrieve request credentials without putting them in workflow data | Host-owned secure storage |
| `WritePolicy` | Deny, allow or ask before operations that can change something | Host-supplied decision closure |
| `ToolServerConnector` | Connect to remote tools | `ModelRelayMCP` |
| `Step.custom` body | Execute trusted developer Swift code | Inline async throwing closure |
| `WorkflowExecutionCheckpointStore` | Atomically persist trusted checkpoints with generation CAS | Host-owned durable storage |

No SwiftUI, App Intents, browser, Keychain or persistence implementation is
required by the core. Model-provider independence does not mean Linux or
older-OS support: this package still requires Apple OS 27. AnyLanguageModel
owns the single native inference/session runtime, including Apple integrations.

## Values, sessions and model resources

These are three different lifetimes:

1. **Workflow values** exist for one call to `run`. Steps share selected
   results through names and templates. By default, the next step reads the
   previous result. Separate runs do not share that state.
2. **Conversations** use native AnyLanguageModel sessions. They are isolated
   by default; `withContext(.conversation("name"))` reuses a session for that
   name and model ID within one run. A different model/fallback has separate
   history. `withContext(.handoff(["draft"]))` instead passes selected values
   into a fresh session, never copying raw provider transcripts.
3. **Model resources** are resolved once per ID and active invocation, with concurrent
   factory loads coalesced. ModelRelay releases its references when the run
   finishes. The provider still controls weight/KV-cache lifetime. Return a
   shared backend if resource reuse across runs is appropriate. A resumed
   invocation rebuilds its resource cache lazily, not its confirmed step values.

Factories are `@Sendable`. Separate runs, including overlapping calls on one
executor, own independent caches and conversations. Shared initialization
across runs belongs to the host/provider. Cancelling one waiting step does
not cancel an in-flight load while another step still needs it.

Each conversation step rebinds tools to its own permission policy, call log
and value snapshot using native dynamic instructions. Parallel branches may
use different conversations, but sharing one name/model is rejected before
any work runs. Recoverable `start`/`resume` executions can restore explicit
histories within the same logical run. There is no global persistent agent
memory, context-window budgeting or MCP connection pool.

See [ContextAndPolicies](ContextAndPolicies.md) for execution restrictions,
conservative privacy propagation and the host trust boundary.

## Recovery and human approval

Use `start`/`resume` with a host-provided `WorkflowExecutionCheckpointStore` to save execution
state between top-level steps. A `requiringApproval` gate returns a checkpoint
instead of suspending a task. A new executor can restore values, privacy labels,
records and native conversation history; it recreates models/connections lazily.
The host owns storage, encryption, account binding, scheduling and review UI.

The store must use atomic durable compare-and-swap on `executionID` and `generation`;
an unconditional overwrite does not satisfy the protocol. Every operation is
claimed before work. A completed step is not replayed; a `running` checkpoint
is ambiguous and cannot be resumed automatically. After independent external
verification, `confirmCompletion` can record a leaf operation's result without
invoking it. A block/agent cannot be reconstructed from just one result.

Keep workflow IDs stable and change the host revision when custom code,
model configuration, account binding or executable dependencies change. Approving
a gate never bypasses current write/data policy. This does not guarantee
exactly-once remote writes or extend OS execution time. See [Recovery](Recovery.md)
for the API, sensitive-data contract, failure cases and supported boundaries.

### Explicit handoff between agents

This workflow lets a second model see the original question and the first
agent's answer without sharing a mutable chat session:

```swift
import ModelRelay

let workflow = Workflow("Draft and review", output: "review") {
    Step.agent("draft", "Write a concise answer.", model: "writer")
    Step.agent("review", """
        Review the draft and return an improved answer.

        Original question:
        {{input}}

        Draft:
        {{draft}}
        """, model: "reviewer")
}
```

Register `writer` and `reviewer` in the catalog. They may refer to the same
model, or different providers. Adding `kits: ["research"]` makes that kit's
tools available to an agent, provided the executor receives the kit and its
required integrations. Results supplied in prompts remain data, not code
or a new set of tool permissions.

## Validation, concurrency and failures

Use `await executor.validate(workflow)` for structured preflight diagnostics.
`run`/`start`/`resume` reject statically invalid definitions automatically,
including duplicate names, unavailable references/models and explicit output.
Missing dynamic fields fail before substitution/request dispatch. Actual
credentials, remote schemas and model readiness remain runtime checks.

Parallel children read the same snapshot and cannot depend on each other.
Their values are merged in declaration order, while `onStep` callbacks may
arrive in completion order. The callback is `@Sendable`, not main-actor UI
code. A thrown run does not return a partial report; retain records through
the observer if your host needs partial progress. Records can contain user
input and model output: apply the host's privacy and retention policy.

There is at most one fallback model per step. An unknown model ID is a
configuration error, not a reason to try the fallback. Requests and tool
calls are never retried by the executor; an agent cannot switch to a fallback
after any tool has run. A timeout does not prove that a remote write failed.
Avoid replaying a whole workflow after an ambiguous network failure.

`stepTimeout` is not a total-workflow deadline. It bounds individual
operations and relies on cooperative cancellation; model loading and
backend behavior can add time. Host execution limits still apply. A
background job, App Intent or HTTP endpoint must manage its own lifetime.

`WorkflowExecutionLimits` adds a global cooperative duration, model/tool attempt
budgets and a nested-parallel leaf concurrency cap. Counters/ceilings survive
checkpoints. `onEvent` provides metadata-only lifecycle events, while operational
failures retain their typed root cause instead of reducing it to a string.
See [ExecutionSafety](ExecutionSafety.md) for counting, privacy, error and
durable-reconciliation boundaries.

## MCP and OAuth

`ModelRelayMCP` implements tool listing and calls over Streamable HTTP. Its
initial protocol version is `2025-06-18`. It is not a complete MCP SDK:
resources, prompts and stdio are not implemented. Listed JSON schemas are
mapped to ModelRelay's field types, not an arbitrary JSON Schema model.

The connector gets a token from a host-supplied closure for each new
connection. That closure can use **any OAuth client or credential store**;
using `MCPSignIn` is optional:

```swift
import ModelRelay
import ModelRelayMCP

func makeAuthenticatedExecutor(
    serverURL: String,
    tokenForKit: @escaping @Sendable (ToolKit) async throws -> String?,
    writePolicy: WritePolicy = .deny
) -> WorkflowExecutor {
    let kit = ToolKit(id: "workspace", name: "Workspace", tools: [],
                      server: ToolServer(url: serverURL, signsIn: true))
    return WorkflowExecutor(
        writePolicy: writePolicy,
        toolKits: [kit],
        toolServers: MCPConnector(accessToken: tokenForKit, clientName: "MyClient")
    )
}
```

The host must bind credentials to the intended server/resource, authorization
server, client and account, not just a workflow-local kit ID. Do not return
an unrelated provider API key as an MCP access token. Keep tokens out of
workflow JSON, prompts, traces and diagnostic logs.

### Sign-in building blocks

`MCPSignIn` provides these independent operations:

- `discover(server:challenge:session:)` obtains endpoints and scopes.
  `Plan` also has a public initializer for host-supplied, trusted endpoints.
- Use `Client(id:)` for a preregistered public client, or call `register`
  only when the server supports dynamic registration. Registration is not
  a mandatory first step for every server.
- `start` creates a PKCE S256 authorization URL and fresh state. Retain
  its `Attempt` only for that sign-in transaction.
- The host presents the URL and validates that the received callback is
  for its expected redirect URI and authorization server. `finish` checks
  state and exchanges the code; it does not present UI or persist tokens.
- Persist returned `Tokens` in host-owned secure storage. They are Codable
  and can also be initialized from an external OAuth client's credentials.
- Before connecting, refresh expiring tokens when possible. Serialize
  refresh per credential set: concurrent workflows must not race rotating
  refresh tokens. `refresh` preserves the old refresh token if the server
  does not return a replacement; `isExpired` includes a 60-second margin.

The connector neither refreshes tokens nor opens a browser. Missing tokens
and HTTP 401 produce `MCPError.needsSignIn` at the connector boundary. The
executor preserves them in `RelayError.operationFailed`: its category is
`.authenticationRequired` and `failure.rootCause as? MCPError` retains the
challenge. The host owns sign-in presentation. A sign-in flow must not
automatically replay prior workflow writes.

### Compatibility limits

The helpers are not a claim of full conformance with the
[MCP 2026-07-28 authorization specification](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization).
In particular, validated issuer/mix-up protection, Client ID Metadata
Documents and scope-upgrade orchestration are not implemented. Discovery
also retains legacy same-origin endpoint fallbacks. Hosts needing those
guarantees should supply tokens through a suitable OAuth implementation,
not assume the helpers provide them.

The default connector opens a fresh MCP session for each connecting step;
it does not pool connections across agents or runs. A host can implement
`ToolServerConnector` to manage connection lifetime. Any pool must isolate
servers, accounts and authorization changes rather than cache by kit ID alone.

## Product boundaries

Keep a single package dependency and select the required products. HTTP,
specialized cloud decisions and MCP use the core and Apple frameworks.
The core depends on AnyLanguageModel; it does not implement competing cloud
providers. SwiftScript/ShellKit and the ModelRelayScript product are removed.
Custom code is a compiled closure, not a package-selected interpreter.

MLX is opt-in through the `MLX` package trait as well as its product. This
changes the earlier default: clients that used implicit MLX support must
enable `traits: ["MLX"]` explicitly. Package resolution can still fetch
optional dependencies even when their targets are not linked. A separate
distribution package would be needed if dependency-resolution isolation
became a hard requirement.
