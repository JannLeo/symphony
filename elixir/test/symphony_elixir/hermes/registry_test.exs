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
         },
         %{
           id: "node-2",
           hostname: "macbook",
           dns_name: "macbook.tailnet.ts.net.",
           os: "macos",
           ip: "100.112.35.72",
           tailscale_online: false,
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
    def health("100.112.35.72", _opts), do: {:error, %{code: "offline", message: "offline"}}

    def status("100.112.35.71", _opts), do: {:ok, %{state: "idle", current_task: nil}}
    def status("100.112.35.72", _opts), do: {:error, %{code: "offline", message: "offline"}}

    def submit_task(ip, task, opts) do
      send(Keyword.fetch!(opts, :parent), {:submitted, ip, task})
      {:ok, %{task_id: "task-for-#{ip}", state: "queued"}}
    end
  end

  defmodule BusyClientStub do
    def health(_ip, _opts), do: {:ok, %{version: "0.1.0", node_id: "busy-node"}}
    def status(_ip, _opts), do: {:ok, %{state: "busy", current_task: %{id: "running"}}}
  end

  defmodule ExplicitNotReadyClientStub do
    def health("100.112.35.71", _opts), do: {:ok, %{version: "0.1.0", node_id: "not-ready-node"}}
    def health("100.112.35.72", _opts), do: {:error, %{code: "offline", message: "offline"}}

    def status("100.112.35.71", _opts), do: {:ok, %{ready: false, current_task: nil}}
    def status("100.112.35.72", _opts), do: {:error, %{code: "offline", message: "offline"}}

    def submit_task(ip, task, opts) do
      send(Keyword.fetch!(opts, :parent), {:submitted, ip, task})
      {:ok, %{task_id: "task-for-#{ip}", state: "queued"}}
    end
  end

  defmodule StatusFailureClientStub do
    def health(_ip, _opts), do: {:ok, %{version: "0.1.0", node_id: "status-failed-node"}}
    def status(_ip, _opts), do: {:error, %{code: "status_timeout", message: "status timed out"}}

    def submit_task(ip, task, opts) do
      send(Keyword.fetch!(opts, :parent), {:submitted, ip, task})
      {:ok, %{task_id: "task-for-#{ip}", state: "queued"}}
    end
  end

  defmodule SlowStatusClientStub do
    def health(_ip, _opts), do: {:ok, %{version: "0.1.0", node_id: "slow-status-node"}}

    def status(_ip, _opts) do
      Process.sleep(800)
      {:ok, %{state: "idle", current_task: nil}}
    end
  end

  test "refresh builds a snapshot with Hermes-ready nodes using injected discovery and client" do
    {:ok, pid} =
      Registry.start_link(
        name: nil,
        discovery: DiscoveryStub,
        client: ClientStub,
        refresh_interval_ms: false
      )

    assert :ok = Registry.refresh(pid)
    assert %{nodes: [ready, offline], counts: counts, error: nil} = Registry.snapshot(pid)

    assert ready.id == "node-1"
    assert ready.hermes.available == true
    assert ready.hermes.ready == true
    assert ready.hermes.version == "0.1.0"
    assert ready.hermes.state == "idle"

    assert offline.id == "node-2"
    assert offline.hermes.available == false
    assert offline.hermes.ready == false

    assert counts.total == 2
    assert counts.online == 1
    assert counts.hermes_ready == 1
    assert counts.busy == 0
  end

  test "snapshot includes counts for busy Hermes nodes" do
    {:ok, pid} =
      Registry.start_link(
        name: nil,
        discovery: DiscoveryStub,
        client: BusyClientStub,
        refresh_interval_ms: false
      )

    assert :ok = Registry.refresh(pid)
    assert %{counts: counts} = Registry.snapshot(pid)

    assert counts.total == 2
    assert counts.online == 1
    assert counts.hermes_ready == 0
    assert counts.busy == 2
  end

  test "submit_task does not send to a node with explicit ready false status" do
    {:ok, pid} =
      Registry.start_link(
        name: nil,
        discovery: DiscoveryStub,
        client: ExplicitNotReadyClientStub,
        client_opts: [parent: self()],
        refresh_interval_ms: false
      )

    assert :ok = Registry.refresh(pid)
    assert %{nodes: [node_1, _offline], counts: counts} = Registry.snapshot(pid)

    assert node_1.hermes.available == true
    assert node_1.hermes.ready == false
    assert node_1.hermes.current_task == nil
    assert counts.hermes_ready == 0

    task = %{title: "Inspect", prompt: "Check the repo"}
    assert %{results: results} = Registry.submit_task(pid, ["node-1"], task)

    assert results["node-1"] == {:error, %{code: "not_ready", message: "Node is not Hermes-ready"}}
    refute_receive {:submitted, _ip, _task}, 20
  end

  test "submit_task sends only to requested Hermes-ready node IDs and returns per-node results" do
    {:ok, pid} =
      Registry.start_link(
        name: nil,
        discovery: DiscoveryStub,
        client: ClientStub,
        client_opts: [parent: self()],
        refresh_interval_ms: false
      )

    assert :ok = Registry.refresh(pid)

    task = %{title: "Inspect", prompt: "Check the repo"}
    assert %{results: results} = Registry.submit_task(pid, ["node-1", "node-2", "missing"], task)

    assert results["node-1"] == {:ok, %{task_id: "task-for-100.112.35.71", state: "queued"}}
    assert results["node-2"] == {:error, %{code: "not_ready", message: "Node is not Hermes-ready"}}
    assert results["missing"] == {:error, %{code: "not_found", message: "Node was not found"}}

    assert_receive {:submitted, "100.112.35.71", ^task}
    refute_receive {:submitted, "100.112.35.72", _task}, 20

    assert %{
             last_submission: %{
               target_ids: ["node-1", "node-2", "missing"],
               results: snapshot_results
             }
           } = Registry.snapshot(pid)

    assert snapshot_results["node-1"] == %{
             node_id: "node-1",
             ok: true,
             task_id: "task-for-100.112.35.71",
             state: "queued"
           }

    assert snapshot_results["node-2"] == %{
             node_id: "node-2",
             ok: false,
             error: %{code: "not_ready", message: "Node is not Hermes-ready"}
           }

    assert snapshot_results["missing"] == %{
             node_id: "missing",
             ok: false,
             error: %{code: "not_found", message: "Node was not found"}
           }
  end

  test "snapshot is JSON encodable after submit_task" do
    {:ok, pid} =
      Registry.start_link(
        name: nil,
        discovery: DiscoveryStub,
        client: ClientStub,
        client_opts: [parent: self()],
        refresh_interval_ms: false
      )

    assert :ok = Registry.refresh(pid)

    task = %{title: "Inspect", prompt: "Check the repo"}
    assert %{results: _results} = Registry.submit_task(pid, ["node-1", "node-2", "missing"], task)

    assert {:ok, _json} = Jason.encode(Registry.snapshot(pid))
  end

  test "submit_task deduplicates target IDs before sending" do
    {:ok, pid} =
      Registry.start_link(
        name: nil,
        discovery: DiscoveryStub,
        client: ClientStub,
        client_opts: [parent: self()],
        refresh_interval_ms: false
      )

    assert :ok = Registry.refresh(pid)

    task = %{title: "Inspect", prompt: "Check the repo"}
    assert %{results: results} = Registry.submit_task(pid, ["node-1", "node-1"], task)

    assert results == %{"node-1" => {:ok, %{task_id: "task-for-100.112.35.71", state: "queued"}}}
    assert_receive {:submitted, "100.112.35.71", ^task}
    refute_receive {:submitted, "100.112.35.71", ^task}, 20

    assert %{last_submission: %{target_ids: ["node-1"], results: snapshot_results}} = Registry.snapshot(pid)

    assert snapshot_results == %{
             "node-1" => %{
               node_id: "node-1",
               ok: true,
               task_id: "task-for-100.112.35.71",
               state: "queued"
             }
           }
  end

  test "submit_task does not send to a node when status probing fails" do
    {:ok, pid} =
      Registry.start_link(
        name: nil,
        discovery: DiscoveryStub,
        client: StatusFailureClientStub,
        client_opts: [parent: self()],
        refresh_interval_ms: false
      )

    assert :ok = Registry.refresh(pid)
    assert %{nodes: [node_1, node_2], counts: counts} = Registry.snapshot(pid)

    assert node_1.hermes.available == true
    assert node_1.hermes.ready == false
    assert node_1.hermes.error == %{code: "status_timeout", message: "status timed out"}
    assert node_2.hermes.available == true
    assert node_2.hermes.ready == false
    assert counts.hermes_ready == 0

    task = %{title: "Inspect", prompt: "Check the repo"}
    assert %{results: results} = Registry.submit_task(pid, ["node-1"], task)

    assert results["node-1"] == {:error, %{code: "not_ready", message: "Node is not Hermes-ready"}}
    refute_receive {:submitted, _ip, _task}, 20
  end

  test "refresh waits long enough for health and status probing before dropping nodes" do
    {:ok, pid} =
      Registry.start_link(
        name: nil,
        discovery: DiscoveryStub,
        client: SlowStatusClientStub,
        probe_timeout_ms: 200,
        refresh_interval_ms: false
      )

    assert :ok = Registry.refresh(pid)
    assert %{nodes: [node_1, node_2], counts: counts} = Registry.snapshot(pid)

    assert node_1.hermes.ready == true
    assert node_2.hermes.ready == true
    assert counts.hermes_ready == 2
  end

  test "discovery failure keeps previous good snapshot and sets an error" do
    {:ok, agent} =
      Agent.start_link(fn ->
        [
          DiscoveryStub.discover([]),
          {:error, %{code: "tailscale_status_failed", message: "tailscale unavailable"}}
        ]
      end)

    {:ok, pid} =
      Registry.start_link(
        name: nil,
        discovery: DiscoverySequenceStub,
        discovery_opts: [agent: agent],
        client: ClientStub,
        refresh_interval_ms: false
      )

    assert :ok = Registry.refresh(pid)
    assert %{nodes: previous_nodes, error: nil} = Registry.snapshot(pid)

    assert :ok = Registry.refresh(pid)

    assert %{
             nodes: ^previous_nodes,
             error: %{code: "tailscale_status_failed", message: "tailscale unavailable"}
           } = Registry.snapshot(pid)
  end
end
