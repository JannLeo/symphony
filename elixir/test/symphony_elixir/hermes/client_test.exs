defmodule SymphonyElixir.Hermes.ClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Hermes.Client

  test "normalize_health accepts Hermes health response" do
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

  test "normalize_health rejects non-Hermes response" do
    assert {:error, %{code: "not_hermes"}} = Client.normalize_health(%{"ok" => true})
  end

  test "normalize_task_response accepts queued task" do
    assert {:ok, result} =
             Client.normalize_task_response(%{
               "accepted" => true,
               "task_id" => "task_123",
               "state" => "queued"
             })

    assert result.task_id == "task_123"
    assert result.state == "queued"
  end

  test "normalize_task_response preserves structured rejection error" do
    assert {:error, %{code: "busy", message: "node is busy"}} =
             Client.normalize_task_response(%{
               "accepted" => false,
               "error" => %{"code" => "busy", "message" => "node is busy"}
             })
  end

  test "normalize_task_response falls back for malformed rejection error" do
    assert {:error, %{code: "task_rejected", message: "Hermes task response was not accepted"}} =
             Client.normalize_task_response(%{
               "accepted" => false,
               "error" => %{"code" => "busy"}
             })
  end

  test "submit_task classifies invalid JSON response as malformed_json" do
    response = "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 8\r\n\r\nnot-json"
    port = serve_once(response)

    assert {:error, %{code: "malformed_json", message: "Hermes response was not valid JSON"}} =
             Client.submit_task("127.0.0.1", %{"command" => "ping"}, port: port)

    assert_receive :served_once
  end

  test "normalize_status accepts map status payload" do
    assert {:ok, status} = Client.normalize_status(%{"ready" => true, "state" => "idle"})

    assert status.ready == true
    assert status.state == "idle"
  end

  defp serve_once(response) do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(listen_socket)
    parent = self()

    spawn(fn ->
      {:ok, socket} = :gen_tcp.accept(listen_socket)
      {:ok, _request} = :gen_tcp.recv(socket, 0)
      :ok = :gen_tcp.send(socket, response)
      :ok = :gen_tcp.close(socket)
      :ok = :gen_tcp.close(listen_socket)
      send(parent, :served_once)
    end)

    port
  end
end
