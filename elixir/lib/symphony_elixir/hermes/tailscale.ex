defmodule SymphonyElixir.Hermes.Tailscale do
  @moduledoc """
  Tailscale device discovery for Hermes nodes.
  """

  @type t :: %{
          id: String.t() | nil,
          hostname: String.t() | nil,
          dns_name: String.t() | nil,
          os: String.t() | nil,
          ip: String.t() | nil,
          tailscale_online: boolean() | nil,
          tailscale_active: boolean() | nil,
          last_seen_at: String.t() | nil
        }

  @type error :: %{code: String.t(), message: String.t()}

  @spec parse_status_json(String.t()) :: {:ok, [t()]} | {:error, :invalid_json}
  def parse_status_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, status} when is_map(status) ->
        {:ok, nodes_from_status(status)}

      {:ok, _other} ->
        {:ok, []}

      {:error, _reason} ->
        {:error, :invalid_json}
    end
  end

  @spec discover(keyword()) :: {:ok, [t()]} | {:error, error()}
  def discover(opts \\ []) when is_list(opts) do
    {command, args} = command_from_opts(opts)
    cmd_opts = Keyword.get(opts, :cmd_opts, stderr_to_stdout: true)

    case System.cmd(command, args, cmd_opts) do
      {json, 0} ->
        case parse_status_json(json) do
          {:ok, nodes} -> {:ok, nodes}
          {:error, :invalid_json} -> {:error, %{code: "invalid_json", message: "Invalid Tailscale status JSON"}}
        end

      {message, exit_status} ->
        {:error,
         %{
           code: "tailscale_status_failed",
           message: error_message(message, exit_status)
         }}
    end
  rescue
    exception in ErlangError ->
      {:error, %{code: "tailscale_status_failed", message: Exception.message(exception)}}
  end

  defp error_message(message, exit_status) do
    case String.trim(message) do
      "" -> "tailscale status failed with exit #{exit_status}"
      trimmed -> trimmed
    end
  end

  defp command_from_opts(opts) do
    case Keyword.get(opts, :command, {"tailscale", ["status", "--json"]}) do
      {command, args} when is_binary(command) and is_list(args) ->
        {command, args}

      [command | args] when is_binary(command) ->
        {command, args}

      command when is_binary(command) ->
        [executable | args] = String.split(command)
        {executable, args}
    end
  end

  defp nodes_from_status(status) do
    self_nodes =
      case Map.get(status, "Self") do
        self when is_map(self) -> [node_from_map(self)]
        _other -> []
      end

    peer_nodes =
      status
      |> Map.get("Peer", %{})
      |> peer_values()
      |> Enum.sort_by(&(&1["HostName"] || ""))
      |> Enum.map(&node_from_map/1)

    self_nodes ++ peer_nodes
  end

  defp peer_values(peers) when is_map(peers), do: Map.values(peers)
  defp peer_values(_peers), do: []

  defp node_from_map(device) do
    %{
      id: Map.get(device, "ID"),
      hostname: Map.get(device, "HostName"),
      dns_name: Map.get(device, "DNSName"),
      os: Map.get(device, "OS"),
      ip: preferred_ip(Map.get(device, "TailscaleIPs", [])),
      tailscale_online: Map.get(device, "Online"),
      tailscale_active: Map.get(device, "Active"),
      last_seen_at: Map.get(device, "LastSeen")
    }
  end

  defp preferred_ip(ips) when is_list(ips) do
    Enum.find(ips, &ipv4?/1) || List.first(ips)
  end

  defp preferred_ip(_ips), do: nil

  defp ipv4?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {_a, _b, _c, _d}} -> true
      _other -> false
    end
  end

  defp ipv4?(_ip), do: false
end
