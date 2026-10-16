# 🔌 Integrating ModelRelay

[← README](../README.md) · [Usage recipes](Usage.md) · [Context](ContextAndPolicies.md)

Bring your app's data, models and permissions. ModelRelay connects the steps;
you keep the interface, accounts and storage.

[🧩 Wiring](#ownership-and-entry-points) · [📡 Progress](#validation-concurrency-and-failures) · [🔑 MCP and OAuth](#mcp-and-oauth)

<a name="ownership-and-entry-points"></a>

## 🧩 Plug in what you need

Build a `Workflow`, pass a `Value`, then call `WorkflowExecutor.run`.
You receive a `WorkflowExecutionReport` or a typed error.

| Integration | You supply | Optional implementation |
| --- | --- | --- |
| `ModelCatalog` | Native model factories and resource ownership | AnyLanguageModel providers / MLX presets |
| `RequestPerformer` | HTTP transport | `ModelRelayHTTP` |
| `SecretProvider` | Request credentials from secure storage | Your storage |
| `WritePolicy` | Deny, allow or ask before writes | Your decision closure |
| `ToolServerConnector` | Remote tool access | `ModelRelayMCP` |
| `Step.custom` | Trusted, compiled Swift logic | Your async body |
| `WorkflowExecutionCheckpointStore` | Atomic, durable generation-based saves | Your database/store |

Declarative workflows are Codable; creating one runs no model or tool.
Custom bodies make the definition non-serializable. Rebuild it in Swift and
restore a separate execution checkpoint when needed.

AnyLanguageModel owns inference and native sessions. ModelRelay does not
require SwiftUI, App Intents, a browser or Keychain. Platform requirements
and optional products are listed in the [README](../README.md#installation).

<a name="values-sessions-and-model-resources"></a>

## 🧠 Be explicit about shared state

| Share… | Use… |
| --- | --- |
| A completed value | `input:` references or `{{step.field}}` |
| Native history within one execution | `.conversation("name")` with the same model ID |
| Selected results with a fresh model | `.handoff(["draft", "input"])` |
| Backend resources across executions | A host/provider-owned shared backend |

Separate executions do not share conversations or factory caches.
A resume restores confirmed values/history but reloads resources lazily.
There is no built-in cross-run memory, compaction or MCP pool.
[Context and resource lifetimes →](ContextAndPolicies.md)

<a name="recovery-and-human-approval"></a>

## ⏸ Pause for a person

Use `start` / `resume` and a host-owned checkpoint store for
`requiringApproval` gates. Gates pause before a top-level step or block;
they do not keep a task suspended.

> 📣 The store needs durable compare-and-swap, not unconditional saves.
> Interrupted writes must be reconciled, never blindly replayed.
> [Recovery contract →](Recovery.md)

<a name="explicit-handoff-between-agents"></a>

Agent handoff examples live in [context](ContextAndPolicies.md#three-context-modes).
Pass selected values, not another provider's opaque transcript.

<a name="validation-concurrency-and-failures"></a>

## 📡 Validate and observe

Execution validates definitions automatically. Use `validate` for diagnostics
before work; credentials, model readiness and remote schemas remain runtime checks.

- Parallel children read the same snapshot. Results merge in declaration
  order; `onStep` callbacks may arrive in completion order.
- Callbacks are `@Sendable`, not UI-actor code. Keep full records yourself
  when you need partial progress after a thrown run.
- Step records may contain user input/output. `onEvent` carries metadata instead.
- There is one fallback per model step, no automatic request/tool replay,
  and no fallback after a host tool attempt.

`stepTimeout` bounds individual operations. Global limits add active duration,
attempt budgets and leaf concurrency. Cancellation is cooperative; your
background job or endpoint still owns its lifetime.
[Errors, events and exact counting →](ExecutionSafety.md)

<a name="mcp-and-oauth"></a>

## 🔑 Connect an MCP server

Use a token closure with your own OAuth client or the optional `MCPSignIn`
helpers. The connector asks for the current token on each new connection.

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

Bind credentials to the intended server/resource, authorization server,
client and account. A kit ID alone is not enough. Keep tokens out of
workflow JSON, prompts, records and logs; do not substitute an unrelated API key.

<a name="sign-in-building-blocks"></a>

### 🔐 Sign in, step by step

| Step | SDK helper | Your responsibility |
| --- | --- | --- |
| Discover | `discover` or a trusted `Plan` | Trust the endpoints and scopes |
| Identify the client | `Client(id:)` or `register` | Register dynamically only if supported |
| Authorize | `start` creates PKCE S256 + state | Present the URL; retain this attempt |
| Receive the callback | `finish` checks state and exchanges the code | Validate the redirect URI and authorization server |
| Store | Codable `Tokens` | Secure storage bound to the correct account |
| Refresh | `refresh`, `isExpired` | Serialize refresh per credential set |

`isExpired` includes a 60-second margin. Refresh preserves the old refresh
token when no replacement is returned. External OAuth credentials can also
initialize `Tokens`.

The connector neither opens a browser nor refreshes tokens. Missing tokens
or HTTP 401 produce `MCPError.needsSignIn`; execution retains it under
`RelayError.operationFailed` with `.authenticationRequired`.
Inspect `failure.rootCause as? MCPError` for its challenge.

> ⚠️ A successful sign-in is not permission to replay earlier workflow writes.

<a name="compatibility-limits"></a>

### 📣 Know the connector's scope

| Supported | Not provided |
| --- | --- |
| Tool listing/calls over Streamable HTTP; initial protocol `2025-06-18` | MCP resources, prompts or stdio |
| Mapping tool schemas to ModelRelay fields | Arbitrary JSON Schema support |
| OAuth building blocks | Full authorization-spec conformance |
| A fresh connection per connecting step | Connection pooling |

OAuth helpers lack validated issuer/mix-up protection, Client ID Metadata
Documents and scope-upgrade orchestration. Discovery retains legacy same-origin
endpoint fallbacks. Supply a suitable OAuth client if you need those guarantees.

You can implement `ToolServerConnector` to manage connection lifetime.
Isolate any pool by server, account and authorization changes, not just kit ID.

<a name="product-boundaries"></a>

## 📦 Keep the dependency small

Choose products from one package. HTTP, decisions and MCP use the core and
Apple frameworks; general cloud providers come from AnyLanguageModel.

MLX needs both its product and `traits: ["MLX"]`. SwiftPM may still resolve
unused optional dependencies; selecting products controls compilation/linking,
not complete resolution isolation.
[Changes from older versions →](NativeRuntimeMigration.md)
