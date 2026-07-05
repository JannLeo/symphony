defmodule SymphonyElixir.Hermes.Registry do
  @moduledoc """
  In-memory registry of Tailscale nodes that are reachable as Hermes agents.
  """

  use GenServer

  alias SymphonyElixir.Hermes.Client
  alias SymphonyElixir.Hermes.Tailscale

  @default_refresh_interval_ms 10_000
  @default_port 8765
  @default_probe_timeout_ms 1_000
  @default_task_submit_timeout_ms 5_000
  @default_max_probe_concurrency 8

  @type error :: %{code: String.t(), message: String.t()}
  @type registry_node :: map()
  @type snapshot :: %{
          generated_at: String.t(),
          nodes: [registry_node()],
          counts: map(),
          error: nil | error(),
          last_submission: nil | map()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if is_nil(name), do: [], else: [name: name]

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__) do
    GenServer.call(server, :refresh, :infinity)
  end

  @spec submit_task(GenServer.server(), [String.t()], map()) :: map()
  def submit_task(server \\ __MODULE__, target_ids, task)
      when is_list(target_ids) and is_map(task) do
    GenServer.call(server, {:submit_task, target_ids, task}, :infinity)
  end

  @impl true
  def init(opts) do
    state = %{
      discovery: Keyword.get(opts, :discovery, Tailscale),
      client: Keyword.get(opts, :client, Client),
      discovery_opts: Keyword.get(opts, :discovery_opts, []),
      client_opts: Keyword.get(opts, :client_opts, []),
      port: Keyword.get(opts, :port, @default_port),
      probe_timeout_ms: Keyword.get(opts, :probe_timeout_ms, @default_probe_timeout_ms),
      task_submit_timeout_ms: Keyword.get(opts, :task_submit_timeout_ms, @default_task_submit_timeout_ms),
      max_probe_concurrency: Keyword.get(opts, :max_probe_concurrency, @default_max_probe_concurrency),
      refresh_interval_ms: Keyword.get(opts, :refresh_interval_ms, @default_refresh_interval_ms),
      snapshot: new_snapshot([])
    }

    schedule_refresh(state.refresh_interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state.snapshot, state}
  end

  def handle_call(:refresh, _from, state) do
    {:reply, :ok, do_refresh(state)}
  end

  def handle_call({:submit_task, target_ids, task}, _from, state) do
    {reply, next_state} = do_submit_task(state, target_ids, task)

    {:reply, reply, next_state}
  end

  @impl true
  def handle_info(:refresh, state) do
    next_state = do_refresh(state)
    schedule_refresh(next_state.refresh_interval_ms)

    {:noreply, next_state}
  end

  defp do_refresh(state) do
    case state.discovery.discover(state.discovery_opts) do
      {:ok, nodes} ->
        snapshot =
          nodes
          |> probe_nodes(state)
          |> new_snapshot()

        %{state | snapshot: %{snapshot | last_submission: state.snapshot.last_submission}}

      {:error, error} ->
        %{state | snapshot: %{state.snapshot | generated_at: now_iso8601(), error: normalize_error(error)}}
    end
  end

  defp probe_nodes(nodes, state) do
    client_opts = probe_client_opts(state)

    nodes
    |> Task.async_stream(
      fn node -> Map.put(node, :hermes, probe_node(node, state.client, client_opts)) end,
      max_concurrency: state.max_probe_concurrency,
      timeout: state.probe_timeout_ms + 500,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, node} -> node
      {:exit, _reason} -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp probe_node(%{ip: ip}, client, client_opts) when is_binary(ip) do
    case client.health(ip, client_opts) do
      {:ok, health} ->
        status = status_for(client, ip, client_opts)
        state = Map.get(status, :state) || Map.get(status, "state")

        %{
          available: true,
          ready: ready_state?(state),
          busy: busy_state?(state),
          version: Map.get(health, :version),
          node_id: Map.get(health, :node_id),
          state: state,
          current_task: Map.get(status, :current_task) || Map.get(status, "current_task"),
          error: nil
        }

      {:error, error} ->
        hermes_unavailable(error)
    end
  end

  defp probe_node(_node, _client, _client_opts) do
    hermes_unavailable(%{code: "missing_ip", message: "Node has no Tailscale IP"})
  end

  defp status_for(client, ip, client_opts) do
    case client.status(ip, client_opts) do
      {:ok, status} -> status
      {:error, _error} -> %{}
    end
  end

  defp do_submit_task(state, target_ids, task) do
    nodes_by_id = Map.new(state.snapshot.nodes, &{&1.id, &1})

    results =
      Map.new(target_ids, fn target_id ->
        {target_id, submit_to_target(Map.get(nodes_by_id, target_id), state, task)}
      end)

    submission = %{
      generated_at: now_iso8601(),
      target_ids: target_ids,
      task: task,
      results: results
    }

    reply = %{submitted_at: submission.generated_at, results: results}
    next_state = %{state | snapshot: %{state.snapshot | last_submission: submission}}

    {reply, next_state}
  end

  defp submit_to_target(nil, _state, _task) do
    {:error, %{code: "not_found", message: "Node was not found"}}
  end

  defp submit_to_target(%{hermes: %{ready: true}, ip: ip}, state, task) do
    state.client.submit_task(ip, task, submit_client_opts(state))
  end

  defp submit_to_target(_node, _state, _task) do
    {:error, %{code: "not_ready", message: "Node is not Hermes-ready"}}
  end

  defp new_snapshot(nodes) do
    %{
      generated_at: now_iso8601(),
      nodes: nodes,
      counts: counts(nodes),
      error: nil,
      last_submission: nil
    }
  end

  defp counts(nodes) do
    %{
      total: length(nodes),
      online: Enum.count(nodes, &(&1[:tailscale_online] == true)),
      hermes_ready: Enum.count(nodes, &(get_in(&1, [:hermes, :ready]) == true)),
      busy: Enum.count(nodes, &(get_in(&1, [:hermes, :busy]) == true))
    }
  end

  defp probe_client_opts(state) do
    state.client_opts
    |> Keyword.put_new(:port, state.port)
    |> Keyword.put(:timeout, state.probe_timeout_ms)
  end

  defp submit_client_opts(state) do
    state.client_opts
    |> Keyword.put_new(:port, state.port)
    |> Keyword.put(:timeout, state.task_submit_timeout_ms)
  end

  defp hermes_unavailable(error) do
    %{available: false, ready: false, busy: false, error: normalize_error(error)}
  end

  defp ready_state?(state), do: state in [nil, "idle", :idle, "ready", :ready]
  defp busy_state?(state), do: state in ["busy", :busy, "running", :running]

  defp normalize_error(%{code: code, message: message}) do
    %{code: to_string(code), message: to_string(message)}
  end

  defp normalize_error(reason) do
    %{code: "error", message: inspect(reason)}
  end

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp schedule_refresh(false), do: :ok
  defp schedule_refresh(nil), do: :ok

  defp schedule_refresh(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :refresh, interval_ms)
    :ok
  end
end
