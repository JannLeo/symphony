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
