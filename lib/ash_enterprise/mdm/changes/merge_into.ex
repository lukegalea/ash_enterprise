defmodule AshEnterprise.Mdm.Changes.MergeInto do
  @moduledoc """
  The merge write (ADR 0017 kept verbatim by 0054): the survivor's
  attributes per the survivorship policy, the loser `merged: true` with
  `master_id` at the survivor, SourceIdentity periods repointed at the
  survivor, and candidates for the loser superseded — all in ONE
  transaction, under the CALLER's correlation id (0017's grant-revocation
  requirement: "why did this disappear" stays answerable).

  The survivorship policy is data: the active MatchRuleSet's
  `survivorship` map for the golden resource, or the `non_null` default
  when the tenant configured none.
  """

  use Ash.Resource.Change
  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    # Order matters inside the one transaction: the loser's row releases
    # its unique email FIRST (this update), and only then does the
    # survivor inherit — the reverse order violates unique_email.
    changeset
    |> Ash.Changeset.before_action(&stage_loser/1)
    |> Ash.Changeset.after_action(&inherit/2)
  end

  defp stage_loser(changeset) do
    tenant = changeset.tenant
    loser = changeset.data
    survivor_id = Ash.Changeset.get_argument(changeset, :survivor_id)

    survivor =
      AshEnterprise.Canonical.Person
      |> Ash.Query.filter(id == ^survivor_id)
      |> Ash.read_one!(tenant: tenant, authorize?: false)

    cond do
      is_nil(survivor) ->
        Ash.Changeset.add_error(changeset,
          field: :survivor_id,
          message: "no such golden record in this tenant"
        )

      survivor.id == loser.id ->
        Ash.Changeset.add_error(changeset,
          field: :survivor_id,
          message: "a record cannot merge into itself"
        )

      # A master is always a golden record: merging into an absorbed row
      # would leave a chain the projectors' golden link cannot follow.
      survivor.merged ->
        Ash.Changeset.add_error(changeset,
          field: :survivor_id,
          message: "was itself merged; merge into its golden record"
        )

      true ->
        stage_merge(changeset, tenant, loser, survivor)
    end
  end

  defp stage_merge(changeset, tenant, loser, survivor) do
    policy = survivorship_policy(tenant, loser)

    %{merged: merged} =
      AshMdm.Survivorship.resolve(policy, [
        %{
          record: :survivor,
          source: "survivor",
          observed_at: survivor.updated_at,
          attributes: %{
            "name" => survivor.name,
            "email" => survivor.email && to_string(survivor.email)
          }
        },
        %{
          record: :loser,
          source: "loser",
          observed_at: loser.updated_at,
          attributes: %{
            "name" => loser.name,
            "email" => loser.email && to_string(loser.email)
          }
        }
      ])

    # Survivorship: the survivor's row is what the operator keeps.
    merged_attrs = Map.take(merged, ["name", "email"])

    moved_identity_ids =
      AshEnterprise.Mdm.SourceIdentity
      |> Ash.Query.filter(golden_id == ^loser.id)
      |> Ash.Query.select(:id)
      |> Ash.read!(tenant: tenant, authorize?: false)
      |> Enum.map(& &1.id)

    # The loser's address is released only when the survivor takes it
    # (unique_email). Otherwise the loser keeps it, so the next
    # projection of that address still finds this row — and links its
    # golden (`Canonical.Projections.Golden`) instead of minting a
    # duplicate the merge already resolved.
    prior_email = released_email(loser, survivor, merged_attrs)

    # Meetings, messages and conversations follow the person (PROD-9).
    joins = AshEnterprise.Mdm.PersonJoins.plan(tenant, loser.id, survivor.id)

    changeset
    |> Ash.Changeset.set_context(%{
      mdm_merge: %{
        survivor_id: survivor.id,
        merged_attrs: merged_attrs,
        moved_identity_ids: moved_identity_ids,
        prior_email: prior_email,
        joins: joins
      }
    })
    |> Ash.Changeset.force_change_attribute(:merge_provenance, %{
      "survivor_id" => survivor.id,
      "merged_attrs" => merged_attrs,
      "moved_identity_ids" => moved_identity_ids,
      "prior_email" => prior_email,
      "joins" => joins
    })
    |> Ash.Changeset.force_change_attribute(:merged, true)
    |> Ash.Changeset.force_change_attribute(:master_id, survivor.id)
    |> release_email(prior_email)
  end

  # The loser's address when the survivor takes it, else nil.
  defp released_email(loser, survivor, merged_attrs) do
    loser_email = loser.email && to_string(loser.email)

    if loser_email && merged_attrs["email"] == loser_email &&
         to_string(survivor.email) != loser_email,
       do: loser_email
  end

  defp release_email(changeset, nil), do: changeset

  defp release_email(changeset, _email),
    do: Ash.Changeset.force_change_attribute(changeset, :email, nil)

  # Runs after the loser's row committed: its email is released, so the
  # survivor can inherit it without violating unique_email.
  defp inherit(changeset, result) do
    tenant = changeset.tenant
    survivor_id = changeset.context[:mdm_merge][:survivor_id]
    merged_attrs = changeset.context[:mdm_merge][:merged_attrs]

    survivor =
      AshEnterprise.Canonical.Person
      |> Ash.Query.filter(id == ^survivor_id)
      |> Ash.read_one!(tenant: tenant, authorize?: false)

    if survivor && merged_attrs do
      survivor
      |> Ash.Changeset.for_update(:mdm_survivor_update, merged_attrs,
        tenant: tenant,
        authorize?: false
      )
      |> Ash.update!(tenant: tenant, authorize?: false)

      repoint_identities(tenant, changeset.data.id, survivor_id)

      AshEnterprise.Mdm.PersonJoins.apply!(
        tenant,
        changeset.context[:mdm_merge][:joins],
        survivor_id
      )

      supersede_candidates(tenant, changeset.data.id)
    end

    {:ok, result}
  end

  defp survivorship_policy(tenant, loser) do
    # Survivorship is data on the pinned-for-resource active MatchRuleSet.
    # NB: rule sets store resource names WITHOUT the "Elixir." prefix, and
    # to_string/1 on a struct adds it — inspect/1 does not.
    rule_set =
      AshEnterprise.Mdm.MatchRuleSet
      |> Ash.Query.filter(golden_resource == ^inspect(loser.__struct__) and status == :active)
      |> Ash.read_one!(tenant: tenant, authorize?: false)

    (rule_set && Map.get(rule_set, :survivorship)) || %{"default" => "non_null"}
  end

  defp repoint_identities(tenant, loser_id, survivor_id) do
    AshEnterprise.Mdm.SourceIdentity
    |> Ash.Query.filter(golden_id == ^loser_id)
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> Enum.each(fn identity ->
      identity
      |> Ash.Changeset.for_update(
        :repoint,
        %{golden_resource: "AshEnterprise.Canonical.Person", golden_id: survivor_id},
        tenant: tenant,
        authorize?: false
      )
      |> Ash.update!(tenant: tenant, authorize?: false)
    end)
  end

  defp supersede_candidates(tenant, loser_id) do
    AshEnterprise.Mdm.MatchCandidate
    |> Ash.Query.filter(golden_id == ^loser_id and status == :pending)
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> Enum.each(fn candidate ->
      candidate
      |> Ash.Changeset.for_update(:update, %{status: :superseded},
        tenant: tenant,
        actor: AshEnterprise.Platform.SystemActor.system(),
        authorize?: true
      )
      |> Ash.update!(
        tenant: tenant,
        actor: AshEnterprise.Platform.SystemActor.system(),
        authorize?: true
      )
    end)
  end
end
