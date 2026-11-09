defmodule AshEnterprise.Mdm.Refold do
  @moduledoc """
  The one fold: a person's `name` and `email` from their attribute assertions
  (`AshMdm.Assertions`), through the merge chain, under one survivorship
  policy, written through `:mdm_survivor_update`.

  ## Which policy

  One per golden, never per flow (`governing/1`): the active rule set for the
  plain Person key, else the people flow's, else `non_null`. Choosing by flow
  would make a person's values depend on which event ran last, and an unmerge
  has no flow at all.

  ## Held values

  A column can hold a value nothing has stated: every row from before
  assertions, and any row a write without a source touched. Left alone, the
  first statement would be the only competitor and would overwrite it. So a
  refold first records such a value as a statement from `"pre_assertion"`,
  dated at the row's `inserted_at`. Matching is on the value, not on whether
  the attribute has any statement: otherwise the second refold would overwrite
  it. These statements are passed to the fold as the `incumbent`, so an import
  dated before the row existed does not displace the value (a `:human`
  statement still does). An unmerge turns this off, because at that point the survivor's column
  still holds what it inherited.

  ## Locks

  Always the tenant's audit-log lock first, then the goldens in id order
  (`lock!/2`). The batch and steward paths reach a refold already holding the
  audit lock, because `AshEvents` takes it on every audited write. A refold
  taking only the golden's lock would then order golden before tenant on its
  own and tenant before golden on those paths, which deadlocks.
  """

  require Ash.Query

  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Mdm.{AttributeAssertion, MatchRuleSet, People}
  alias AshEnterprise.Repo.AdvisoryLock
  alias AshMdm.Assertions

  @golden_resource "AshEnterprise.Canonical.Person"
  @attributes ~w(name email)
  @default_policy %{"default" => "non_null"}
  @held_source "pre_assertion"
  @lock_namespace "mdm.refold"

  @doc "The fields a person's fold decides."
  def attributes, do: @attributes

  @doc """
  The survivorship policy governing every person in this tenant, and the rule
  set it came from (nil under the default).
  """
  @spec governing(term()) :: %{rule_set: struct() | nil, policy: map()}
  def governing(tenant) do
    rule_set = plain_rule_set(tenant) || People.rule_set(tenant)
    %{rule_set: rule_set, policy: (rule_set && rule_set.survivorship) || @default_policy}
  end

  defp plain_rule_set(tenant) do
    MatchRuleSet
    |> Ash.Query.filter(golden_resource == ^@golden_resource and status == :active)
    |> Ash.read_one!(tenant: tenant, authorize?: false)
  end

  @doc """
  Records what an origin says about a person. `values` maps attribute to value;
  blank values are not statements. `origin` carries `:origin_kind`, `:source`,
  `:origin_ref` and `:observed_at`.
  """
  @spec assert!(term(), Ash.UUID.t(), map(), map()) :: [struct()]
  def assert!(tenant, golden_id, values, origin) do
    values
    |> present()
    |> Enum.map(fn {attribute, value} ->
      assert_one!(tenant, golden_id, attribute, value, origin)
    end)
  end

  @doc """
  What a projector just wrote, under its own source name, then a refold.
  Nothing is written when this source has already said it, so a replay and a
  person seen in many threads cost one read.
  """
  @spec assert_from_source!(term(), Ash.UUID.t(), map(), String.t(), DateTime.t()) :: :ok
  def assert_from_source!(tenant, golden_id, values, source, observed_at) do
    existing = source_statements(tenant, golden_id, source)

    new =
      values
      |> present()
      |> Enum.reject(fn {attribute, value} -> said?(existing, attribute, value, observed_at) end)

    if new != [] do
      assert!(tenant, golden_id, Map.new(new), %{
        origin_kind: :import,
        source: source,
        origin_ref: %{"source" => source},
        observed_at: observed_at
      })

      refold!(tenant, golden_id)
    end

    :ok
  end

  @doc """
  Refolds the golden `golden_id` belongs to and writes any change. A merged
  row refolds its golden. Pass `materialize_held: false` only from an unmerge,
  and `write?: false` to record held values without touching the row, which a
  merge needs for its loser: writing it would make the merge's own update of
  that row stale.
  """
  @spec refold!(term(), Ash.UUID.t(), keyword()) :: map()
  def refold!(tenant, golden_id, opts \\ []) do
    {:ok, result} =
      Ash.transaction([Person, AttributeAssertion], fn ->
        golden = locked_root!(tenant, golden_id, MapSet.new())
        fold_and_write!(tenant, golden, opts)
      end)

    result
  end

  @doc """
  What a merge of `loser` into `survivor` would resolve to, written to nothing.
  Adds `:loser_ids`, every id on the loser's side of the merge.
  """
  @spec preview_merge(term(), struct(), struct(), map()) :: map()
  def preview_merge(tenant, survivor, loser, policy) do
    edges = [{loser.id, survivor.id} | chain_edges(tenant, [survivor.id, loser.id])]
    depths = Assertions.chain_depths(survivor.id, edges)

    policy
    |> Assertions.standing(statements(tenant, Map.keys(depths)),
      depths: depths,
      incumbent: &held?/1
    )
    |> Map.put(:loser_ids, loser.id |> Assertions.chain_depths(edges) |> Map.keys())
  end

  @doc "Takes the locks a change to these goldens needs, for the rest of the transaction."
  @spec lock!(term(), [Ash.UUID.t()]) :: :ok
  def lock!(tenant, golden_ids) do
    AdvisoryLock.xact_lock_audit_log!(Person, tenant)

    golden_ids
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&AdvisoryLock.xact_lock!(@lock_namespace, &1))
  end

  defp locked_root!(tenant, id, seen) do
    lock!(tenant, [id])
    person = Ash.get!(Person, id, tenant: tenant, authorize?: false)

    case person do
      %{merged: true, master_id: master_id} when not is_nil(master_id) ->
        if MapSet.member?(seen, master_id),
          do: person,
          else: locked_root!(tenant, master_id, MapSet.put(seen, id))

      _golden ->
        person
    end
  end

  defp fold_and_write!(tenant, golden, opts) do
    depths = Assertions.chain_depths(golden.id, chain_edges(tenant, [golden.id]))
    existing = statements(tenant, Map.keys(depths))

    all =
      if Keyword.get(opts, :materialize_held, true),
        do: existing ++ materialize_held!(tenant, golden, existing),
        else: existing

    standing = Assertions.standing(governing(tenant).policy, all,
        depths: depths,
        incumbent: &held?/1
      )

    written =
      if Keyword.get(opts, :write?, true),
        do: write!(tenant, golden, standing.merged),
        else: golden

    Map.put(standing, :golden, written)
  end

  # The materialized held value, and only that: it ranks after a person and
  # before the oldest-first order, so history dated before the column's value
  # cannot replace it, while a steward still can.
  defp held?(%{source: @held_source, origin_ref: %{"held" => true}}), do: true
  defp held?(_statement), do: false

  defp materialize_held!(tenant, golden, statements) do
    for attribute <- @attributes,
        value = column(golden, attribute),
        not Enum.any?(statements, &says?(&1, attribute, value)) do
      assert_one!(tenant, golden.id, attribute, value, %{
        origin_kind: :import,
        source: @held_source,
        origin_ref: %{"held" => true},
        observed_at: golden.inserted_at
      })
    end
  end

  # Any statement of this value counts, retracted ones included: a value that
  # was retracted must not come back as a held one. One still waiting on a
  # person, or refused, is not what the column holds.
  defp says?(statement, attribute, value) do
    statement.attribute == attribute and statement.origin_kind != :retraction and
      statement.band in [nil, :admit] and
      normal(attribute, Assertions.unwrap_value(statement.value)) == normal(attribute, value)
  end

  defp write!(tenant, golden, merged) do
    changes =
      @attributes
      |> Enum.reject(&(normal(&1, column(golden, &1)) == normal(&1, merged[&1])))
      |> Map.new(&{&1, merged[&1]})
      |> drop_taken_email(tenant, golden)

    if map_size(changes) == 0 do
      golden
    else
      golden
      |> Ash.Changeset.for_update(:mdm_survivor_update, changes,
        tenant: tenant,
        authorize?: false
      )
      |> Ash.update!(tenant: tenant, authorize?: false)
    end
  end

  # One person per address. A pre-check rather than a rescue: a refold can run
  # inside a batch transaction, and a violation there would abort all of it.
  # The statement stands and the person keeps the address it has.
  defp drop_taken_email(%{"email" => email} = changes, tenant, golden) when is_binary(email) do
    taken? =
      Person
      |> Ash.Query.filter(email == ^email and id != ^golden.id)
      |> Ash.exists?(tenant: tenant, authorize?: false)

    if taken?, do: Map.delete(changes, "email"), else: changes
  end

  defp drop_taken_email(changes, _tenant, _golden), do: changes

  defp assert_one!(tenant, golden_id, attribute, value, origin) do
    AttributeAssertion
    |> Ash.Changeset.for_create(
      :assert,
      Map.merge(origin, %{
        golden_resource: @golden_resource,
        golden_id: golden_id,
        attribute: attribute,
        value: value
      }),
      tenant: tenant,
      authorize?: false
    )
    |> Ash.create!(tenant: tenant, authorize?: false)
  end

  defp chain_edges(tenant, frontier, seen \\ MapSet.new(), edges \\ [])
  defp chain_edges(_tenant, [], _seen, edges), do: edges

  defp chain_edges(tenant, frontier, seen, edges) do
    seen = MapSet.union(seen, MapSet.new(frontier))

    absorbed =
      Person
      |> Ash.Query.filter(merged == true and master_id in ^frontier)
      |> Ash.Query.select([:id, :master_id])
      |> Ash.read!(tenant: tenant, authorize?: false)

    new_edges = Enum.map(absorbed, &{&1.id, &1.master_id})
    next = absorbed |> Enum.map(& &1.id) |> Enum.reject(&MapSet.member?(seen, &1))

    chain_edges(tenant, next, seen, new_edges ++ edges)
  end

  defp statements(tenant, golden_ids) do
    AttributeAssertion
    |> Ash.Query.filter(
      golden_resource == ^@golden_resource and golden_id in ^golden_ids and
        attribute in ^@attributes
    )
    |> Ash.read!(tenant: tenant, authorize?: false)
  end

  defp source_statements(tenant, golden_id, source) do
    AttributeAssertion
    |> Ash.Query.filter(
      golden_resource == ^@golden_resource and golden_id == ^golden_id and source == ^source
    )
    |> Ash.read!(tenant: tenant, authorize?: false)
  end

  defp said?(existing, attribute, value, observed_at) do
    from_attribute = Enum.filter(existing, &(&1.attribute == attribute))

    Enum.any?(from_attribute, &same_statement?(&1, attribute, value, observed_at)) or
      newest_says?(from_attribute, attribute, value)
  end

  defp same_statement?(statement, attribute, value, observed_at) do
    DateTime.compare(statement.observed_at, observed_at) == :eq and
      normal(attribute, Assertions.unwrap_value(statement.value)) == normal(attribute, value)
  end

  defp newest_says?([], _attribute, _value), do: false

  defp newest_says?(statements, attribute, value) do
    newest = Enum.max_by(statements, &DateTime.to_unix(&1.observed_at, :microsecond))
    normal(attribute, Assertions.unwrap_value(newest.value)) == normal(attribute, value)
  end

  defp present(values) do
    values
    |> Enum.map(fn {attribute, value} -> {attribute, value && to_string(value)} end)
    |> Enum.reject(fn {_attribute, value} -> is_nil(value) or String.trim(value) == "" end)
  end

  defp column(golden, "name"), do: golden.name
  defp column(golden, "email"), do: golden.email && to_string(golden.email)

  # Two spellings of one address are one value: `email` is case-insensitive.
  defp normal("email", value) when is_binary(value), do: String.downcase(value)
  defp normal(_attribute, value), do: value
end
