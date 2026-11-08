defmodule AshEnterprise.Artifacts.Facets do
  @moduledoc """
  The per-type checks and references the artifact registry names
  (`AshEnterprise.Artifacts`): each re-reads what the stored version says about itself,
  and none reads the database.

  A check returns `{:ok, problems}`, `[]` meaning it ran and found none, or
  `{:error, reason}` when there is nothing to check yet (a draft never compiled, a
  manifest whose gate has not run). The page shows an error as "not checked", never as
  valid.
  """

  alias AshAgent.AgentVersion.Definition
  alias AshEnterprise.Assistant.Composer
  alias AshEnterprise.Quality.Validations.Cases

  # --- checks ---------------------------------------------------------------------

  @doc "An agent version's publish problems (`AshAgent.AgentVersion.Definition.publish_problems/1`)."
  def agent_problems(version), do: {:ok, Definition.publish_problems(version)}

  @doc "A process definition's compile errors; a version never compiled is not checked."
  def process_problems(%{graph: nil, errors: []}), do: {:error, :not_compiled}
  def process_problems(%{errors: errors}), do: {:ok, Enum.map(errors || [], &message/1)}

  @doc """
  A decision definition's compile errors and its verification's error and warning
  findings; a version never compiled is not checked.
  """
  def decision_problems(%{graph: nil, errors: []}), do: {:error, :not_compiled}

  def decision_problems(%{errors: errors, verification: verification}) do
    findings =
      for finding <- (verification || %{})["findings"] || [],
          to_string(finding["severity"]) in ["error", "warning"],
          do: message(finding)

    {:ok, Enum.map(errors || [], &message/1) ++ findings}
  end

  @doc "A mapping's last validator run (errors and warnings); one never validated is not checked."
  def mapping_problems(%{validation_findings: nil}), do: {:error, :not_validated}

  def mapping_problems(%{validation_findings: findings}) do
    {:ok,
     Enum.map(field(findings, :errors) ++ field(findings, :warnings), fn
       text when is_binary(text) -> text
       finding -> message(finding)
     end)}
  end

  @doc "A suite's case problems (`AshEnterprise.Quality.Validations.Cases.problems/1`)."
  def suite_problems(suite), do: {:ok, Cases.problems(suite.cases || [])}

  @doc "A release manifest's gate result; one whose gate has not run is not checked."
  def release_problems(%{gate_result: %{"passed" => true, "problems" => []}}), do: {:ok, []}

  def release_problems(%{gate_result: %{"passed" => false} = result}) do
    case result["problems"] do
      [_ | _] = problems -> {:ok, problems}
      _none -> {:ok, ["the release gate did not pass"]}
    end
  end

  def release_problems(_manifest), do: {:error, :gate_not_run}

  @doc "A saved surface spec resolved again against the composer's allowlist as it is now."
  def surface_problems(%{spec: spec}) do
    case Composer.reload(spec) do
      {:ok, _surface} -> {:ok, []}
      {:error, messages} -> {:ok, messages}
    end
  end

  # --- references -----------------------------------------------------------------

  @doc "The tools an agent version may ask for, and its model profile."
  def agent_references(version) do
    Enum.map(version.toolset || [], &{:tool, to_string(field(&1, :target))}) ++
      [{:model_profile, version.model_profile}]
  end

  @doc "The decisions, actions and calls a process definition's steps name."
  def process_references(%{graph: graph}) do
    nodes = (graph || %{})["nodes"] || %{}

    nodes
    |> Map.values()
    |> Enum.flat_map(fn node ->
      [
        node["decision"] && {:decision, node["decision"]["ref"]},
        node["action"] && {:action, to_string(node["action"])},
        node["call"] && {:call, node["call"]["ref"]}
      ]
    end)
    |> Enum.reject(&(is_nil(&1) or is_nil(elem(&1, 1))))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "The input data a decision model declares."
  def decision_references(%{graph: graph}) do
    for {_id, input} <- ((graph || %{})["input_data"] || %{}) |> Enum.sort(),
        do: {:input, input["name"]}
  end

  @doc "The resource a mapping writes."
  def mapping_references(mapping), do: [{:resource, mapping.target_resource}]

  @doc "What a release manifest pins: each entry by kind and name."
  def release_references(manifest) do
    for entry <- manifest.entries || [],
        do: {(entry["annotations"] || %{})["kind"], entry["name"]}
  end

  @doc "The module a rule set was compiled from."
  def rule_set_references(revision), do: [{:module, revision.source_module}]

  @doc "What a saved surface shows."
  def surface_references(app), do: [{:source, app.source}]

  defp message(%{} = map), do: field(map, :message) || inspect(map)
  defp message(other), do: to_string(other)

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key)) || default(key)

  defp default(key) when key in [:errors, :warnings], do: []
  defp default(_key), do: nil
end
