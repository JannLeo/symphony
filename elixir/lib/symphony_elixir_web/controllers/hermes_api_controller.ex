defmodule SymphonyElixirWeb.HermesApiController do
  @moduledoc """
  JSON API for the Hermes dashboard.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Hermes.Registry
  alias SymphonyElixirWeb.Endpoint

  @spec nodes(Conn.t(), map()) :: Conn.t()
  def nodes(conn, _params) do
    case snapshot(registry()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, error} ->
        error_response(conn, 503, error.code, error.message)
    end
  end

  @spec submit_task(Conn.t(), map()) :: Conn.t()
  def submit_task(conn, params) do
    with {:ok, body} <- request_body(conn, params),
         {:ok, target_ids, task} <- validate_task_body(body),
         {:ok, result} <- submit(registry(), target_ids, task) do
      conn
      |> put_status(202)
      |> json(result)
    else
      {:error, %{status: 400, code: code, message: message}} ->
        error_response(conn, 400, code, message)

      {:error, %{code: code, message: message}} ->
        error_response(conn, 503, code, message)
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  defp request_body(conn, params) do
    body_from_params = Map.drop(params, ["_format"])

    cond do
      map_size(body_from_params) > 0 ->
        {:ok, body_from_params}

      true ->
        case Conn.read_body(conn) do
          {:ok, "", _conn} ->
            {:ok, %{}}

          {:ok, raw_body, _conn} ->
            case Jason.decode(raw_body) do
              {:ok, decoded} when is_map(decoded) ->
                {:ok, decoded}

              {:ok, _decoded} ->
                {:error, bad_request("invalid_json", "Request body must be a JSON object")}

              {:error, _reason} ->
                {:error, bad_request("invalid_json", "Request body must be valid JSON")}
            end

          {:more, _partial, _conn} ->
            {:error, bad_request("invalid_json", "Request body is too large")}

          {:error, _reason} ->
            {:error, bad_request("invalid_json", "Could not read request body")}
        end
    end
  end

  defp validate_task_body(body) do
    title = body_value(body, "title")
    prompt = body_value(body, "prompt")
    target_ids = body_value(body, "target_ids")

    cond do
      blank?(title) ->
        {:error, bad_request("missing_title", "title is required")}

      blank?(prompt) ->
        {:error, bad_request("missing_prompt", "prompt is required")}

      not valid_target_ids?(target_ids) ->
        {:error, bad_request("missing_target_ids", "target_ids must contain at least one target id")}

      true ->
        {:ok, target_ids, %{title: String.trim(title), prompt: String.trim(prompt)}}
    end
  end

  defp body_value(body, key), do: Map.get(body, key) || Map.get(body, String.to_existing_atom(key))

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp valid_target_ids?(target_ids) do
    is_list(target_ids) and target_ids != [] and Enum.all?(target_ids, &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp snapshot(registry) do
    {:ok, Registry.snapshot(registry)}
  catch
    :exit, _reason -> {:error, %{code: "registry_unavailable", message: "Hermes registry is unavailable"}}
  end

  defp submit(registry, target_ids, task) do
    {:ok, Registry.submit_task(registry, target_ids, task) |> normalize_submission()}
  catch
    :exit, _reason -> {:error, %{code: "registry_unavailable", message: "Hermes registry is unavailable"}}
  end

  defp normalize_submission(%{results: results} = payload) when is_map(results) do
    %{payload | results: Map.new(results, fn {target_id, result} -> {target_id, normalize_result(result)} end)}
  end

  defp normalize_submission(payload), do: payload

  defp normalize_result({:ok, result}) when is_map(result), do: result
  defp normalize_result({:error, error}) when is_map(error), do: %{error: error}
  defp normalize_result(result), do: result

  defp bad_request(code, message), do: %{status: 400, code: code, message: message}

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp registry do
    endpoint_config(:hermes_registry) || Registry
  end

  defp endpoint_config(key) do
    case Application.get_env(:symphony_elixir, Endpoint, []) do
      config when is_list(config) -> Keyword.get(config, key)
      _other -> nil
    end
  end
end
