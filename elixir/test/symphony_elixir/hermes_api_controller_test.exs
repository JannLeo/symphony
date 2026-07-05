defmodule SymphonyElixirWeb.HermesApiControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixir.Hermes.Registry
  alias SymphonyElixirWeb.{Endpoint, Router}

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

  test "GET /api/v1/hermes/nodes is routed before issue catch-all" do
    conn = conn(:get, "/api/v1/hermes/nodes") |> Router.call([])

    assert conn.status in [200, 503]
    refute conn.status == 404
  end

  test "POST /api/v1/hermes/tasks requires title, prompt, and target_ids" do
    cases = [
      {%{}, "missing_title"},
      {%{title: "Run task", prompt: "Do it"}, "missing_target_ids"},
      {%{title: "Run task", target_ids: ["node-1"]}, "missing_prompt"},
      {%{prompt: "Do it", target_ids: ["node-1"]}, "missing_title"},
      {%{title: "", prompt: "Do it", target_ids: ["node-1"]}, "missing_title"},
      {%{title: "Run task", prompt: "", target_ids: ["node-1"]}, "missing_prompt"},
      {%{title: "Run task", prompt: "Do it", target_ids: []}, "missing_target_ids"}
    ]

    for {body, code} <- cases do
      conn =
        conn(:post, "/api/v1/hermes/tasks", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> Endpoint.call([])

      assert conn.status == 400
      assert %{"error" => %{"code" => ^code}} = Jason.decode!(conn.resp_body)
    end
  end

  test "POST /api/v1/hermes/tasks rejects malformed JSON through endpoint" do
    conn =
      conn(:post, "/api/v1/hermes/tasks", ~s({"title"))
      |> put_req_header("content-type", "application/json")
      |> Endpoint.call([])

    assert conn.status == 400
    assert %{"error" => %{"code" => "invalid_json"}} = Jason.decode!(conn.resp_body)
  end

  test "POST /api/v1/hermes/tasks rejects top-level non-object JSON" do
    for body <- [[], ["node-1"]] do
      conn =
        conn(:post, "/api/v1/hermes/tasks", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> Endpoint.call([])

      assert conn.status == 400
      assert %{"error" => %{"code" => "invalid_json"}} = Jason.decode!(conn.resp_body)
    end
  end

  test "POST /api/v1/hermes/tasks rejects invalid target_ids" do
    for target_ids <- ["node-1", nil, [""], ["node-1", "  "], [123], ["node-1", 123]] do
      conn =
        conn(:post, "/api/v1/hermes/tasks", Jason.encode!(%{target_ids: target_ids, title: "Run task", prompt: "Do it"}))
        |> put_req_header("content-type", "application/json")
        |> Endpoint.call([])

      assert conn.status == 400
      assert %{"error" => %{"code" => "missing_target_ids"}} = Jason.decode!(conn.resp_body)
    end
  end

  test "unsupported Hermes API methods return method_not_allowed" do
    for {method, path} <- [
          {:post, "/api/v1/hermes/nodes"},
          {:put, "/api/v1/hermes/nodes"},
          {:get, "/api/v1/hermes/tasks"},
          {:put, "/api/v1/hermes/tasks"},
          {:delete, "/api/v1/hermes/tasks"}
        ] do
      conn = conn(method, path) |> Router.call([])

      assert conn.status == 405
      assert %{"error" => %{"code" => "method_not_allowed"}} = Jason.decode!(conn.resp_body)
    end
  end

  test "GET /api/v1/hermes/nodes returns structured error when registry is unavailable" do
    put_endpoint_config(:hermes_registry, :missing_hermes_registry)

    conn = conn(:get, "/api/v1/hermes/nodes") |> Router.call([])

    assert conn.status == 503
    assert %{"error" => %{"code" => "registry_unavailable"}} = Jason.decode!(conn.resp_body)
  end

  test "POST /api/v1/hermes/tasks returns structured error when registry is unavailable" do
    put_endpoint_config(:hermes_registry, :missing_hermes_registry)

    conn =
      conn(:post, "/api/v1/hermes/tasks", Jason.encode!(%{target_ids: ["node-1"], title: "Run task", prompt: "Do it"}))
      |> put_req_header("content-type", "application/json")
      |> Endpoint.call([])

    assert conn.status == 503
    assert %{"error" => %{"code" => "registry_unavailable"}} = Jason.decode!(conn.resp_body)
  end

  test "valid POST /api/v1/hermes/tasks submits task to registry" do
    {:ok, registry} =
      Registry.start_link(
        name: nil,
        discovery: DiscoveryStub,
        client: ClientStub,
        client_opts: [test_pid: self()],
        refresh_interval_ms: false
      )

    :ok = Registry.refresh(registry)
    put_endpoint_config(:hermes_registry, registry)

    conn =
      conn(
        :post,
        "/api/v1/hermes/tasks",
        Jason.encode!(%{target_ids: ["node-1"], title: "Run task", prompt: "Do it"})
      )
      |> put_req_header("content-type", "application/json")
      |> Endpoint.call([])

    assert conn.status == 202
    assert %{"results" => %{"node-1" => %{"task_id" => "task-1"}}} = Jason.decode!(conn.resp_body)
    assert_received {:submitted_task, %{title: "Run task", prompt: "Do it"}}
  end

  defp put_endpoint_config(key, value) do
    config = Application.get_env(:symphony_elixir, Endpoint, [])
    Application.put_env(:symphony_elixir, Endpoint, Keyword.put(config, key, value))
  end
end
