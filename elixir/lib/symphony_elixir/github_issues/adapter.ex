defmodule SymphonyElixir.GitHubIssues.Adapter do
  @moduledoc """
  GitHub Issues-backed tracker adapter.

  Filtering rules:
  - repo from config.github_repo
  - state = open
  - label includes "agent-ready"
  - label does NOT include "agent-running"
  - label does NOT include "agent-blocked"
  - label does NOT include "agent-done"

  Claim logic:
  - Adds label "agent-running"
  - Removes label "agent-ready"
  - Writes comment with agent name, branch, workspace path, startedAt
  - If add label fails (409 Conflict), returns {:error, :already_claimed}

  Error handling:
  - On error: writes issue comment with failure reason, removes "agent-running", adds "agent-failed"
  - Token is never logged
  """

  @behaviour SymphonyElixir.Tracker

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHubIssues.{Client, Issue}

  @label_agent_ready "agent-ready"
  @label_agent_running "agent-running"
  @label_agent_blocked "agent-blocked"
  @label_agent_done "agent-done"
  @label_agent_failed "agent-failed"
  @label_agent_smoke_ok "agent-smoke-ok"

  # ─────────────────────────────────────────────────────────────────────────
  # Tracker behaviour callbacks
  # ─────────────────────────────────────────────────────────────────────────

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    settings = Config.settings!()
    token = settings.tracker.github_token
    repo = settings.tracker.github_repo
    IO.puts(:stderr, "[GITHUB] fetch_candidate_issues token=#{if(token, do: "ok", else: "nil")} repo=#{inspect(repo)}")

    case Client.list_issues_with_labels(token, repo, [@label_agent_ready]) do
      {:ok, github_issues} ->
        IO.puts(:stderr, "[GITHUB] got #{length(github_issues)} raw issues from API")
        issues = github_issues
        |> Enum.reject(fn issue ->
          # Reject issues that already have agent-running / agent-blocked / agent-done
          labels = Enum.map(issue["labels"] || [], & &1["name"])
          has_running = @label_agent_running in labels
          has_blocked = @label_agent_blocked in labels
          has_done = @label_agent_done in labels
          has_failed = @label_agent_failed in labels
          reject = has_running or has_blocked or has_done or has_failed
          if reject, do: IO.puts(:stderr, "[GITHUB] rejecting issue ##{issue["number"]} labels=#{inspect(labels)}")
          reject
        end)
        |> Enum.map(fn gh -> Issue.from_github_map(gh, repo) end)

        IO.puts(:stderr, "[GITHUB] after filter: #{length(issues)} candidate issues")
        {:ok, issues}

      {:error, reason} ->
        IO.puts(:stderr, "[GITHUB] API error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(_states) do
    # In GitHub mode, states are not used for issue selection — labels are.
    # Called by orchestrator for terminal-state reconciliation.
    # Filter by agent-done label.
    settings = Config.settings!()
    token = settings.tracker.github_token
    repo = settings.tracker.github_repo

    case Client.list_issues_with_labels(token, repo, [@label_agent_done]) do
      {:ok, github_issues} ->
        issues = Enum.map(github_issues, fn gh -> Issue.from_github_map(gh, repo) end)
        {:ok, issues}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    settings = Config.settings!()
    token = settings.tracker.github_token
    repo = settings.tracker.github_repo

    case Client.get_issues(token, repo, issue_ids) do
      {:ok, github_issues} ->
        issues = Enum.map(github_issues, fn gh -> Issue.from_github_map(gh, repo) end)
        {:ok, issues}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    settings = Config.settings!()
    token = settings.tracker.github_token
    repo = settings.tracker.github_repo

    case Client.add_comment(token, repo, issue_id, body) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(_issue_id, _state_name) do
    # GitHub uses labels, not states. This is a no-op for GitHub mode.
    # State transitions in GitHub are handled via labels in the dry-run workflow.
    :ok
  end

  @spec claim_issue(String.t(), map()) :: :ok | {:error, :already_claimed | term()}
  def claim_issue(issue_id, metadata \\ %{}) when is_binary(issue_id) and is_map(metadata) do
    settings = Config.settings!()
    token = settings.tracker.github_token
    repo = settings.tracker.github_repo
    agent_name = settings.tracker.agent_name

    # Step 1: Check if already claimed (has agent-running label)
    if Client.has_label?(token, repo, issue_id, @label_agent_running) do
      {:error, :already_claimed}
    else
      # Step 2: Add agent-running label
      case Client.add_labels(token, repo, issue_id, [@label_agent_running]) do
        {:ok, _} ->
          # Step 3: Remove agent-ready label (best effort — non-fatal if missing)
          _ = Client.remove_label(token, repo, issue_id, @label_agent_ready)

          # Step 4: Write claim comment
          branch_name = Map.get(metadata, :branch_name, "unknown")
          workspace_path = Map.get(metadata, :workspace_path, "unknown")
          started_at = Map.get(metadata, :started_at, DateTime.utc_now() |> DateTime.to_iso8601())

          comment_body = """
          Agent claimed this issue

          | Field | Value |
          |-------|-------|
          | Agent | #{agent_name} |
          | Branch | `#{branch_name}` |
          | Workspace | `#{workspace_path}` |
          | Started At | #{started_at} |
          | Mode | dry-run |
          """

          case Client.add_comment(token, repo, issue_id, comment_body) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end

        {:error, {:http_error, 409, _body}} ->
          # 409 = label already exists → already claimed by another agent
          {:error, :already_claimed}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Public helpers (used by DryRunner)
  # ─────────────────────────────────────────────────────────────────────────

  @doc "Write a result comment to the issue"
  @spec write_result_comment(String.t(), map(), String.t()) :: :ok | {:error, term()}
  def write_result_comment(issue_id, _result, comment_body) when is_binary(issue_id) and is_binary(comment_body) do
    settings = Config.settings!()
    token = settings.tracker.github_token
    repo = settings.tracker.github_repo

    case Client.add_comment(token, repo, issue_id, comment_body) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Mark issue as failed: remove agent-running, add agent-failed, write error comment."
  @spec mark_failed(String.t(), String.t()) :: :ok
  def mark_failed(issue_id, error_message) when is_binary(issue_id) and is_binary(error_message) do
    settings = Config.settings!()
    token = settings.tracker.github_token
    repo = settings.tracker.github_repo

    # Remove agent-running label
    _ = Client.remove_label(token, repo, issue_id, @label_agent_running)

    # Add agent-failed label
    _ = Client.add_labels(token, repo, issue_id, [@label_agent_failed])

    # Write error comment (token is never printed)
    error_comment = """
    ## Agent Failed

    Error: #{error_message}

    *Token was not exposed in this error message.*
    """

    case Client.add_comment(token, repo, issue_id, error_comment) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Mark issue smoke test passed: remove agent-running, add agent-smoke-ok."
  @spec mark_smoke_ok(String.t()) :: :ok
  def mark_smoke_ok(issue_id) when is_binary(issue_id) do
    settings = Config.settings!()
    token = settings.tracker.github_token
    repo = settings.tracker.github_repo

    _ = Client.remove_label(token, repo, issue_id, @label_agent_running)
    _ = Client.add_labels(token, repo, issue_id, [@label_agent_smoke_ok])

    :ok
  end
end