# Hermes Dashboard Design

## Context

The Symphony Elixir app already exposes a Phoenix/LiveView observability dashboard for orchestration state. The requested feature is a new "Hermes / 爱马仕" dashboard area that discovers machines on the user's private Tailscale network, detects whether a Hermes agent is available on those machines, and provides a central place to publish tasks to selected devices.

Hermes does not yet have a fixed device-side API, so this design defines a minimal HTTP+JSON contract for the first iteration.

## Goals

- Add a Hermes board to the existing Symphony workbench/dashboard.
- Discover candidate devices from local `tailscale status --json` output.
- Probe discovered Tailscale IPv4 addresses for a Hermes service.
- Show a consolidated device board with online/offline/Hermes availability state.
- Allow a user to publish a task to one or more selected Hermes nodes from the dashboard.
- Keep the first version safe: explicit user action, bounded timeouts, clear per-device delivery results, and no silent broadcast.

## Non-goals

- Implement a full distributed scheduler.
- Replace Linear/Symphony's existing issue orchestration flow.
- Require the dashboard to be available for the core Symphony runtime to function.
- Invent privileged remote execution beyond the Hermes API.
- Manage Tailscale ACLs, install Tailscale, or provision Hermes on devices.
- Persist long-term task history in a database in the first iteration.

## Existing project fit

Relevant existing surfaces:

- `SymphonyElixirWeb.Router` hosts the LiveView dashboard at `/` and JSON endpoints under `/api/v1/*`.
- `SymphonyElixirWeb.DashboardLive` renders the current operations dashboard.
- `SymphonyElixirWeb.Presenter` produces dashboard/API payloads from runtime state.
- Static dashboard styling is embedded via `priv/static/dashboard.css` and `StaticAssetController`.

The Hermes feature should be added as an optional observability/control surface, similar in spirit to the current dashboard, and must not become required for normal Symphony issue polling or agent orchestration.

## Considered approaches

### Approach A — Tailscale discovery + Hermes HTTP API (recommended)

The workbench shells out locally to `tailscale status --json`, extracts devices and their Tailscale IPv4 addresses, then probes `http://<ip>:8765/health` for a Hermes agent.

Pros:

- Minimal setup; no central registry required.
- Works with the user's existing Tailscale network.
- Easy to reason about and debug with curl.
- Keeps device-side contract language/runtime neutral.

Cons:

- Requires Hermes to expose an HTTP service on each device.
- Availability depends on Tailscale status being available on the dashboard host.
- Polling many devices requires careful timeout/concurrency limits.

### Approach B — Static configured nodes only

Add Hermes nodes manually to `WORKFLOW.md`, then probe only those nodes.

Pros:

- Deterministic and easy to test.
- Avoids parsing Tailscale status.
- Allows custom labels/ports per device from day one.

Cons:

- Does not satisfy "tailscale 里面的那些 IP 全部加进去" as well.
- Configuration drifts as devices join/leave the tailnet.
- More manual maintenance.

### Approach C — Hermes agents self-register to Symphony

Each Hermes node calls back into Symphony to register itself and receive tasks.

Pros:

- Scales better later.
- Avoids active network scanning.
- Can support NAT/non-Tailscale networks later.

Cons:

- More moving parts and auth design upfront.
- Requires device-side work before the board can show anything useful.
- Higher risk for a first iteration.

Recommendation: start with Approach A, while allowing optional config overrides from Approach B later.

## Hermes device API v1

Default bind/port assumption:

- Hermes listens on Tailscale-reachable HTTP port `8765`.
- The service should bind only to the Tailscale interface/IP or otherwise restrict access to trusted tailnet clients.
- All endpoints use JSON.

### `GET /health`

Purpose: cheap liveness probe.

Success response:

```json
{
  "ok": true,
  "service": "hermes",
  "version": "0.1.0",
  "node_id": "szserver"
}
```

Dashboard interpretation:

- HTTP 200 + `ok: true` + `service: "hermes"` means Hermes is available.
- Timeout, connection refused, non-2xx, or malformed JSON means Hermes is unavailable on that device.

### `GET /status`

Purpose: richer device/task state.

Success response:

```json
{
  "node_id": "szserver",
  "hostname": "szserver",
  "version": "0.1.0",
  "state": "idle",
  "current_task": null,
  "last_seen_at": "2026-07-05T04:31:00Z",
  "capabilities": ["shell", "codex"]
}
```

Allowed `state` values for v1:

- `idle`
- `busy`
- `degraded`
- `offline` should be inferred by the dashboard, not returned by a reachable node.

### `POST /tasks`

Purpose: submit a new task to a Hermes node.

Request:

```json
{
  "title": "执行某个任务",
  "prompt": "具体任务内容",
  "priority": "normal",
  "created_by": "symphony-dashboard",
  "metadata": {
    "source": "hermes-dashboard"
  }
}
```

Success response:

```json
{
  "accepted": true,
  "task_id": "task_01HX...",
  "state": "queued"
}
```

Error response:

```json
{
  "accepted": false,
  "error": {
    "code": "busy",
    "message": "Node is already running a task"
  }
}
```

### `GET /tasks/:id`

Purpose: inspect task state after submission.

Success response:

```json
{
  "task_id": "task_01HX...",
  "state": "running",
  "title": "执行某个任务",
  "started_at": "2026-07-05T04:32:00Z",
  "finished_at": null,
  "summary": null
}
```

### `POST /tasks/:id/cancel`

Purpose: request cancellation.

Success response:

```json
{
  "task_id": "task_01HX...",
  "cancel_requested": true,
  "state": "canceling"
}
```

## Symphony-side architecture

### New modules

- `SymphonyElixir.Hermes.Tailscale`
  - Runs `tailscale status --json` through a controlled command wrapper.
  - Parses self + peer nodes.
  - Extracts hostname, DNS name, OS, IPv4 Tailscale IP, online/active flags, and last-seen fields.
  - Handles missing `tailscale` binary or non-running daemon gracefully.

- `SymphonyElixir.Hermes.Client`
  - Small HTTP client for Hermes endpoints.
  - Uses short per-request timeouts.
  - Normalizes response/error shapes.

- `SymphonyElixir.Hermes.Registry`
  - Maintains an in-memory snapshot of discovered devices and Hermes probe results.
  - Periodically refreshes discovery and status.
  - Exposes synchronous snapshot calls for LiveView/API.
  - Broadcasts dashboard updates via the existing observability PubSub or a Hermes-specific topic.

- `SymphonyElixirWeb.HermesLive`
  - LiveView page for the Hermes board.
  - Renders device cards/table, selection controls, task form, and submission result summary.

- `SymphonyElixirWeb.HermesApiController`
  - Optional JSON API endpoints for automation/testing:
    - `GET /api/v1/hermes/nodes`
    - `POST /api/v1/hermes/tasks`

### Routing

Add browser routes:

- `/` remains the existing operations dashboard.
- `/hermes` opens the Hermes board.

Add API routes:

- `GET /api/v1/hermes/nodes`
- `POST /api/v1/hermes/tasks`

The existing `/api/v1/:issue_identifier` catch-all must not swallow the Hermes API routes; explicit Hermes routes should be defined before the catch-all route.

## Data model

### Discovered node snapshot

```elixir
%{
  id: "nodekey-or-hostname",
  hostname: "szserver",
  dns_name: "szserver.tail80c4f3.ts.net.",
  os: "linux",
  ip: "100.112.35.71",
  tailscale_online: true,
  tailscale_active: true,
  last_seen_at: "2026-07-05T04:20:00Z",
  hermes: %{
    available: true,
    endpoint: "http://100.112.35.71:8765",
    version: "0.1.0",
    state: "idle",
    current_task: nil,
    last_probe_at: "2026-07-05T04:31:00Z",
    error: nil
  }
}
```

### Task submission result

```elixir
%{
  submitted_at: "2026-07-05T04:32:00Z",
  title: "执行某个任务",
  target_count: 2,
  results: [
    %{node_id: "szserver", ok: true, task_id: "task_01HX...", state: "queued"},
    %{node_id: "niuniu", ok: false, error: %{code: "connect_timeout", message: "Timed out"}}
  ]
}
```

## Dashboard interaction

- Top navigation adds a Hermes link from the existing dashboard header area.
- Hermes page sections:
  1. Summary cards: total Tailscale devices, online devices, Hermes-ready devices, busy devices.
  2. Device table/cards: hostname, IP, OS, Tailscale status, Hermes status, current task, last probe.
  3. Task composer: title, prompt, priority, target selection.
  4. Delivery results: per-node accepted/error status after submit.
- The submit button is disabled when no Hermes-ready devices are selected.
- Broadcast/send to all devices should require an explicit "select all ready nodes" action, not be the default.

## Configuration

Initial defaults can be hard-coded in the Hermes modules to keep v1 small:

- `port`: `8765`
- `refresh_interval_ms`: `10_000`
- `probe_timeout_ms`: `1_000`
- `task_submit_timeout_ms`: `5_000`
- `max_probe_concurrency`: `8`

If the implementation already has a clean config pattern available, add an optional `hermes:` block to `WORKFLOW.md` front matter:

```yaml
hermes:
  enabled: true
  port: 8765
  refresh_interval_ms: 10000
  probe_timeout_ms: 1000
  task_submit_timeout_ms: 5000
  max_probe_concurrency: 8
```

The feature should degrade safely if this block is absent.

## Error handling

- Missing `tailscale` binary: show an empty board with a clear "Tailscale unavailable" message.
- Tailscale daemon not running: show the command error, but do not crash the dashboard.
- Malformed Tailscale JSON: log warning and keep the previous good snapshot if available.
- Hermes probe failure: mark only that node's Hermes status as unavailable.
- Task submission partial failure: show per-node results; successful nodes remain successful even if others fail.
- Registry timeout: API returns a structured error instead of blocking indefinitely.

## Security and safety

- v1 assumes the service is reachable only over the user's private tailnet, but the design should not treat that as sufficient forever.
- Do not execute arbitrary dashboard input locally on the Symphony host; tasks are only sent to Hermes nodes.
- Do not automatically publish tasks on page load or discovery.
- Require an explicit form submit for task publication.
- Limit request body size for task submission.
- Log task submissions with target hostnames/IPs and outcome, but avoid logging secrets embedded in prompts.
- Future hardening should add shared-token or mTLS authentication between Symphony and Hermes.

## Testing strategy

- Unit tests for Tailscale JSON parsing:
  - self + peers are included.
  - IPv4 is preferred over IPv6.
  - offline and online fields are preserved.
  - missing/invalid fields are handled safely.
- Unit tests for Hermes client response normalization:
  - healthy response.
  - timeout/refused.
  - malformed JSON.
  - busy/error task response.
- Registry tests using mocked discovery/client modules:
  - snapshot refresh populates nodes.
  - prior snapshot survives transient discovery failure.
  - submit task returns partial success/failure results.
- LiveView tests:
  - Hermes page renders empty/unavailable state.
  - Hermes-ready nodes are selectable.
  - submit action calls the backend and displays delivery results.
- Router/API tests:
  - `/hermes` returns the LiveView page.
  - Hermes API routes are not captured by `/api/v1/:issue_identifier`.

## Acceptance criteria

- Visiting `/hermes` shows Tailscale-discovered devices when Tailscale is available.
- Devices with Hermes listening on port `8765` show as Hermes-ready.
- Devices without Hermes show as discovered but unavailable for task submission.
- User can select one or more ready nodes, enter a title/prompt, and submit a task.
- The dashboard shows per-device delivery results.
- Existing `/` dashboard and `/api/v1/state` behavior remain unchanged.
- If Tailscale is unavailable, the Hermes page shows a friendly unavailable state instead of crashing.

## Open questions for later

- Should Hermes require a shared secret from v1, or is tailnet-only acceptable for the first private iteration?
- Should task history be persisted across Symphony restarts?
- Should nodes be grouped by owner, OS, location, or capability?
- Should Hermes support streaming logs back to the dashboard?
- Should task publication integrate with existing Symphony issue/session primitives or remain separate?
