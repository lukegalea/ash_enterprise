defmodule AshEnterprise.Artifacts.Differs.ReleaseManifest do
  @moduledoc """
  Two release manifests (`AshEnterprise.Execution.ReleaseManifest`), by what they pin
  (their `entries`, matched by kind and name):

    * **routing**: the processes and decisions work is routed through;
    * **agents**: which version of each agent;
    * **authority**, **tools** and **models**: for an agent whose version changed, who
      its runs act as, the tools it may ask for and its model profile, read from the two
      pinned versions (`AshEnterprise.Artifacts.Differs.AgentVersion`), as the viewer;
      plus the tools and model profiles the manifest pins itself;
    * **rules**, **judgments** and **evaluation**: rule sets, judgment questions and
      suites.

  An entry is compared by its version and digest, never by its text. An agent whose two
  versions the viewer cannot read is reported as changed with its contents unread.
  """

  @behaviour AshEnterprise.Artifacts.Differ

  use Gettext, backend: AshEnterpriseWeb.Gettext

  alias AshEnterprise.Artifacts.Change
  alias AshEnterprise.Artifacts.Differs.AgentVersion, as: AgentDiffer
  alias AshEnterprise.Execution

  @aspect %{
    "process" => :routing,
    "decision" => :routing,
    "agent" => :agents,
    "tool" => :tools,
    "model_profile" => :models,
    "ruleset" => :rules,
    "judgment_question" => :judgments,
    "suite" => :evaluation
  }

  @impl true
  def aspects do
    [
      routing: dgettext_noop("artifacts", "Routing"),
      agents: dgettext_noop("artifacts", "Agents"),
      authority: dgettext_noop("artifacts", "Authority"),
      tools: dgettext_noop("artifacts", "Tools"),
      models: dgettext_noop("artifacts", "Models"),
      rules: dgettext_noop("artifacts", "Rules"),
      judgments: dgettext_noop("artifacts", "Judgments"),
      evaluation: dgettext_noop("artifacts", "Evaluation")
    ]
  end

  @impl true
  def diff(old, new, opts) do
    old_entries = entries(old.entries)
    new_entries = entries(new.entries)

    pinned =
      @aspect
      |> Map.values()
      |> Enum.uniq()
      |> Enum.flat_map(fn aspect ->
        Change.keyed(aspect, by_aspect(old_entries, aspect), by_aspect(new_entries, aspect))
      end)

    agents =
      for {{"agent", name}, from} <- old_entries,
          {:ok, to} <- [Map.fetch(new_entries, {"agent", name})],
          from["id"] != to["id"],
          change <- agent(name, from["id"], to["id"], opts),
          do: change

    {:ok, pinned ++ agents}
  end

  defp entries(entries) do
    Map.new(entries || [], fn entry ->
      annotations = entry["annotations"] || %{}

      {{annotations["kind"], entry["name"]},
       %{
         "id" => annotations["id"],
         "version" => annotations["version"],
         "digest" => get_in(entry, ["digest", "sha256"])
       }}
    end)
  end

  defp by_aspect(entries, aspect) do
    for {{kind, name}, value} <- entries,
        Map.get(@aspect, kind, :unknown) == aspect,
        into: %{},
        do: {label(kind, name), Map.delete(value, "id")}
  end

  defp label(kind, name) when kind in ["process", "decision"], do: "#{kind} #{name}"
  defp label(_kind, name), do: name

  # What changed inside an agent the two manifests pin at different versions.
  defp agent(name, from_id, to_id, opts) do
    with {:ok, from} <- read(from_id, opts),
         {:ok, to} <- read(to_id, opts),
         {:ok, changes} <- AgentDiffer.diff(from, to, opts) do
      for %Change{aspect: aspect} = change <- changes,
          aspect in [:authority, :tools, :model] do
        %{change | aspect: nested(aspect), subject: subject(name, change.subject)}
      end
    else
      _unread ->
        [
          %Change{
            aspect: :agents,
            kind: :changed,
            subject: name,
            option: "contents",
            from: :unread,
            to: :unread
          }
        ]
    end
  end

  defp nested(:model), do: :models
  defp nested(aspect), do: aspect

  defp subject(name, nil), do: name
  defp subject(name, subject), do: "#{name}: #{subject}"

  defp read(nil, _opts), do: :unread

  defp read(id, opts) do
    case Execution.get_agent_version(id, Keyword.take(opts, [:actor, :tenant])) do
      {:ok, version} -> {:ok, version}
      {:error, _not_readable} -> :unread
    end
  end
end
