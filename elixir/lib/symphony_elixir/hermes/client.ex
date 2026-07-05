defmodule SymphonyElixir.Hermes.Client do
  @moduledoc """
  HTTP client for Hermes agents.
  """

  @default_port 8765
  @health_timeout 1_000
  @task_timeout 5_000

  @type error :: %{code: String.t(), message: String.t()}
  @type health :: %{version: String.t() | nil, node_id: String.t() | nil}
  @type task_result :: %{task_id: String.t() | nil, state: String.t() | nil}

  @spec health(String.t(), keyword()) :: {:ok, health()} | {:error, error()}
  def health(ip, opts \\ []) when is_binary(ip) and is_list(opts) do
    ip
    |> endpoint(opts, "/health")
    |> request(:get, nil, timeout(opts, @health_timeout))
    |> normalize_response(&normalize_health/1)
  end

  @spec status(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def status(ip, opts \\ []) when is_binary(ip) and is_list(opts) do
    ip
    |> endpoint(opts, "/status")
    |> request(:get, nil, timeout(opts, @health_timeout))
    |> normalize_response(&normalize_status/1)
  end

  @spec submit_task(String.t(), map(), keyword()) :: {:ok, task_result()} | {:error, error()}
  def submit_task(ip, task, opts \\ []) when is_binary(ip) and is_map(task) and is_list(opts) do
    ip
    |> endpoint(opts, "/tasks")
    |> request(:post, task, timeout(opts, @task_timeout))
    |> normalize_response(&normalize_task_response/1)
  end

  @spec normalize_health(term()) :: {:ok, health()} | {:error, error()}
  def normalize_health(%{"ok" => true, "service" => "hermes"} = payload) do
    {:ok,
     %{
       version: Map.get(payload, "version"),
       node_id: Map.get(payload, "node_id")
     }}
  end

  def normalize_health(_payload) do
    error("not_hermes", "Response is not a Hermes health payload")
  end

  @spec normalize_status(term()) :: {:ok, map()} | {:error, error()}
  def normalize_status(payload) when is_map(payload) do
    {:ok, atomize_known_status(payload)}
  end

  def normalize_status(_payload) do
    error("malformed_json", "Hermes status response is malformed")
  end

  @spec normalize_task_response(term()) :: {:ok, task_result()} | {:error, error()}
  def normalize_task_response(%{"accepted" => true} = payload) do
    {:ok,
     %{
       task_id: Map.get(payload, "task_id"),
       state: Map.get(payload, "state")
     }}
  end

  def normalize_task_response(_payload) do
    error("task_rejected", "Hermes task response was not accepted")
  end

  defp endpoint(ip, opts, path) do
    port = Keyword.get(opts, :port, @default_port)
    "http://#{ip}:#{port}#{path}"
  end

  defp timeout(opts, default), do: Keyword.get(opts, :timeout, default)

  defp request(url, :get, _body, timeout) do
    Req.get(url, receive_timeout: timeout, retry: false)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp request(url, :post, body, timeout) do
    Req.post(url, json: body, receive_timeout: timeout, retry: false)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_response({:ok, %{status: status, body: body}}, normalizer) when status in 200..299 do
    case decode_body(body) do
      {:ok, payload} -> normalizer.(payload)
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_response({:ok, %{status: status, body: body}}, _normalizer) do
    error("http_error", "Hermes returned HTTP #{status}: #{body_message(body)}")
  end

  defp normalize_response({:error, reason}, _normalizer) do
    network_error(reason)
  end

  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> error("malformed_json", "Hermes response was not valid JSON")
    end
  end

  defp decode_body(_body), do: error("malformed_json", "Hermes response was not a JSON object")

  defp network_error(%Req.TransportError{reason: :timeout}) do
    error("timeout", "Hermes request timed out")
  end

  defp network_error(%Req.TransportError{reason: :econnrefused}) do
    error("refused", "Hermes connection was refused")
  end

  defp network_error(%Req.TransportError{reason: reason}) do
    error("network_error", "Hermes network error: #{inspect(reason)}")
  end

  defp network_error(%{reason: :timeout}) do
    error("timeout", "Hermes request timed out")
  end

  defp network_error(%{reason: :econnrefused}) do
    error("refused", "Hermes connection was refused")
  end

  defp network_error(reason) do
    error("network_error", "Hermes request failed: #{Exception.message(reason)}")
  rescue
    _exception -> error("network_error", "Hermes request failed: #{inspect(reason)}")
  end

  defp atomize_known_status(payload) do
    Map.new(payload, fn
      {"ready", value} -> {:ready, value}
      {"state", value} -> {:state, value}
      {"node_id", value} -> {:node_id, value}
      {key, value} -> {key, value}
    end)
  end

  defp body_message(body) when is_binary(body), do: String.trim(body)
  defp body_message(body), do: inspect(body)

  defp error(code, message), do: {:error, %{code: code, message: message}}
end
