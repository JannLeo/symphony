defmodule SymphonyElixir.GitHubIssues.Issue do
  @moduledoc """
  Normalized GitHub issue representation used by the orchestrator.
  Mirrors the structure of Linear.Issue so the rest of the system is agnostic to the tracker.
  """

  defstruct [
    :id,           # GitHub issue number as string (e.g. "123")
    :identifier,   # "owner/repo#123"
    :title,
    :description,
    :state,        # "open" | "closed" — not used for routing in GitHub mode
    :branch_name,   # "agent/hermes/issue-123-fix-bug"
    :url,          # "https://github.com/owner/repo/issues/123"
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          blocked_by: [String.t()],
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec from_github_map(map(), String.t()) :: t()
  def from_github_map(github_issue, repo) do
    issue_number = to_string(github_issue["number"])

    %__MODULE__{
      id: issue_number,
      identifier: "#{repo}##{issue_number}",
      title: github_issue["title"],
      description: github_issue["body"],
      state: github_issue["state"],
      branch_name: nil,
      url: github_issue["html_url"],
      labels: extract_label_names(github_issue["labels"]),
      assigned_to_worker: true,
      created_at: parse_datetime(github_issue["created_at"]),
      updated_at: parse_datetime(github_issue["updated_at"])
    }
  end

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}), do: labels

  @spec routable?(t(), [String.t()]) :: boolean()
  def routable?(%__MODULE__{assigned_to_worker: true, labels: labels}, _required_labels)
      when is_list(labels) do
    # In GitHub mode, routing is based purely on label agent-ready (handled in adapter)
    # required_labels is not used in GitHub mode; we always check agent-ready in the query
    true
  end

  def routable?(%__MODULE__{}, _required_labels), do: false

  defp extract_label_names(nil), do: []
  defp extract_label_names(labels) when is_list(labels) do
    Enum.map(labels, fn l -> l["name"] end)
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  @doc "Generate a safe branch name from issue number and title slug"
  @spec make_branch_name(String.t(), String.t(), String.t()) :: String.t()
  def make_branch_name(agent_name, issue_id, title) do
    slug = title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.replace(~r/^-+|-+$/, "")
    |> String.slice(0, 40)

    "agent/#{agent_name}/issue-#{issue_id}-#{slug}"
  end
end