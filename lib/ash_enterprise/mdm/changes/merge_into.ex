defmodule AshEnterprise.Mdm.Changes.MergeInto do
  @moduledoc """
  The merge write (ADR 0017 kept verbatim by 0054): the survivor's
  attributes per the survivorship policy, the loser `merged: true` with
  `master_id` at the survivor, SourceIdentity periods repointed at the
  survivor, and candidates for the loser superseded — all in ONE
  transaction, under the CALLER's correlation id (0017's grant-revocation
  requirement: "why did this disappear" stays answerable).

  Both sides refold first, so every value either holds is a statement. An
  absorbed person's statements stay where they are and the survivor folds
  through `master_id` (`AshEnterprise.Mdm.Refold`), under the one policy that
  governs the person.

  `merge_provenance` records, beside what the unmerge restores, who won each
  field: `"winners"` maps an attribute to `"winner"` (`"survivor"`, `"loser"`
  or nil when neither had a value), `"strategy"`, and the winning statement's
  `"source"` and `"assertion_id"`. With them, the deciding rule set
  (`"rule_set_id"`, `"rule_set_content_hash"`, both nil under the default) and
  `"assertions_folded"`, which tells the unmerge this merge's statements exist.
  """

  use Ash.Resource.Change
  require Ash.Query

  alias AshEnterprise.Mdm.Refold

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
    survivor_id = Ash.Changeset.get_argument(changeset, :survivor_id)

    # Everything is read under the lock. The changeset's record was read
    # before it, so two merges in opposite directions would each still see
    # the other side as a golden, and leave a cycle.
    Refold.lock!(tenant, [changeset.data.id, survivor_id])
    loser = read_person(tenant, changeset.data.id)
    survivor = read_person(tenant, survivor_id)

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

      loser.merged ->
        Ash.Changeset.add_error(changeset,
          field: :merged,
          message: "was already merged into another record"
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

  defp read_person(tenant, id) do
    AshEnterprise.Canonical.Person
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(tenant: tenant, authorize?: false)
  end

  defp stage_merge(changeset, tenant, loser, survivor) do
    # Every value either side holds becomes a statement before anything moves.
    %{golden: loser} = Refold.refold!(tenant, loser.id, write?: false)
    %{golden: survivor} = Refold.refold!(tenant, survivor.id)

    %{rule_set: rule_set, policy: policy} = Refold.governing(tenant)
    standing = Refold.preview_merge(tenant, survivor, loser, policy)

    merged_attrs = Map.take(standing.merged, Refold.attributes())

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
      "joins" => joins,
      "winners" => winners(standing, policy),
      "assertions_folded" => true,
      "rule_set_id" => rule_set && rule_set.id,
      "rule_set_content_hash" => rule_set && rule_set.content_hash
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

    if survivor_id do
      Refold.refold!(tenant, survivor_id)

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

  # The role each side played, beside the statement that won.
  defp winners(standing, policy) do
    Map.new(Refold.attributes(), fn attribute ->
      {attribute, winner(Map.get(standing.statements, attribute), standing, policy, attribute)}
    end)
  end

  defp winner(nil, _standing, policy, attribute) do
    %{
      "winner" => nil,
      "strategy" => strategy(policy, attribute),
      "source" => nil,
      "assertion_id" => nil
    }
  end

  defp winner(statement, standing, policy, attribute) do
    %{
      "winner" => if(statement.golden_id in standing.loser_ids, do: "loser", else: "survivor"),
      "strategy" => strategy(policy, attribute),
      "source" => statement.source,
      "assertion_id" => statement.id
    }
  end

  defp strategy(policy, attribute) do
    get_in(policy, ["attributes", attribute, "strategy"]) || policy["default"] || "non_null"
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
