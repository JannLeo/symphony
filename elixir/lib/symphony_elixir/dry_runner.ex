defmodule SymphonyElixir.DryRunner do
  @moduledoc """
  Phase 1 dry-run / no-op agent runner for GitHub Issues.

  Flow:
  1. Receive claimed issue from orchestrator
  2. Claim issue (add agent-running, remove agent-ready, write claim comment)
  3. Create git worktree (branch = agent/<name>/issue-<num>-<slug>)
  4. Optionally push branch (only when push_branch=true, never main/master)
  5. Create independent DATA_DIR
  6. Run dry-run commands (git status, node --version, pnpm --version)
  7. Phase 1.5: run scripts/smoke.sh if present (10-min timeout, last 200 lines)
  8. Write result comment with dryRun/pushed/smoke status flags
  9. On error: label agent-failed; on smoke exit 0: label agent-smoke-ok

  Safety invariants:
  - dry_run=true → never push to remote (worktree stays local)
  - push_branch=false (default) → never push even in real mode
  - Branch name must not be main or master → guarded
  - No agent code execution. No PR creation. No code modification.
  - smoke.sh output is scrubbed of tokens/keys before writing to issue comment
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHubIssues.{Adapter, Issue}

  @main_branch_names ["main", "master", "refs/heads/main", "refs/heads/master"]
  # Compiled once at module load — avoids ~r sigil {} delimiter conflict
  @long_base64_pattern Regex.compile!("^[A-Za-z0-9+/]{32,}$")

  # Smoke test timeout: 10 minutes
  @smoke_timeout_ms 600_000
  # Max output lines to keep in issue comment
  @smoke_max_lines 200

  # ─────────────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────────────

  @doc "Execute a dry-run for a GitHub issue."
  @spec run(map(), pid() | nil, keyword()) :: :ok | {:error, term()}
  def run(issue, _codex_update_recipient \\ nil, _opts \\ []) do
    %{id: issue_id, title: title} = issue
    settings = Config.settings!()
    agent_name = settings.tracker.agent_name
    repo = settings.tracker.github_repo

    branch_name = Issue.make_branch_name(agent_name, issue_id, title)
    workspace_root = settings.tracker.agent_workspace_root
    data_root = settings.tracker.agent_data_root
    workspace_path = Path.join(workspace_root, branch_name)
    data_path = Path.join(data_root, branch_name)

    started_at = DateTime.utc_now()
    Logger.info("DryRunner: processing issue #{issue.identifier} branch=#{branch_name} workspace=#{workspace_path}")

    claim_metadata = %{
      branch_name: branch_name,
      workspace_path: workspace_path,
      started_at: DateTime.to_iso8601(started_at)
    }

    case Adapter.claim_issue(issue_id, claim_metadata) do
      :ok ->
        Logger.info("DryRunner: claimed issue #{issue_id}")

      {:error, :already_claimed} ->
        Logger.info("DryRunner: issue #{issue_id} already claimed — skipping")
        {:error, :already_claimed}

      {:error, reason} ->
        Logger.error("DryRunner: claim failed for issue #{issue_id}: #{inspect(reason)}")
        Adapter.mark_failed(issue_id, "Claim failed: #{inspect(reason)}")
        {:error, reason}
    end
    |> case do
      {:error, _} = result -> result
      :ok -> do_worktree_and_checks(issue, branch_name, workspace_path, data_path, repo)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Worktree + dry-run checks + Phase 1.5 SmokeRunner
  # ─────────────────────────────────────────────────────────────────────────

  defp do_worktree_and_checks(issue, branch_name, workspace_path, data_path, repo) do
    %{id: issue_id} = issue
    settings = Config.settings!()

    case create_worktree(issue_id, branch_name, workspace_path, data_path, repo, settings) do
      {:ok, worktree_info} ->
        Logger.info("DryRunner: worktree ready at #{workspace_path}")

        # Structural checks: git status, node, pnpm
        dry_run_results = run_dry_run_checks(workspace_path)

        # Phase 1.5: run smoke.sh if present
        smoke_result = run_smoke_script(workspace_path, issue_id)

        # Write result comment then update labels
        result_comment = format_result_comment(
          issue,
          branch_name,
          workspace_path,
          data_path,
          worktree_info,
          dry_run_results,
          smoke_result,
          settings
        )

        _ = Adapter.write_result_comment(issue_id, %{}, result_comment)

        case smoke_result do
          %{status: :passed} ->
            Adapter.mark_smoke_ok(issue_id)
            Logger.info("DryRunner: smoke PASSED for issue #{issue_id}")

          %{status: :failed} ->
            Adapter.mark_failed(issue_id, "smoke.sh exited with code #{smoke_result.exit_code}")
            Logger.error("DryRunner: smoke FAILED (exit=#{smoke_result.exit_code})")

          %{status: :timeout} ->
            Adapter.mark_failed(issue_id, "smoke.sh timed out after 10 minutes")
            Logger.error("DryRunner: smoke TIMED OUT after #{@smoke_timeout_ms}ms")

          %{status: :not_found} ->
            Logger.info("DryRunner: no smoke.sh found — no label update")
        end

        Logger.info("DryRunner: completed for issue #{issue_id}")
        :ok

      {:error, reason} ->
        Logger.error("DryRunner: worktree creation failed for issue #{issue_id}: #{inspect(reason)}")
        Adapter.mark_failed(issue_id, "Worktree creation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Worktree creation
  # ─────────────────────────────────────────────────────────────────────────

  defp create_worktree(_issue_id, branch_name, workspace_path, data_path, repo, settings) do
    workdir = Path.dirname(workspace_path)
    File.mkdir_p!(workdir)
    File.mkdir_p!(data_path)

    repo_url = "https://github.com/#{repo}.git"
    worktree_dir = workspace_path

    if protected_branch?(branch_name) do
      Logger.error("DryRunner: blocked attempt to use protected branch name '#{branch_name}'")
      {:error, :protected_branch_name}
    else
      if File.dir?(Path.join(worktree_dir, ".git")) do
        Logger.info("DryRunner: worktree already exists at #{worktree_dir}")
        {:ok, %{path: worktree_dir, existing: true, pushed: false, dry_run: true}}
      else
        {output, exit_code} = System.cmd("git", ["clone", "--depth", "1", repo_url, worktree_dir],
          stderr: true, into: []
        )
        Logger.debug("DryRunner: clone = exit=#{exit_code}")

        case exit_code do
          0 ->
            {out2, ec2} = System.cmd("git", ["checkout", "-b", branch_name],
              cd: worktree_dir, stderr: true, into: []
            )
            Logger.debug("DryRunner: checkout branch = exit=#{ec2}")

            if ec2 == 0 do
              pushed = attempt_push(worktree_dir, branch_name, settings)
              {:ok, %{path: worktree_dir, existing: false, branch: branch_name, pushed: pushed, dry_run: true}}
            else
              {:error, "git checkout -b failed: #{inspect(out2)}"}
            end

          _ ->
            if File.dir?(worktree_dir), do: File.rm_rf!(worktree_dir)
            {:error, "git clone failed (exit=#{exit_code}): #{inspect(output)}"}
        end
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Push logic with safety guards
  # ─────────────────────────────────────────────────────────────────────────

  defp protected_branch?(branch_name), do: branch_name in @main_branch_names

  @doc "Attempt to push branch to remote. Only succeeds if dry_run=false AND push_branch=true."
  @spec attempt_push(String.t(), String.t(), map()) :: boolean()
  def attempt_push(worktree_dir, branch_name, settings) do
    dry_run = settings.tracker.dry_run
    push_branch = settings.tracker.push_branch

    cond do
      dry_run == true ->
        Logger.info("DryRunner: push skipped — dry_run=true (AGENT_DRY_RUN=true)")
        false

      push_branch != true ->
        Logger.info("DryRunner: push skipped — push_branch=false (AGENT_PUSH_BRANCH=false or unset)")
        false

      protected_branch?(branch_name) ->
        Logger.error("DryRunner: push BLOCKED — protected branch name '#{branch_name}'")
        false

      true ->
        case System.cmd("git", ["push", "-u", "origin", branch_name],
               cd: worktree_dir, stderr: true, into: []) do
          {_output, 0} ->
            Logger.info("DryRunner: pushed branch '#{branch_name}' to origin")
            true

          {_output, code} ->
            Logger.error("DryRunner: push failed (exit=#{code})")
            false
        end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Dry-run structural checks
  # ─────────────────────────────────────────────────────────────────────────

  defp run_dry_run_checks(workspace_path) do
    %{
      git_status: run_git_status(workspace_path),
      node_version: run_command(workspace_path, "node", ["--version"]),
      pnpm_version: run_command(workspace_path, "pnpm", ["--version"])
    }
  end

  defp run_git_status(workspace_path) do
    case System.cmd("git", ["status", "--short"], cd: workspace_path, stderr: true, into: []) do
      {output, 0} when output in [nil, "", []] -> {:ok, "clean"}
      {output, 0} -> {:ok, output |> to_string() |> String.trim()}
      {_, code} -> {:error, "git status failed: exit=#{code}"}
    end
  end

  defp run_command(workspace_path, cmd, args) do
    case System.find_executable(cmd) do
      nil -> {:not_found, "#{cmd} not found on PATH"}
      _ ->
        case System.cmd(cmd, args, cd: workspace_path, stderr: true, into: []) do
          {output, 0} -> {:ok, output |> to_string() |> String.trim()}
          {_, code} -> {:error, "#{cmd} failed: exit=#{code}"}
        end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Phase 1.5 SmokeRunner
  # ─────────────────────────────────────────────────────────────────────────

  @doc "Check if scripts/smoke.sh exists in the worktree."
  @spec smoke_script_exists?(String.t()) :: boolean()
  def smoke_script_exists?(workspace_path) do
    File.exists?(Path.join(workspace_path, "scripts/smoke.sh"))
  end

  @doc """
  Run scripts/smoke.sh if it exists.
  Timeout: 10 minutes. Captures stdout+stderr, keeps last 200 lines.
  Returns a result map with status :passed | :failed | :timeout | :not_found.
  """
  @spec run_smoke_script(String.t(), String.t()) :: %{
          status: :passed | :failed | :timeout | :not_found,
          output: String.t() | nil,
          exit_code: non_neg_integer() | nil
        }
  def run_smoke_script(workspace_path, _issue_id) do
    smoke_script_path = Path.join(workspace_path, "scripts/smoke.sh")

    unless File.exists?(smoke_script_path) do
      Logger.info("DryRunner: scripts/smoke.sh not found — skipping smoke test")
      %{status: :not_found, output: nil, exit_code: nil}
    else
      Logger.info("DryRunner: running scripts/smoke.sh (timeout=#{div(@smoke_timeout_ms, 60_000)}m)")

      result = run_smoke_command(workspace_path)
      truncated = truncate_smoke_output(result[:output])
      Logger.info("DryRunner: smoke result: status=#{result.status} exit_code=#{result[:exit_code]} lines=#{result[:output_lines]}")

      %{status: result.status, output: truncated, exit_code: result[:exit_code]}
    end
  end

  @doc "Execute smoke.sh and return raw result with timeout guard."
  @spec run_smoke_command(String.t()) :: %{
          status: :passed | :failed | :timeout,
          output: String.t() | nil,
          exit_code: non_neg_integer() | nil,
          output_lines: non_neg_integer()
        }
  def run_smoke_command(workspace_path) do
    script = Path.join(workspace_path, "scripts/smoke.sh")

    task = Task.async(fn ->
      {output, exit_code} = System.cmd("bash", [script],
        cd: workspace_path, stderr: true
      )
      {output, exit_code}
    end)

    case Task.yield(task, @smoke_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        %{status: :passed, output: output, exit_code: 0, output_lines: count_lines(output)}

      {:ok, {output, exit_code}} ->
        %{status: :failed, output: output, exit_code: exit_code, output_lines: count_lines(output)}

      {:exit, _reason} ->
        %{status: :timeout, output: nil, exit_code: nil, output_lines: 0}
    end
  end

  defp truncate_smoke_output(nil), do: ""

  defp truncate_smoke_output(output) when is_binary(output) do
    lines = String.split(output, "\n", trim: false)

    if length(lines) > @smoke_max_lines do
      total = length(lines)
      kept = Enum.take(lines, -@smoke_max_lines)
      note = "_#{total - @smoke_max_lines} lines omitted (showing last #{@smoke_max_lines})_\n\n"
      note <> Enum.join(kept, "\n")
    else
      output
    end
  end

  defp count_lines(""), do: 0
  defp count_lines(nil), do: 0
  defp count_lines(output) when is_binary(output), do: length(String.split(output, "\n", trim: false))

  # ─────────────────────────────────────────────────────────────────────────
  # Result comment formatting (includes smoke result)
  # ─────────────────────────────────────────────────────────────────────────

  defp format_result_comment(_issue, branch_name, workspace_path, data_path, worktree_info, dry_run_results, smoke_result, settings) do
    existing_str = if worktree_info[:existing], do: " (reused existing)", else: ""
    pushed = worktree_info[:pushed] || false
    dry_run = settings.tracker.dry_run

    smoke_section = format_smoke_section(smoke_result)

    """
    ## Dry-Run Complete

    ### Mode
    | Field | Value |
    |-------|-------|
    | dryRun | `#{dry_run}` |
    | pushed | `#{pushed}` |

    ### Worktree
    | Field | Value |
    |-------|-------|
    | Branch | `#{branch_name}` |
    | Workspace | `#{workspace_path}#{existing_str}` |
    | DATA_DIR | `#{data_path}` |

    ### Dry-Run Checks
    | Check | Result |
    |-------|--------|
    | Git Status | #{format_result(dry_run_results.git_status)} |
    | Node Version | #{format_result(dry_run_results.node_version)} |
    | pnpm Version | #{format_result(dry_run_results.pnpm_version)} |

    #{smoke_section}

    ### Safety
    - `main` / `master` push: **blocked** (never allowed)
    - No Codex/Hermes execution in dry-run mode.
    - No PR creation in dry-run mode.
    """
  end

  defp format_smoke_section(%{status: :not_found}) do
    """
    ### Smoke Test
    | Status | Value |
    |--------|-------|
    | Script | Not found — skipped |
    """
  end

  defp format_smoke_section(%{status: :passed, output: output, exit_code: 0}) do
    """
    ### Smoke Test
    | Status | Value |
    |--------|-------|
    | Status | ✅ PASSED |
    | Exit Code | `0` |
    | Script | `scripts/smoke.sh` |

    ### Smoke Output (last #{@smoke_max_lines} lines)
    ```bash
    #{scrub_token(output)}
    ```
    """
  end

  defp format_smoke_section(%{status: :failed, output: output, exit_code: ec}) do
    """
    ### Smoke Test
    | Status | Value |
    |--------|-------|
    | Status | ❌ FAILED |
    | Exit Code | `#{ec}` |
    | Script | `scripts/smoke.sh` |

    ### Smoke Output (last #{@smoke_max_lines} lines)
    ```bash
    #{scrub_token(output)}
    ```
    """
  end

  defp format_smoke_section(%{status: :timeout}) do
    """
    ### Smoke Test
    | Status | Value |
    |--------|-------|
    | Status | ⏱ TIMEOUT |
    | Timeout | 10 minutes |
    """
  end

  # Scrub tokens/secrets from smoke output before writing to issue comment
  defp scrub_token(nil), do: ""
  defp scrub_token(output) when is_binary(output) do
    output
    |> String.split("\n", trim: false)
    |> Enum.take(-@smoke_max_lines)
    |> Enum.map_join("\n", &redact_sensitive_line/1)
  end

  defp redact_sensitive_line(line) do
    if sensitive_line?(line) do
      case String.split(line, ["=", ":", " "], parts: 2) do
        [key, _val] -> "#{key} [REDACTED]"
        _ -> "[REDACTED]"
      end
    else
      line
    end
  end

  defp sensitive_line?(line) do
    Enum.any?(
      [
        ~r/(?i)(token|secret|password|api_key|apikey|auth|bearer|ghp_|sk-)/,
        @long_base64_pattern,
        ~r/-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----/
      ],
      fn p -> Regex.match?(p, line) end
    )
  end

  defp format_result({:ok, val}), do: "`#{val}`"
  defp format_result({:not_found, msg}), do: "❌ #{msg}"
  defp format_result({:error, msg}), do: "❌ #{msg}"
end