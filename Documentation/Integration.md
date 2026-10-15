# Integrating ModelRelay

ModelRelay is an SDK for Apple-platform clients: a command-line tool, service,
test target or application can use the same workflow engine. No particular
client application's identity or infrastructure is required.

## Ownership and entry points

The host builds a `Workflow`, supplies a `Value`, and calls
`WorkflowRunner.run(_:input:onStep:)`. The runner returns a `RunReport` or
throws an error. Declarative workflows, steps and fields are `Codable` data; creating them
never calls a model or tool. Developer-supplied `Step.custom` bodies run
only during execution, and make their containing workflow in-memory only.

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

No SwiftUI, App Intents, browser, Keychain or persistence implementation is
required by the core. Model-provider independence does not mean Linux or
older-OS support: this package still requires Apple OS 27. AnyLanguageModel
owns the single native inference/session runtime, including Apple integrations.

## Values, sessions and model resources

These are three different lifetimes:

1. **Workflow values** exist for one call to `run`. Steps share selected
   results through names and templates. By default, the next step reads the
   previous result. Separate runs do not share that state.
2. **Conversations** exist inside a `LanguageModelSession`. Every model step
   creates a fresh session today. A single agent step keeps its tool turns
   in that session, but the next agent step does not inherit those turns.
3. **Model resources** belong to the registered factory and its backend.
   The runner calls the factory for each model attempt; the catalog does
   not memoize it. A factory may return a shared model, or use a host-owned
   resource manager that loads once. Whether weights/executors are reused
   depends on the provider; a fresh session is not proof of a reload.

Factories are `@Sendable` and may be called concurrently, for example by
parallel steps or overlapping runs. Coordinate expensive initialization in
your backend rather than storing a single mutable conversation globally.
Returning the same model configuration is not a promise that its executor
or weights are cached.

There is no named persistent `Agent` API, automatic transcript handoff,
context-window budgeting or MCP connection pool in the current runner.
Reusing a tool kit or model ID shares configuration, not conversation memory.
Do not rely on hidden state to move information between steps.

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
tools available to an agent, provided the runner receives the kit and its
required integrations. Results supplied in prompts remain data, not code
or a new set of tool permissions.

## Validation, concurrency and failures

Check `workflow.referenceIssues` before running generated or edited
workflows, and keep all step names unique. The runner is not a complete
schema validator. Missing template references currently render as empty
text; an unresolved `Workflow.output` falls back to the last value. A
step's explicit missing input reference throws instead. Do not use those
fallbacks as validation.

Parallel children read the same snapshot and cannot depend on each other.
Their values are merged in declaration order, while `onStep` callbacks may
arrive in completion order. The callback is `@Sendable`, not main-actor UI
code. A thrown run does not return a partial report; retain records through
the observer if your host needs partial progress. Records can contain user
input and model output: apply the host's privacy and retention policy.

There is at most one fallback model per step. An unknown model ID is a
configuration error, not a reason to try the fallback. Requests and tool
calls are never retried by the runner; an agent cannot switch to a fallback
after any tool has run. A timeout does not prove that a remote write failed.
Avoid replaying a whole workflow after an ambiguous network failure.

`stepTimeout` is not a total-workflow deadline. It bounds individual
operations and relies on cooperative cancellation; model loading and
backend behavior can add time. Host execution limits still apply. A
background job, App Intent or HTTP endpoint must manage its own lifetime.

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

func makeAuthenticatedRunner(
    serverURL: String,
    tokenForKit: @escaping @Sendable (ToolKit) async throws -> String?,
    writePolicy: WritePolicy = .deny
) -> WorkflowRunner {
    let kit = ToolKit(id: "workspace", name: "Workspace", tools: [],
                      server: ToolServer(url: serverURL, signsIn: true))
    return WorkflowRunner(
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
runner currently wraps connector failures as `RelayError.stepFailed`; a
host needing typed sign-in routing should authorize/preflight connections
before starting a workflow. A sign-in flow must not automatically replay
prior workflow writes.

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
