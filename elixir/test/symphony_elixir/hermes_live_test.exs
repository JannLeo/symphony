defmodule SymphonyElixirWeb.HermesLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Hermes.Registry
  alias SymphonyElixirWeb.Endpoint

  @endpoint Endpoint

  defmodule EmptyDiscovery do
    def discover(_opts), do: {:ok, []}
  end

  defmodule ReadyDiscovery do
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
           last_seen_at: "2026-07-05T04:20:00Z"
         },
         %{
           id: "node-2",
           hostname: "laptop",
           dns_name: "laptop.tailnet.ts.net.",
           os: "macOS",
           ip: "100.64.0.2",
           tailscale_online: true,
           tailscale_active: false,
           last_seen_at: nil
         }
       ]}
    end
  end

  defmodule DiscoverySequenceStub do
    def discover(opts) do
      opts
      |> Keyword.fetch!(:agent)
      |> Agent.get_and_update(fn [result | rest] -> {result, rest} end)
    end
  end

  defmodule ClientStub do
    def health("100.112.35.71", _opts), do: {:ok, %{version: "0.1.0", node_id: "szserver"}}
    def health("100.64.0.2", _opts), do: {:error, %{code: "refused", message: "connection refused"}}

    def status("100.112.35.71", _opts), do: {:ok, %{state: "idle", current_task: nil, ready: true}}

    def submit_task("100.112.35.71", task, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:submitted_task, task})
      {:ok, %{accepted: true, task_id: "task-1", state: "queued"}}
    end
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])
    start_supervised!(Endpoint)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
    end)

    :ok
  end

  test "GET/live /hermes renders Hermes board title and Tailscale copy" do
    start_registry!(EmptyDiscovery)

    {:ok, _view, html} = live(Phoenix.ConnTest.build_conn(), "/hermes")

    assert html =~ "Hermes Board"
    assert html =~ ~s(href="/")
    assert html =~ "Operations Dashboard"
    assert html =~ "Tailscale"
  end

  test "page renders empty state when registry snapshot has no nodes" do
    start_registry!(EmptyDiscovery)

    {:ok, _view, html} = live(Phoenix.ConnTest.build_conn(), "/hermes")

    assert html =~ "No Tailscale devices found"
    assert html =~ "Snapshot available, but the registry has not discovered any nodes yet."
  end

  test "page renders unavailable state when registry snapshot errors" do
    put_endpoint_config(:hermes_registry, :missing_hermes_registry)

    {:ok, _view, html} = live(Phoenix.ConnTest.build_conn(), "/hermes")

    assert html =~ "Hermes snapshot unavailable"
    assert html =~ "registry_unavailable"
  end

  test "Hermes-ready nodes are selectable and receive submitted tasks" do
    start_registry!(ReadyDiscovery)

    {:ok, view, html} = live(Phoenix.ConnTest.build_conn(), "/hermes")

    assert html =~ "szserver"
    assert html =~ "100.112.35.71"
    assert html =~ ~s(name="target_ids[]")
    assert html =~ ~s(value="node-1")
    refute html =~ ~s(value="node-2" checked)

    result =
      view
      |> form("#hermes-task-form", %{
        "task" => %{"title" => "Collect logs", "prompt" => "Run diagnostics", "priority" => "normal"},
        "target_ids" => ["node-1"]
      })
      |> render_submit()

    assert result =~ "Delivery results"
    assert result =~ "task-1"
    assert_received {:submitted_task, %{title: "Collect logs", prompt: "Run diagnostics", priority: "normal"}}
  end

  test "Hermes board reloads when registry broadcasts an update" do
    {:ok, agent} =
      Agent.start_link(fn ->
        [EmptyDiscovery.discover([]), ReadyDiscovery.discover([])]
      end)

    registry = start_registry!(DiscoverySequenceStub, discovery_opts: [agent: agent])

    {:ok, view, html} = live(Phoenix.ConnTest.build_conn(), "/hermes")

    assert html =~ "No Tailscale devices found"

    :ok = Registry.refresh(registry)

    assert render(view) =~ "szserver"
  end

  test "duplicate selected targets submit only once" do
    start_registry!(ReadyDiscovery)

    {:ok, view, _html} = live(Phoenix.ConnTest.build_conn(), "/hermes")

    result =
      view
      |> form("#hermes-task-form", %{
        "task" => %{"title" => "Collect logs", "prompt" => "Run diagnostics", "priority" => "normal"},
        "target_ids" => ["node-1", "node-1"]
      })
      |> render_submit()

    assert result =~ "Delivery results"
    assert_received {:submitted_task, %{title: "Collect logs", prompt: "Run diagnostics", priority: "normal"}}
    refute_receive {:submitted_task, _task}, 20
  end

  test "submit with no ready target shows validation error" do
    start_registry!(EmptyDiscovery)

    {:ok, view, _html} = live(Phoenix.ConnTest.build_conn(), "/hermes")

    result =
      view
      |> form("#hermes-task-form", %{"task" => %{"title" => "Collect logs", "prompt" => "Run diagnostics"}})
      |> render_submit()

    assert result =~ "Select at least one Hermes-ready node."
  end

  defp start_registry!(discovery, opts \\ []) do
    {:ok, registry} =
      Registry.start_link(
        name: nil,
        discovery: discovery,
        discovery_opts: Keyword.get(opts, :discovery_opts, []),
        client: ClientStub,
        client_opts: [test_pid: self()],
        refresh_interval_ms: false
      )

    :ok = Registry.refresh(registry)
    put_endpoint_config(:hermes_registry, registry)
    registry
  end

  defp put_endpoint_config(key, value) do
    config = Application.get_env(:symphony_elixir, Endpoint, [])
    Application.put_env(:symphony_elixir, Endpoint, Keyword.put(config, key, value))
  end
end
