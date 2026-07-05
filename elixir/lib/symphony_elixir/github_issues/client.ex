defmodule SymphonyElixir.GitHubIssues.Client do
  @moduledoc """
  Thin HTTP client for the GitHub REST API v3 using Req.
  All functions return {:ok, data} | {:error, reason}.
  Token is never printed in logs.
  """

  require Logger

  @api_base "https://api.github.com"

  # ─────────────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────────────

  @doc "List issues with given labels (open state only)"
  @spec list_issues_with_labels(String.t(), String.t(), [String.t()]) :: {:ok, [map()]} | {:error, term()}
  def list_issues_with_labels(token, repo, labels) when is_binary(token) and is_binary(repo) do
    params = %{
      "labels" => Enum.join(labels, ","),
      "state" => "open",
      "per_page" => 50
    }

    url = "#{@api_base}/repos/#{repo}/issues"
    do_get(url, token, params: params)
  end

  @doc "Get a single issue by number"
  @spec get_issue(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_issue(token, repo, issue_number) when is_binary(token) and is_binary(repo) do
    url = "#{@api_base}/repos/#{repo}/issues/#{issue_number}"
    do_get(url, token, [])
  end

  @doc "Get multiple issues by numbers (sequential, GitHub REST doesn't support batch)"
  @spec get_issues(String.t(), String.t(), [String.t()]) :: {:ok, [map()]} | {:error, term()}
  def get_issues(_token, _repo, []), do: {:ok, []}
  def get_issues(token, repo, issue_numbers) when is_binary(token) and is_binary(repo) do
    results = Enum.map(issue_numbers, &get_issue(token, repo, &1))

    ok_results = Enum.filter(results, fn
      {:ok, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {:ok, v} -> v end)

    if length(ok_results) == length(issue_numbers) do
      {:ok, ok_results}
    else
      {:error, :partial_fetch_failed}
    end
  end

  @doc "Add labels to an issue"
  @spec add_labels(String.t(), String.t(), String.t(), [String.t()]) :: {:ok, [map()]} | {:error, term()}
  def add_labels(token, repo, issue_number, labels) when is_binary(token) and is_binary(repo) do
    url = "#{@api_base}/repos/#{repo}/issues/#{issue_number}/labels"
    body = %{"labels" => labels}

    case do_post(url, token, body) do
      {:ok, labels_data} when is_list(labels_data) -> {:ok, labels_data}
      {:ok, _} -> {:ok, []}
      {:error, _} = e -> e
    end
  end

  @doc "Remove a label from an issue"
  @spec remove_label(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def remove_label(token, repo, issue_number, label) when is_binary(token) and is_binary(repo) do
    encoded_label = URI.encode_www_form(label)
    url = "#{@api_base}/repos/#{repo}/issues/#{issue_number}/labels/#{encoded_label}"

    case do_delete(url, token) do
      {:ok, _} -> :ok
      {:error, {:http_error, 404, _}} -> :ok  # already absent
      {:error, _} = e -> e
    end
  end

  @doc "Add an issue comment"
  @spec add_comment(String.t(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def add_comment(token, repo, issue_number, body) when is_binary(token) and is_binary(repo) do
    url = "#{@api_base}/repos/#{repo}/issues/#{issue_number}/comments"
    do_post(url, token, %{"body" => body})
  end

  @doc "Check if an issue has a specific label"
  @spec has_label?(String.t(), String.t(), String.t(), String.t()) :: boolean()
  def has_label?(token, repo, issue_number, label) do
    case get_issue(token, repo, issue_number) do
      {:ok, issue} ->
        existing = issue["labels"] || []
        Enum.any?(existing, fn l -> l["name"] == label end)
      _ ->
        false
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Private helpers
  # ─────────────────────────────────────────────────────────────────────────

  defp base_headers(token) do
    [
      "Accept": "application/vnd.github+json",
      "Authorization": "Bearer #{token}",
      "X-GitHub-Api-Version": "2022-11-28"
    ]
  end

  defp do_get(url, token, opts) when is_list(opts) do
    case Req.get(url, headers: base_headers(token) |> Keyword.merge(opts)) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.debug("GitHub GET #{url} -> #{status}")
        {:error, {:http_error, status, body}}
    end
  end

  defp do_get(url, token, params) when is_map(params) do
    case Req.get(url, headers: base_headers(token), params: params) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.debug("GitHub GET #{url} -> #{status}")
        {:error, {:http_error, status, body}}
    end
  end

  defp do_post(url, token, body) do
    case Req.post(url,
           headers: base_headers(token) ++ [{"content-type", "application/json"}],
           json: body
         ) do
      {:ok, %{status: status, body: body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}
    end
  end

  defp do_delete(url, token) do
    case Req.delete(url, headers: base_headers(token)) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end