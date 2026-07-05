defmodule SymphonyElixirWeb.HermesLive do
  @moduledoc """
  Live Hermes board for Tailscale-discovered agent nodes.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias Phoenix.LiveView.Socket
  alias SymphonyElixir.Hermes.Registry
  alias SymphonyElixirWeb.{Endpoint, HermesPubSub}

  @type snapshot_result :: {:ok, map()} | {:error, map()}

  @impl true
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = HermesPubSub.subscribe()
    end

    {:ok,
     socket
     |> assign(:snapshot_result, load_snapshot())
     |> assign(:form, default_form())
     |> assign(:selected_target_ids, [])
     |> assign(:validation_error, nil)
     |> assign(:submission_result, nil)}
  end

  @impl true
  @spec handle_info(:hermes_registry_updated, Socket.t()) :: {:noreply, Socket.t()}
  def handle_info(:hermes_registry_updated, socket) do
    {:noreply, assign(socket, :snapshot_result, load_snapshot())}
  end

  @impl true
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("submit_task", params, socket) do
    form = normalize_form(params)
    selected_target_ids = selected_target_ids(params)

    case validate_submission(socket.assigns.snapshot_result, selected_target_ids, form) do
      {:ok, ready_target_ids, task} ->
        result = submit_task(ready_target_ids, task)

        {:noreply,
         socket
         |> assign(:form, form)
         |> assign(:selected_target_ids, ready_target_ids)
         |> assign(:validation_error, nil)
         |> assign(:submission_result, result)
         |> assign(:snapshot_result, load_snapshot())}

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:form, form)
         |> assign(:selected_target_ids, selected_target_ids)
         |> assign(:validation_error, message)
         |> assign(:submission_result, nil)}
    end
  end

  def handle_event("refresh", _params, socket) do
    refresh_registry()

    {:noreply,
     socket
     |> assign(:snapshot_result, load_snapshot())
     |> assign(:validation_error, nil)}
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell hermes-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Hermes Dashboard</p>
            <h1 class="hero-title">Hermes Board</h1>
            <p class="hero-copy">
              Dispatch tasks to Hermes agents discovered across your Tailscale tailnet, with readiness and delivery feedback in one place.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <button type="button" class="secondary" phx-click="refresh">Refresh</button>
          </div>
        </div>
      </header>

      <%= case @snapshot_result do %>
        <% {:error, error} -> %>
          <section class="error-card">
            <h2 class="error-title">Hermes snapshot unavailable</h2>
            <p class="error-copy">
              <strong><%= error.code %>:</strong> <%= error.message %>
            </p>
          </section>

        <% {:ok, snapshot} -> %>
          <section class="metric-grid">
            <article class="metric-card">
              <p class="metric-label">Tailscale devices</p>
              <p class="metric-value numeric"><%= count(snapshot, :total) %></p>
              <p class="metric-detail">Total devices in the latest registry snapshot.</p>
            </article>

            <article class="metric-card">
              <p class="metric-label">Online devices</p>
              <p class="metric-value numeric"><%= count(snapshot, :online) %></p>
              <p class="metric-detail">Tailscale nodes currently marked online.</p>
            </article>

            <article class="metric-card">
              <p class="metric-label">Hermes-ready</p>
              <p class="metric-value numeric"><%= count(snapshot, :hermes_ready) %></p>
              <p class="metric-detail">Agents ready to accept a task.</p>
            </article>

            <article class="metric-card">
              <p class="metric-label">Busy</p>
              <p class="metric-value numeric"><%= count(snapshot, :busy) %></p>
              <p class="metric-detail">Agents already running work.</p>
            </article>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Tailscale nodes</h2>
                <p class="section-copy">
                  Hostname, IP, OS, Tailscale state, Hermes readiness, current task, and latest probe error.
                </p>
              </div>
            </div>

            <%= if nodes(snapshot) == [] do %>
              <p class="empty-state">No Tailscale devices found.</p>
              <p class="empty-state">Snapshot available, but the registry has not discovered any nodes yet.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table hermes-table">
                  <thead>
                    <tr>
                      <th>Target</th>
                      <th>Host</th>
                      <th>IP / OS</th>
                      <th>Tailscale</th>
                      <th>Hermes</th>
                      <th>Current task</th>
                      <th>Last probe / error</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={node <- nodes(snapshot)}>
                      <td>
                        <%= if ready?(node) do %>
                          <label class="target-checkbox">
                            <input
                              type="checkbox"
                              form="hermes-task-form"
                              name="target_ids[]"
                              value={node_id(node)}
                              checked={node_id(node) in @selected_target_ids}
                            />
                            Select
                          </label>
                        <% else %>
                          <span class="muted">Not ready</span>
                        <% end %>
                      </td>
                      <td>
                        <div class="detail-stack">
                          <span class="issue-id"><%= display(node, :hostname) %></span>
                          <span class="muted"><%= display(node, :dns_name) %></span>
                        </div>
                      </td>
                      <td>
                        <div class="detail-stack">
                          <span class="mono numeric"><%= display(node, :ip) %></span>
                          <span class="muted"><%= display(node, :os) %></span>
                        </div>
                      </td>
                      <td>
                        <div class="detail-stack">
                          <span class={boolean_badge_class(map_get(node, :tailscale_online))}>
                            <%= boolean_label(map_get(node, :tailscale_online), "online", "offline") %>
                          </span>
                          <span class="muted">active: <%= yes_no(map_get(node, :tailscale_active)) %></span>
                        </div>
                      </td>
                      <td>
                        <div class="detail-stack">
                          <span class={hermes_badge_class(node)}><%= hermes_label(node) %></span>
                          <span class="muted"><%= hermes_version(node) %></span>
                        </div>
                      </td>
                      <td><%= current_task(node) %></td>
                      <td>
                        <div class="detail-stack">
                          <span><%= probe_message(node) %></span>
                          <span class="muted mono"><%= display(node, :last_seen_at) %></span>
                        </div>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Task composer</h2>
                <p class="section-copy">Choose Hermes-ready targets above, then send a title and prompt.</p>
              </div>
            </div>

            <form id="hermes-task-form" class="task-form" phx-submit="submit_task">
              <label class="field-label">
                Title
                <input type="text" name="task[title]" value={@form.title} placeholder="Collect logs" />
              </label>

              <label class="field-label">
                Prompt
                <textarea name="task[prompt]" rows="5" placeholder="Describe the work for Hermes..."><%= @form.prompt %></textarea>
              </label>

              <label class="field-label">
                Priority
                <select name="task[priority]">
                  <option value="low" selected={@form.priority == "low"}>Low</option>
                  <option value="normal" selected={@form.priority == "normal"}>Normal</option>
                  <option value="high" selected={@form.priority == "high"}>High</option>
                </select>
              </label>

              <%= if @validation_error do %>
                <p class="form-error"><%= @validation_error %></p>
              <% end %>

              <button type="submit">Submit task</button>
            </form>
          </section>

          <%= if @submission_result do %>
            <section class="section-card">
              <div class="section-header">
                <div>
                  <h2 class="section-title">Delivery results</h2>
                  <p class="section-copy">Latest per-node Hermes submission response.</p>
                </div>
              </div>

              <div class="table-wrap">
                <table class="data-table delivery-table">
                  <thead>
                    <tr>
                      <th>Target</th>
                      <th>Result</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={{target_id, result} <- submission_results(@submission_result)}>
                      <td class="mono"><%= target_id %></td>
                      <td><%= render_delivery_result(result) %></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>
          <% end %>
      <% end %>
    </section>
    """
  end

  @spec load_snapshot() :: snapshot_result()
  defp load_snapshot do
    {:ok, Registry.snapshot(registry())}
  catch
    :exit, _reason -> {:error, %{code: "registry_unavailable", message: "Hermes registry is unavailable"}}
  end

  @spec submit_task([String.t()], map()) :: {:ok, map()} | {:error, map()}
  defp submit_task(target_ids, task) do
    {:ok, Registry.submit_task(registry(), target_ids, task)}
  catch
    :exit, _reason -> {:error, %{code: "registry_unavailable", message: "Hermes registry is unavailable"}}
  end

  @spec refresh_registry() :: :ok
  defp refresh_registry do
    Registry.refresh(registry())
  catch
    :exit, _reason -> :ok
  end

  @spec registry() :: GenServer.server()
  defp registry do
    endpoint_config(:hermes_registry) || Registry
  end

  @spec endpoint_config(atom()) :: term()
  defp endpoint_config(key) do
    case Application.get_env(:symphony_elixir, Endpoint, []) do
      config when is_list(config) -> Keyword.get(config, key)
      _other -> nil
    end
  end

  @spec default_form() :: map()
  defp default_form, do: %{title: "", prompt: "", priority: "normal"}

  @spec normalize_form(map()) :: map()
  defp normalize_form(params) do
    task = Map.get(params, "task", %{})

    %{
      title: task |> Map.get("title", "") |> to_string(),
      prompt: task |> Map.get("prompt", "") |> to_string(),
      priority: task |> Map.get("priority", "normal") |> normalize_priority()
    }
  end

  @spec selected_target_ids(map()) :: [String.t()]
  defp selected_target_ids(params) do
    params
    |> Map.get("target_ids", [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  @spec validate_submission(snapshot_result(), [String.t()], map()) :: {:ok, [String.t()], map()} | {:error, String.t()}
  defp validate_submission(snapshot_result, selected_target_ids, form) do
    ready_ids = ready_ids(snapshot_result)
    ready_target_ids = Enum.filter(selected_target_ids, &(&1 in ready_ids))

    cond do
      String.trim(form.title) == "" ->
        {:error, "Title is required."}

      String.trim(form.prompt) == "" ->
        {:error, "Prompt is required."}

      ready_target_ids == [] ->
        {:error, "Select at least one Hermes-ready node."}

      true ->
        {:ok, ready_target_ids, %{title: String.trim(form.title), prompt: String.trim(form.prompt), priority: form.priority}}
    end
  end

  @spec ready_ids(snapshot_result()) :: [String.t()]
  defp ready_ids({:ok, snapshot}) do
    snapshot
    |> nodes()
    |> Enum.filter(&ready?/1)
    |> Enum.map(&node_id/1)
  end

  defp ready_ids(_snapshot_result), do: []

  @spec normalize_priority(term()) :: String.t()
  defp normalize_priority(priority) when priority in ["low", "normal", "high"], do: priority
  defp normalize_priority(_priority), do: "normal"

  @spec nodes(map()) :: [map()]
  defp nodes(snapshot), do: map_get(snapshot, :nodes) || []

  @spec count(map(), atom()) :: non_neg_integer()
  defp count(snapshot, key), do: snapshot |> map_get(:counts) |> map_get(key) || 0

  @spec node_id(map()) :: String.t()
  defp node_id(node), do: node |> map_get(:id) |> to_string()

  @spec ready?(map()) :: boolean()
  defp ready?(node), do: get_in(node, [:hermes, :ready]) == true or get_in(node, ["hermes", "ready"]) == true

  @spec display(map(), atom()) :: String.t()
  defp display(map, key) do
    case map_get(map, key) do
      nil -> "n/a"
      "" -> "n/a"
      value -> to_string(value)
    end
  end

  @spec map_get(nil | map(), atom()) :: term()
  defp map_get(nil, _key), do: nil
  defp map_get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  @spec boolean_badge_class(term()) :: String.t()
  defp boolean_badge_class(true), do: "state-badge state-badge-active"
  defp boolean_badge_class(_value), do: "state-badge state-badge-danger"

  @spec boolean_label(term(), String.t(), String.t()) :: String.t()
  defp boolean_label(true, truthy, _falsy), do: truthy
  defp boolean_label(_value, _truthy, falsy), do: falsy

  @spec yes_no(term()) :: String.t()
  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
  defp yes_no(_value), do: "n/a"

  @spec hermes_badge_class(map()) :: String.t()
  defp hermes_badge_class(node) do
    cond do
      ready?(node) -> "state-badge state-badge-active"
      get_in(node, [:hermes, :busy]) == true or get_in(node, ["hermes", "busy"]) == true -> "state-badge state-badge-warning"
      true -> "state-badge state-badge-danger"
    end
  end

  @spec hermes_label(map()) :: String.t()
  defp hermes_label(node) do
    hermes = map_get(node, :hermes) || %{}

    cond do
      ready?(node) -> "ready"
      map_get(hermes, :busy) == true -> "busy"
      map_get(hermes, :available) == true -> "unready"
      true -> "unavailable"
    end
  end

  @spec hermes_version(map()) :: String.t()
  defp hermes_version(node) do
    hermes = map_get(node, :hermes) || %{}

    case map_get(hermes, :version) do
      nil -> "version n/a"
      version -> "version #{version}"
    end
  end

  @spec current_task(map()) :: String.t()
  defp current_task(node) do
    hermes = map_get(node, :hermes) || %{}

    case map_get(hermes, :current_task) do
      nil -> "n/a"
      value when is_binary(value) -> value
      value -> inspect(value)
    end
  end

  @spec probe_message(map()) :: String.t()
  defp probe_message(node) do
    hermes = map_get(node, :hermes) || %{}

    case map_get(hermes, :error) do
      nil -> "ok"
      %{code: code, message: message} -> "#{code}: #{message}"
      %{"code" => code, "message" => message} -> "#{code}: #{message}"
      error -> inspect(error)
    end
  end

  @spec submission_results({:ok, map()} | {:error, map()}) :: [{String.t(), term()}]
  defp submission_results({:ok, %{results: results}}) when is_map(results), do: Enum.sort(results)
  defp submission_results({:error, error}), do: [{"registry", {:error, error}}]
  defp submission_results(_result), do: []

  @spec render_delivery_result(term()) :: String.t()
  defp render_delivery_result({:ok, result}) when is_map(result) do
    task_id = map_get(result, :task_id) || "accepted"
    state = map_get(result, :state) || "queued"
    "#{task_id} (#{state})"
  end

  defp render_delivery_result({:error, error}) when is_map(error) do
    "#{map_get(error, :code) || "error"}: #{map_get(error, :message) || inspect(error)}"
  end

  defp render_delivery_result(result) when is_map(result), do: inspect(result)
  defp render_delivery_result(result), do: to_string(result)
end
