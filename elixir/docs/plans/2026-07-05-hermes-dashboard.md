# Hermes Dashboard Implementation Plan

> **For implementer:** Use TDD throughout. Write failing test first. Watch it fail. Then implement.

**Goal:** Build a Hermes board in the Symphony dashboard that discovers Tailscale devices, probes Hermes agents on port 8765, and publishes tasks to selected ready nodes.

**Architecture:** Add a small `SymphonyElixir.Hermes` subsystem: Tailscale discovery, HTTP client, in-memory registry, LiveView page, and JSON controller. Keep Hermes optional and isolated from the existing orchestrator so `/` and `/api/v1/state` continue working unchanged.

**Tech Stack:** Elixir 1.19, OTP GenServer, Phoenix LiveView, Phoenix Controller JSON APIs, Req HTTP client, Jason, ExUnit.

---

## Task 1: Parse Tailscale status JSON

**Files:**
- Create: `lib/symphony_elixir/hermes/tailscale.ex`
- Test: `test/symphony_elixir/hermes/tailscale_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule SymphonyElixir.Hermes.TailscaleTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Hermes.Tailscale

  @json Jason.encode!(%{
          "Self" => %{
            "ID" => "self-id",
            "HostName" => "dashboard-host",
            "DNSName" => "dashboard-host.tailnet.ts.net.",
            "OS" => "linux",
            "TailscaleIPs" => ["100.83.245.24", "fd7a:115c:a1e0::1"],
            "Online" => true,
            "Active" => false,
            "LastSeen" => "0001-01-01T00:00:00Z"
          },
          "Peer" => %{
            "nodekey:abc" => %{
              "ID" => "peer-id",
              "HostName" => "szserver",
              "DNSName" => "szserver.tailnet.ts.net.",
              "OS" => "linux",
              "TailscaleIPs" => ["100.112.35.71", "fd7a:115c:a1e0::2"],
              "Online" => true,
              "Active" => true,
              "LastSeen" => "2026-07-05T04:20:00Z"
            }
          }
        })

  test "parse_status_json returns self and peers with preferred IPv4 addresses" do
    assert {:ok, nodes} = Tailscale.parse_status_json(@json)

    assert [self, peer] = nodes
    assert self.id == "self-id"
    assert self.hostname == "dashboard-host"
    assert self.ip == "100.83.245.24"
    assert self.tailscale_online == true

    assert peer.id == "peer-id"
    assert peer.hostname == "szserver"
    assert peer.ip == "100.112.35.71"
    assert peer.tailscale_active == true
  end

  test "parse_status_json rejects malformed JSON" do
    assert {:error, :invalid_json} = Tailscale.parse_status_json("not-json")
  end
end
```

**Step 2: Run test — confirm it fails**

Command: `mix test test/symphony_elixir/hermes/tailscale_test.exs`

Expected: FAIL — `SymphonyElixir.Hermes.Tailscale` is undefined.

**Step 3: Write minimal implementation**

Create `lib/symphony_elixir/hermes/tailscale.ex` with public specs for:

- `parse_status_json/1`
- `discover/1`

Implementation requirements:

- `parse_status_json/1` decodes JSON with Jason.
- Include `Self` first when present, then all `Peer` values sorted by hostname.
- Prefer IPv4 address from `TailscaleIPs`; fall back to first address.
- Return maps with keys: `:id`, `:hostname`, `:dns_name`, `:os`, `:ip`, `:tailscale_online`, `:tailscale_active`, `:last_seen_at`.
- `discover/1` shells out through `System.cmd/3` using configurable command defaulting to `tailscale status --json` and returns `{:ok, nodes}` or `{:error, %{code: ..., message: ...}}`.

**Step 4: Run test — confirm it passes**

Command: `mix test test/symphony_elixir/hermes/tailscale_test.exs`

Expected: PASS.

**Step 5: Commit**

`git add lib/symphony_elixir/hermes/tailscale.ex test/symphony_elixir/hermes/tailscale_test.exs && git commit -m "feat: parse tailscale devices for Hermes"`

---

## Task 2: Add Hermes HTTP client

**Files:**
- Create: `lib/symphony_elixir/hermes/client.ex`
- Test: `test/symphony_elixir/hermes/client_test.exs`

**Step 1: Write the failing test**

Use a small test HTTP server or `Req.Test` if available in the installed Req version. Cover response normalization rather than network behavior when possible.

Required tests:

```elixir
defmodule SymphonyElixir.Hermes.ClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Hermes.Client

  test "health_payload accepts Hermes health response" do
    assert {:ok, health} =
             Client.normalize_health(%{
               "ok" => true,
               "service" => "hermes",
               "version" => "0.1.0",
               "node_id" => "szserver"
             })

    assert health.version == "0.1.0"
    assert health.node_id == "szserver"
  end

  test "health_payload rejects non-Hermes response" do
    assert {:error, %{code: "not_hermes"}} = Client.normalize_health(%{"ok" => true})
  end

  test "task response accepts queued task" do
    assert {:ok, result} =
             Client.normalize_task_response(%{
               "accepted" => true,
               "task_id" => "task_123",
               "state" => "queued"
             })

    assert result.task_id == "task_123"
    assert result.state == "queued"
  end
end
```

**Step 2: Run test — confirm it fails**

Command: `mix test test/symphony_elixir/hermes/client_test.exs`

Expected: FAIL — client module/functions undefined.

**Step 3: Write minimal implementation**

Create `SymphonyElixir.Hermes.Client` with specs for:

- `health/2`
- `status/2`
- `submit_task/3`
- `normalize_health/1`
- `normalize_status/1`
- `normalize_task_response/1`

Implementation requirements:

- Endpoint builder uses `http://#{ip}:#{port}`.
- Defaults: port `8765`, health timeout `1_000`, task timeout `5_000`.
- Use `Req.get/2` and `Req.post/2`.
- Normalize timeout/refused/non-2xx/malformed JSON to `{:error, %{code: string, message: string}}`.
- Never raise on network failures.

**Step 4: Run test — confirm it passes**

Command: `mix test test/symphony_elixir/hermes/client_test.exs`

Expected: PASS.

**Step 5: Commit**

`git add lib/symphony_elixir/hermes/client.ex test/symphony_elixir/hermes/client_test.exs && git commit -m "feat: add Hermes HTTP client"`

---

## Task 3: Add Hermes registry process

**Files:**
- Create: `lib/symphony_elixir/hermes/registry.ex`
- Modify: `lib/symphony_elixir.ex`
- Test: `test/symphony_elixir/hermes/registry_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule SymphonyElixir.Hermes.RegistryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Hermes.Registry

  defmodule DiscoveryStub do
    def discover(_opts) do
      {:ok,
       [
         %{
           id: "node-1",
           hostname: "szserver",
           dns_name: "szserver.tailnet.ts.net.",
           os: "linux",
           ip: "100.112.35.71",
           tailscale_online: true,
           tailscale_active: true,
           last_seen_at: nil
         }
       ]}
    end
  end

  defmodule ClientStub do
    def health("100.112.35.71", _opts), do: {:ok, %{version: "0.1.0", node_id: "szserver"}}
    def status("100.112.35.71", _opts), do: {:ok, %{state: "idle", current_task: nil}}
  end

  test "refresh builds a snapshot with Hermes-ready nodes" do
    {:ok, pid} =
      Registry.start_link(
        name: nil,
        discovery: DiscoveryStub,
        client: ClientStub,
        refresh_interval_ms: false
      )

    assert :ok = Registry.refresh(pid)
    assert %{nodes: [node], counts: counts} = Registry.snapshot(pid)
    assert node.hermes.available == true
    assert node.hermes.version == "0.1.0"
    assert counts.hermes_ready == 1
  end
end
```

**Step 2: Run test — confirm it fails**

Command: `mix test test/symphony_elixir/hermes/registry_test.exs`

Expected: FAIL — registry module undefined.

**Step 3: Write minimal implementation**

Create a GenServer with public specs for:

- `start_link/1`
- `snapshot/1`
- `refresh/1`
- `submit_task/3`

Implementation requirements:

- Accept injectable `:discovery` and `:client` modules for tests.
- Store `%{generated_at: iso8601, nodes: list, counts: map, error: nil | map, last_submission: nil | map}`.
- On refresh, call discovery then probe each node. Keep concurrency bounded with `Task.async_stream/3` using `max_concurrency` default `8`.
- If discovery fails and a previous snapshot exists, keep previous nodes and set `error`.
- `submit_task/3` sends to only requested node IDs that are Hermes-ready.
- Return per-node success/error results.

Modify `SymphonyElixir.Application` children to include `SymphonyElixir.Hermes.Registry` after PubSub/Task.Supervisor and before dashboard processes.

**Step 4: Run test — confirm it passes**

Command: `mix test test/symphony_elixir/hermes/registry_test.exs`

Expected: PASS.

**Step 5: Commit**

`git add lib/symphony_elixir.ex lib/symphony_elixir/hermes/registry.ex test/symphony_elixir/hermes/registry_test.exs && git commit -m "feat: track Hermes node registry"`

---

## Task 4: Add Hermes JSON API routes

**Files:**
- Create: `lib/symphony_elixir_web/controllers/hermes_api_controller.ex`
- Modify: `lib/symphony_elixir_web/router.ex`
- Test: `test/symphony_elixir/hermes_api_controller_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule SymphonyElixirWeb.HermesApiControllerTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias SymphonyElixirWeb.Router

  test "GET /api/v1/hermes/nodes is routed before issue catch-all" do
    conn = conn(:get, "/api/v1/hermes/nodes") |> Router.call([])
    assert conn.status in [200, 503]
    refute conn.status == 404
  end

  test "POST /api/v1/hermes/tasks requires title and prompt" do
    conn =
      conn(:post, "/api/v1/hermes/tasks", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert conn.status == 400
  end
end
```

**Step 2: Run test — confirm it fails**

Command: `mix test test/symphony_elixir/hermes_api_controller_test.exs`

Expected: FAIL — route/controller missing.

**Step 3: Write minimal implementation**

Create `SymphonyElixirWeb.HermesApiController` with public specs for:

- `nodes/2`
- `submit_task/2`
- `method_not_allowed/2`

Implementation requirements:

- `GET /api/v1/hermes/nodes` returns `Registry.snapshot/1`.
- `POST /api/v1/hermes/tasks` requires JSON body keys: `target_ids`, `title`, `prompt`.
- Reject missing/empty title/prompt/targets with 400.
- Call `Registry.submit_task/3` and return 202 with result payload.
- Define routes before `get("/api/v1/:issue_identifier", ...)`.

**Step 4: Run test — confirm it passes**

Command: `mix test test/symphony_elixir/hermes_api_controller_test.exs`

Expected: PASS.

**Step 5: Commit**

`git add lib/symphony_elixir_web/controllers/hermes_api_controller.ex lib/symphony_elixir_web/router.ex test/symphony_elixir/hermes_api_controller_test.exs && git commit -m "feat: expose Hermes dashboard API"`

---

## Task 5: Add Hermes LiveView page

**Files:**
- Create: `lib/symphony_elixir_web/live/hermes_live.ex`
- Modify: `lib/symphony_elixir_web/router.ex`
- Modify: `priv/static/dashboard.css`
- Test: `test/symphony_elixir/hermes_live_test.exs`

**Step 1: Write the failing test**

```elixir
defmodule SymphonyElixirWeb.HermesLiveTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  test "Hermes page renders board title" do
    {:ok, _view, html} = live(Phoenix.ConnTest.build_conn(), "/hermes")
    assert html =~ "Hermes"
    assert html =~ "Tailscale"
  end
end
```

**Step 2: Run test — confirm it fails**

Command: `mix test test/symphony_elixir/hermes_live_test.exs`

Expected: FAIL — `/hermes` route missing.

**Step 3: Write minimal implementation**

Create `SymphonyElixirWeb.HermesLive`:

- `mount/3` loads `Registry.snapshot/1`.
- Subscribe to dashboard updates if connected.
- Render:
  - summary cards,
  - nodes table,
  - checkbox per Hermes-ready node,
  - title input,
  - prompt textarea,
  - submit button,
  - last submission results.
- `handle_event("submit_task", params, socket)` validates inputs and calls `Registry.submit_task/3`.

Modify router:

- `live("/hermes", HermesLive, :index)` in the browser scope.

Modify CSS minimally:

- Reuse existing dashboard classes where possible.
- Add only Hermes-specific styles that are needed for selection/results states.

**Step 4: Run test — confirm it passes**

Command: `mix test test/symphony_elixir/hermes_live_test.exs`

Expected: PASS.

**Step 5: Commit**

`git add lib/symphony_elixir_web/live/hermes_live.ex lib/symphony_elixir_web/router.ex priv/static/dashboard.css test/symphony_elixir/hermes_live_test.exs && git commit -m "feat: add Hermes dashboard page"`

---

## Task 6: Add navigation and final regression coverage

**Files:**
- Modify: `lib/symphony_elixir_web/live/dashboard_live.ex`
- Modify: `lib/symphony_elixir_web/live/hermes_live.ex`
- Modify: `test/symphony_elixir/observability_pubsub_test.exs` only if PubSub behavior changes
- Test: existing relevant tests

**Step 1: Write the failing test**

Add or extend a LiveView/render test that asserts the operations dashboard includes a link to `/hermes`.

```elixir
test "operations dashboard links to Hermes board" do
  {:ok, _view, html} = live(Phoenix.ConnTest.build_conn(), "/")
  assert html =~ ~s(href="/hermes")
end
```

**Step 2: Run test — confirm it fails**

Command: `mix test test/symphony_elixir/hermes_live_test.exs`

Expected: FAIL — link missing.

**Step 3: Write minimal implementation**

- Add a small navigation link in the dashboard header: `Hermes Board` -> `/hermes`.
- Add reciprocal link from Hermes page back to `/`.
- Ensure existing operations dashboard content remains unchanged otherwise.

**Step 4: Run targeted tests**

Commands:

- `mix test test/symphony_elixir/hermes/tailscale_test.exs`
- `mix test test/symphony_elixir/hermes/client_test.exs`
- `mix test test/symphony_elixir/hermes/registry_test.exs`
- `mix test test/symphony_elixir/hermes_api_controller_test.exs`
- `mix test test/symphony_elixir/hermes_live_test.exs`

Expected: PASS.

**Step 5: Run project gates**

Commands:

- `mix format --check-formatted`
- `mix specs.check`
- `mix credo --strict`
- `mix test`

Expected: PASS. If coverage threshold fails because new web modules are not in the coverage ignore list, either add meaningful tests until covered or add intentionally UI-only modules to the existing ignore list with justification in the commit message.

**Step 6: Commit**

`git add lib/symphony_elixir_web/live/dashboard_live.ex lib/symphony_elixir_web/live/hermes_live.ex test/symphony_elixir/hermes_live_test.exs && git commit -m "feat: link Hermes board from dashboard"`

---

## Final validation

Before handoff, run:

```bash
make all
```

Expected: all formatting, lint, coverage, and dialyzer gates pass.

Manual smoke check if a local server is available:

1. Start Symphony dashboard.
2. Visit `/` and confirm existing operations dashboard renders.
3. Click `Hermes Board`.
4. Confirm `/hermes` renders Tailscale devices or a friendly Tailscale unavailable state.
5. If a Hermes test node is available on `:8765`, submit a harmless task and confirm per-node delivery results.

## Notes for implementer

- Keep all Hermes behavior optional. The existing orchestrator must not fail if Tailscale or Hermes is unavailable.
- Do not add silent broadcast behavior.
- Do not expand into full persistent task history in this iteration.
- Keep public `def` functions in `lib/` adjacent to `@spec`, per repository rules.
