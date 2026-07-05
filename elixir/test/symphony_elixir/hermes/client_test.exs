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

  test "normalize_status accepts map status payload" do
    assert {:ok, status} = Client.normalize_status(%{"ready" => true, "state" => "idle"})

    assert status.ready == true
    assert status.state == "idle"
  end
end
