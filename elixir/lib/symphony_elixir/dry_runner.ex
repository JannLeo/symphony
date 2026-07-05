defmodule SymphonyElixir.DryRunner do
  @moduledoc """
  Phase 1 dry-run / no-op agent runner for GitHub Issues.

  Flow:
  1. Receive claimed issue from orchestrator
  2. Claim issue (add agent-running, remove agent-ready, write claim comment)
  3. Create git worktree (based on origin/main, branch = agent/<name>/issue-<num>-<slug>)
  4. Optionally push branch to remote (only when push_branch=true, never on main/master)
  5. Create independent DATA_DIR
  6. Run dry-run commands (git status, node --version, pnpm --version)
  7. Write result comment back to the issue (dryRun, pushed flags)
  8. On error: write error comment, label as agent-failed

  Safety invariants:
  - dry_run=true  → never push to remote (worktree stays local)
  - push_branch=false (default) → never push even in real mode
  - Branch name must not be main or master → guarded
  - No agent code execution. No PR creation. No code modification.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHubIssues.{Adapter, Issue}

  @main_branch_names ["main", "master", "refs/heads/main", "refs/heads/master"]

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
      :ok -> do_worktree_and_checks(issue, branch_name, workspace_path, data_path, repo)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Worktree + dry-run checks
  # ─────────────────────────────────────────────────────────────────────────

  defp do_worktree_and_checks(issue, branch_name, workspace_path, data_path, repo) do
    %{id: issue_id} = issue
    settings = Config.settings!()

    # Step 2: Create git worktree
    case create_worktree(issue_id, branch_name, workspace_path, data_path, repo, settings) do
      {:ok, worktree_info} ->
        Logger.info("DryRunner: worktree ready at #{workspace_path}")

        # Step 3: Run dry-run checks
        dry_run_results = run_dry_run_checks(workspace_path)

        # Step 4: Write result comment (dryRun + pushed flags)
        result_comment = format_result_comment(
          issue,
          branch_name,
          workspace_path,
          data_path,
          worktree_info,
          dry_run_results,
          settings
        )

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
  # Worktree creation
  # ─────────────────────────────────────────────────────────────────────────

  defp create_worktree(_issue_id, branch_name, workspace_path, data_path, repo, settings) do
    workdir = Path.dirname(workspace_path)
    File.mkdir_p!(workdir)
    File.mkdir_p!(data_path)

    repo_url = "https://github.com/#{repo}.git"
    worktree_dir = workspace_path

    # Safety: never work with main or master
    if protected_branch?(branch_name) do
      Logger.error("DryRunner: blocked attempt to use protected branch name '#{branch_name}'")
      {:error, :protected_branch_name}
    else
      # Step 1: Check if worktree already exists
      if File.dir?(Path.join(worktree_dir, ".git")) do
        Logger.info("DryRunner: worktree already exists at #{worktree_dir}")
        {:ok, %{path: worktree_dir, existing: true, pushed: false, dry_run: true}}
      else
        # Clone from remote
        {output, exit_code} = System.cmd("git", ["clone", "--depth", "1", repo_url, worktree_dir],
          stderr: true,
          into: []
        )
        Logger.debug("DryRunner: clone = exit=#{exit_code}")

        case exit_code do
          0 ->
            # Create the agent branch (NO push in dry-run mode)
            {out2, ec2} = System.cmd("git", ["checkout", "-b", branch_name],
              cd: worktree_dir,
              stderr: true,
              into: []
            )
            Logger.debug("DryRunner: checkout branch = exit=#{ec2}")

            if ec2 == 0 do
              # Determine push policy
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

  @spec protected_branch?(String.t()) :: boolean()
  defp protected_branch?(branch_name) do
    branch_name in @main_branch_names
  end

  @doc "Attempt to push branch to remote. Only succeeds if dry_run=false AND push_branch=true."
  @spec attempt_push(String.t(), String.t(), map()) :: boolean()
  def attempt_push(worktree_dir, branch_name, settings) do
    dry_run = settings.tracker.dry_run
    push_branch = settings.tracker.push_branch

    cond do
      # Safety: never push in dry-run mode
      dry_run == true ->
        Logger.info("DryRunner: push skipped — dry_run=true (AGENT_DRY_RUN=true)")
        false

      # Safety: push_branch must be explicitly enabled
      push_branch != true ->
        Logger.info("DryRunner: push skipped — push_branch=false (AGENT_PUSH_BRANCH=false or unset)")
        false

      # Safety: never push to main or master
      protected_branch?(branch_name) ->
        Logger.error("DryRunner: push BLOCKED — protected branch name '#{branch_name}'")
        false

      true ->
        # Actually push
        case System.cmd("git", ["push", "-u", "origin", branch_name],
               cd: worktree_dir,
               stderr: true, into: []) do
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
  # Dry-run checks
  # ─────────────────────────────────────────────────────────────────────────

  defp run_dry_run_checks(workspace_path) do
    %{
      git_status: run_git_status(workspace_path),
      node_version: run_command(workspace_path, "node", ["--version"]),
      pnpm_version: run_command(workspace_path, "pnpm", ["--version"]),
      smoke_hint: check_smoke_script(workspace_path)
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

  defp format_result_comment(_issue, branch_name, workspace_path, data_path, worktree_info, dry_run_results, settings) do
    existing_str = if worktree_info[:existing], do: " (reused existing)", else: ""
    pushed = worktree_info[:pushed] || false
    dry_run = settings.tracker.dry_run

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
    | Smoke Script | #{dry_run_results.smoke_hint} |

    ### Safety
    - `main` / `master` push: **blocked** (never allowed)
    - No Codex/Hermes execution in dry-run mode.
    - No PR creation in dry-run mode.
    """
  end

  defp format_result({:ok, val}), do: "`#{val}`"
  defp format_result({:not_found, msg}), do: "❌ #{msg}"
  defp format_result({:error, msg}), do: "❌ #{msg}"
end