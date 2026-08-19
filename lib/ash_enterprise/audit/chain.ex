defmodule AshEnterprise.Audit.Chain do
  @moduledoc """
  Verification for the audit log's hash chain.

  `AshEnterprise.Audit.EventLog` chains every event to the one before it, per
  tenant. This module walks a chain and reports the first place it stops adding
  up. That is the whole point of a chain: not that history cannot be edited —
  a sufficiently privileged operator can always edit a table — but that editing
  it cannot be made to *look* untouched.

  ## What a break means

  Three distinguishable findings, because they have different causes:

    * `:altered` — a row's stored hash does not match a hash recomputed from its
      own contents. Someone changed the row.
    * `:broken_link` — a row's `previous_hash` does not match the hash of the row
      before it in sequence. Someone removed a row, or inserted one out of band.
    * `:unchained` — a row has no hash at all, after rows that do. In practice
      this means the insert trigger was dropped, which is what an operator would
      do first if they intended to edit quietly.

  Rows written *before* the chain existed also have no hash. Those are not a
  finding: `verify/1` reports where the chain starts and treats everything
  earlier as out of scope, because claiming tamper-evidence over rows that never
  had it would be a lie in the opposite direction.

  ## Reading it back the way it was written

  The digest is recomputed here in SQL, using the same expression the trigger
  uses, rather than reassembled in Elixir. Two implementations of one canonical
  form is how a verifier ends up disagreeing with reality about `NULL`s, JSON key
  order and timestamp formatting — and a verifier that reports false breaks gets
  switched off.
  """

  alias AshEnterprise.Repo

  @type finding ::
          %{
            sequence: integer(),
            id: Ash.UUID.t(),
            occurred_at: DateTime.t(),
            problem: :altered | :broken_link | :unchained
          }

  @type result :: %{
          organization_id: Ash.UUID.t() | nil,
          checked: non_neg_integer(),
          skipped_unchained_prefix: non_neg_integer(),
          findings: [finding()]
        }

  @doc """
  Verifies one tenant's chain. `nil` verifies the chain of events with no tenant.

  Returns a summary; `findings: []` is a clean chain.
  """
  @spec verify(Ash.UUID.t() | nil) :: result()
  def verify(organization_id) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH chained AS (
          SELECT
            sequence,
            id,
            occurred_at,
            hash,
            previous_hash,
            lag(hash) OVER (ORDER BY sequence) AS actual_previous,
            encode(sha256(convert_to(concat_ws('|',
              coalesce(lag(hash) OVER (ORDER BY sequence), ''),
              sequence::text,
              id::text,
              record_id::text,
              version::text,
              occurred_at::text,
              resource,
              action,
              action_type,
              coalesce(user_id::text, ''),
              coalesce(organization_id::text, ''),
              data::text,
              changed_attributes::text,
              metadata::text
            ), 'UTF8')), 'hex') AS recomputed
          FROM audit_events
          WHERE organization_id IS NOT DISTINCT FROM $1::uuid
        )
        SELECT sequence, id, occurred_at, hash, previous_hash, actual_previous, recomputed
        FROM chained
        ORDER BY sequence
        """,
        [organization_id && Ecto.UUID.dump!(organization_id)]
      )

    {unchained_prefix, chained} = split_prefix(rows)

    %{
      organization_id: organization_id,
      checked: length(chained),
      skipped_unchained_prefix: length(unchained_prefix),
      findings: chained |> Enum.map(&examine/1) |> Enum.reject(&is_nil/1)
    }
  end

  @doc """
  Verifies every chain in the log — one per tenant, plus the untenanted one.
  """
  @spec verify_all() :: [result()]
  def verify_all do
    %{rows: rows} =
      Repo.query!("SELECT DISTINCT organization_id FROM audit_events ORDER BY 1 NULLS FIRST")

    Enum.map(rows, fn [org] -> verify(org && Ecto.UUID.cast!(org)) end)
  end

  # Rows predating the chain carry no hash. They are only ignorable while they
  # form an unbroken run at the very start -- an unchained row appearing *after*
  # a chained one is the trigger having been dropped, which is a finding.
  defp split_prefix(rows), do: Enum.split_while(rows, fn [_, _, _, hash | _] -> is_nil(hash) end)

  defp examine([sequence, id, occurred_at, hash, previous_hash, actual_previous, recomputed]) do
    finding = fn problem ->
      %{
        sequence: sequence,
        id: Ecto.UUID.cast!(id),
        occurred_at: occurred_at,
        problem: problem
      }
    end

    cond do
      is_nil(hash) -> finding.(:unchained)
      previous_hash != actual_previous -> finding.(:broken_link)
      hash != recomputed -> finding.(:altered)
      true -> nil
    end
  end
end
