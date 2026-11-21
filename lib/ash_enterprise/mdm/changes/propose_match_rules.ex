defmodule AshEnterprise.Mdm.Changes.ProposeMatchRules do
  @moduledoc """
  Builds a match-rule proposal (`MatchRuleProposal.propose`) from the tenant's
  steward verdicts, inside the create's transaction:

  1. reads the active rule set for the golden resource;
  2. reads every pair a steward confirmed or rejected and keeps those its
     explanation shows were scored by that rule set's rules;
  3. asks `AshMdm.Tuning.propose/2` for new weights over them;
  4. writes the new weights as a draft successor (`MatchRuleSet.create_version`),
     as the proposing actor, so their grants on rule sets decide;
  5. replays the verdicts under both versions through the tenant's band table
     (`AshEnterprise.Mdm.MatchReplay`, banding by `Banding.preview/3`, recorded
     nowhere) and stores the result on the proposal.

  Nothing here changes matching: the draft scores nothing until a person
  activates the proposal. No model is asked. A proposal whose weights equal the
  active ones is refused, since there is nothing to review.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Mdm.{Banding, MatchCandidate, MatchReplay, MatchRuleSet}

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, &propose(&1, context))
  end

  defp propose(changeset, context) do
    tenant = changeset.tenant
    golden_resource = Ash.Changeset.get_attribute(changeset, :golden_resource)
    write = [tenant: tenant, actor: context.actor, authorize?: context.authorize?]

    with {:ok, base} <- active_rule_set(golden_resource, tenant),
         verdicts = verdicts(tenant),
         comparable = Enum.filter(verdicts, &MatchReplay.comparable?(base.rules, &1.explanation)),
         %{rules: rules, report: report} = AshMdm.Tuning.propose(base.rules, comparable),
         :ok <- moved(base.rules, rules),
         {:ok, table} <- Banding.definition(tenant),
         {:ok, replay} <- MatchReplay.replay(base.rules, rules, verdicts, band(tenant, table)),
         {:ok, draft} <- draft(base, rules, write) do
      Ash.Changeset.force_change_attributes(changeset, %{
        base_rule_set_id: base.id,
        rule_set_id: draft.id,
        band_table_id: table.id,
        proposer: "AshMdm.Tuning #{Application.spec(:ash_mdm, :vsn)}",
        verdicts_digest: digest(comparable),
        tuning: Enum.map(report, &json_safe/1),
        replay: replay.summary,
        changed_pairs: replay.changed,
        flips: replay.summary["flips"]
      })
    else
      {:error, field, message} ->
        Ash.Changeset.add_error(changeset, field: field, message: message)

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp active_rule_set(golden_resource, tenant) do
    MatchRuleSet
    |> Ash.Query.filter(golden_resource == ^golden_resource and status == :active)
    |> Ash.read_one(tenant: tenant, authorize?: false)
    |> case do
      {:ok, %MatchRuleSet{} = rule_set} -> {:ok, rule_set}
      {:ok, nil} -> {:error, :golden_resource, "has no active match rule set"}
      {:error, error} -> {:error, error}
    end
  end

  # Every pair a person decided: a confirm is a match, a reject is not. Read
  # as the machine, like the matcher that generated them; the proposal keeps
  # their ids and bands, never their values.
  defp verdicts(tenant) do
    MatchCandidate
    |> Ash.Query.filter(status in [:confirmed, :rejected])
    |> Ash.Query.select([:id, :explanation, :status])
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> Enum.map(fn candidate ->
      %{
        id: candidate.id,
        explanation: candidate.explanation,
        verdict: if(candidate.status == :confirmed, do: :match, else: :non_match)
      }
    end)
  end

  defp moved(rules, rules),
    do: {:error, :golden_resource, "no rule earned a new weight from the steward verdicts"}

  defp moved(_before, _after), do: :ok

  defp digest(verdicts) do
    ids = verdicts |> Enum.map(& &1.id) |> Enum.sort() |> Enum.join("\n")
    :sha256 |> :crypto.hash(ids) |> Base.encode16(case: :lower)
  end

  defp band(tenant, table), do: &Banding.preview(&1, tenant, pinned: table.id)

  defp draft(base, rules, write) do
    MatchRuleSet
    |> Ash.Changeset.for_create(
      :create_version,
      %{from_rule_set_id: base.id, rules: rules, survivorship: base.survivorship},
      write
    )
    |> Ash.create()
  end

  defp json_safe(entry),
    do: Map.new(entry, fn {key, value} -> {to_string(key), json_value(value)} end)

  defp json_value(value) when is_atom(value) and value not in [nil, true, false],
    do: to_string(value)

  defp json_value(value), do: value
end
