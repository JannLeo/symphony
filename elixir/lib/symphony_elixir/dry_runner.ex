defmodule SymphonyElixir.DryRunner do
  @moduledoc """
  Phase 1 dry-run / no-op agent runner for GitHub Issues.

  Flow:
  1. Receive claimed issue from orchestrator
  2. Claim issue (add agent-running, remove agent-ready, write claim comment)
  3. Create git worktree (based on origin/main, branch = agent/<name>/issue-<num>-<slug>)
  4. Create independent DATA_DIR
  5. Run dry-run commands (git status, node --version, pnpm --version)
  6. Write result comment back to the issue
  7. On error: write error comment, label as agent-failed

  No agent code is executed. No PR is created. No code is modified.
  """

  require Logger

  alias SymphonyElixir.{Config, GitHubIssues}
  alias SymphonyElixir.GitHubIssues.{Adapter, Client, Issue}

  # ─────────────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────────────

  @doc "Execute a dry-run for a GitHub issue."
  # Called from the orchestrator's dispatch pipeline.
  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, _codex_update_recipient \\ nil, opts \\ []) do
    %{id: issue_id, title: title} = issue
    settings = Config.settings!()
    agent_name = settings.tracker.agent_name

    branch_name = Issue.make_branch_name(agent_name, issue_id, title)
    workspace_root = settings.tracker.agent_workspace_root
    data_root = settings.tracker.agent_data_root
    workspace_path = Path.join(workspace_root, branch_name)
    data_path = Path.join(data_root, branch_name)

    started_at = DateTime.utc_now()
    Logger.info("DryRunner: processing issue #{issue.identifier} branch=#{branch_name} workspace=#{workspace_path}")

    # Step 1: Claim the issue
    claim_metadata = %{
      branch_name: branch_name,
      workspace_path: workspace_path,
      started_at: DateTime.to_iso8601(started_at)
    }

    case Adapter.claim_issue(issue_id, claim_metadata) do
      :ok ->
        Logger.info("DryRunner: claimed issue #{issue_id}")

      {:error, :already_claimed} ->
        Logger.info("DryRunner: issue #{issue_id} already claimed by another agent — skipping")
        {:error, :already_claimed}

      {:error, reason} ->
        Logger.error("DryRunner: claim failed for issue #{issue_id}: #{inspect(reason)}")
        Adapter.mark_failed(issue_id, "Claim failed: #{inspect(reason)}")
        {:error, reason}
    end
    |> case do
      {:error, _} = result -> result
      :ok -> do_worktree_and_checks(issue, branch_name, workspace_path, data_path)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Worktree + dry-run checks
  # ─────────────────────────────────────────────────────────────────────────

  defp do_worktree_and_checks(issue, branch_name, workspace_path, data_path) do
    %{id: issue_id, identifier: identifier} = issue

    # Step 2: Create git worktree
    case create_worktree(issue_id, identifier, branch_name, workspace_path, data_path) do
      {:ok, worktree_info} ->
        Logger.info("DryRunner: worktree created at #{workspace_path}")

        # Step 3: Run dry-run checks
        dry_run_results = run_dry_run_checks(workspace_path)

        # Step 4: Write result comment
        result_comment = format_result_comment(issue, branch_name, workspace_path, data_path, worktree_info, dry_run_results)

        case Adapter.write_result_comment(issue_id, %{}, result_comment) do
          :ok ->
            Logger.info("DryRunner: completed for issue #{issue_id}")
            :ok

          {:error, reason} ->
            Logger.error("DryRunner: failed to write result comment: #{inspect(reason)}")
            :ok  # not fatal
        end

      {:error, reason} ->
        Logger.error("DryRunner: worktree creation failed for issue #{issue_id}: #{inspect(reason)}")
        Adapter.mark_failed(issue_id, "Worktree creation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Worktree creation (no-op / Phase 1: only structural checks)
  # ─────────────────────────────────────────────────────────────────────────

  defp create_worktree(issue_id, identifier, branch_name, workspace_path, data_path) do
    workdir = Path.dirname(workspace_path)
    File.mkdir_p!(workdir)
    File.mkdir_p!(data_path)

    repo_url = "https://github.com/#{repo}.git"
    worktree_dir = workspace_path

    # Step 1: Check if worktree already exists
    if File.dir?(Path.join(worktree_dir, ".git")) do
      Logger.info("DryRunner: worktree already exists at #{worktree_dir}")
      {:ok, %{path: worktree_dir, existing: true}}
    else
      {output, exit_code} = System.cmd("git", ["clone", "--depth", "1", repo_url, worktree_dir],
        stderr: true,
        into: []
      )
      Logger.debug("DryRunner: clone = exit=#{exit_code} -> #{output}")

      case exit_code do
        0 ->
          # Create and checkout the branch
          {out2, ec2} = System.cmd("git", ["checkout", "-b", branch_name],
            cd: worktree_dir,
            stderr: true,
            into: []
          )
          Logger.debug("DryRunner: checkout branch = exit=#{ec2} -> #{out2}")

          if ec2 == 0 do
            {:ok, %{path: worktree_dir, existing: false, branch: branch_name}}
          else
            {:error, "git checkout -b failed: #{inspect(out2)}"}
          end

        _ ->
          if File.dir?(worktree_dir), do: File.rm_rf!(worktree_dir)
          {:error, "git clone failed (exit=#{exit_code}): #{inspect(output)}"}
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Dry-run checks
  # ─────────────────────────────────────────────────────────────────────────

  defp run_dry_run_checks(workspace_path) do
    results = %{
      git_status: run_git_status(workspace_path),
      node_version: run_command(workspace_path, "node", ["--version"]),
      pnpm_version: run_command(workspace_path, "pnpm", ["--version"]),
      smoke_hint: check_smoke_script(workspace_path)
    }

    results
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

  defp check_smoke_script(workspace_path) do
    script_path = Path.join(workspace_path, "scripts/smoke.sh")
    if File.exists?(script_path) do
      "Found at `scripts/smoke.sh` — not executed (dry-run mode)."
    else
      "Not present — skipping smoke check."
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Result comment formatting
  # ─────────────────────────────────────────────────────────────────────────

  defp format_result_comment(issue, branch_name, workspace_path, data_path, worktree_info, dry_run_results) do
    existing_str = if worktree_info[:existing], do: " (reused existing)", else: ""

    """
    ## Dry-Run Complete

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
    | Smoke Script | #{dry_run_results.smoke_hint} |

    ### Next Steps
    - This was a **dry-run (Phase 1)** — no agent was executed.
    - Next phase: enable real agent execution and PR creation.
    """
  end

  defp format_result({:ok, val}), do: "`#{val}`"
  defp format_result({:not_found, msg}), do: "❌ #{msg}"
  defp format_result({:error, msg}), do: "❌ #{msg}"
end