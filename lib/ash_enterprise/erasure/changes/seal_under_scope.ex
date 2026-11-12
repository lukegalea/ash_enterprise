defmodule AshEnterprise.Erasure.Changes.SealUnderScope do
  @moduledoc """
  Seals cloaked content under the erasure scope the row names.

      change {AshEnterprise.Erasure.Changes.SealUnderScope, fields: [:body]},
        on: [:create, :update]

  `changes:` names fields no argument carries because an action's own changes write
  them to the attribute itself (`Ash.Changeset.force_change_attribute/3`): a
  package's fragment can write one where no caller input exists. Sealed the same way,
  from the pending attribute change, which is then cleared.

  On a resource using `AshCloak`, each cloaked attribute `x` arrives as a
  sensitive *argument* `x`, and `ash_cloak` encrypts it into `encrypted_x` with
  a vault that has no record in hand. This change does that job instead, with
  the record in hand: it reads `erasure_scope_id` off the changeset, seals the
  value under that scope's key (`AshEnterprise.Erasure.Keyring.seal/2`), writes
  the result to `encrypted_x`, and removes the argument — so `ash_cloak`'s own
  encrypt hook, which would otherwise call `AshEnterprise.Erasure.Vault.encrypt!/1`
  and raise, finds nothing left to encrypt.

  It runs in `change/3`, not in a hook, because Ash checks required attributes
  before `before_action` hooks run, and `encrypted_x` is required wherever `x`
  was.

  ## Byte-compatible with `ash_cloak`

  The plaintext is serialized exactly as `ash_cloak` serializes it (the
  `:__ash_cloak__` tag when the embedded form differs from the value,
  `term_to_binary/1` otherwise) and stored base64-encoded, so `ash_cloak`'s
  decrypt calculation reads it back unchanged. `nil` stays SQL `NULL`, matching
  `encrypt_nil? false`.

  ## Refusals

    * no `erasure_scope_id` on the changeset — an error on that field; content
      is never stored unsealed and never sealed under a guessed scope;
    * a shredded scope — an error naming it; nothing new lands under a scope
      whose key is gone. Checked twice: when sealing, and again inside the
      write's transaction under a `FOR SHARE` lock on the scope row, so a shred
      racing the write either reaches the row or refuses it;
    * a scope id nobody issued — an error, before the foreign key would.

  ## Temporal safety (ADR 0049 invariant 4)

  It runs on `AshEnterprise.Canonical.CalendarEvent`, which is temporal, so
  it declares `temporal_safe?/1`. Nothing here depends on when: a scope owns
  one key for its whole life, so the key that seals a version is the same
  whatever instant the write is as of, and a shredded scope refuses every
  instant alike. It reads no clock; the scope and key are read through Ash
  (`AshEnterprise.Erasure.Keyring`, the `FOR SHARE` recheck), and neither is
  temporal. Every version of an event is sealed under the same scope key,
  which is why one shred reaches all of them.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Erasure.{Keyring, Scope}

  @scope_attribute :erasure_scope_id

  @impl true
  def init(opts) do
    fields = List.wrap(opts[:fields])
    changes = List.wrap(opts[:changes])

    cond do
      fields == [] and changes == [] ->
        {:error, "fields and changes must name at least one attribute to seal"}

      not Enum.all?(fields ++ changes, &is_atom/1) ->
        {:error, "fields and changes must be lists of atoms"}

      true ->
        {:ok, opts}
    end
  end

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, opts, _context) do
    case sealing(changeset, opts) do
      [] -> changeset
      present -> seal(changeset, present)
    end
  end

  # Nothing to seal means nothing that needs the record; with content present,
  # sealing needs the scope id and a key lookup, which an atomic update cannot do.
  @impl true
  def atomic(changeset, opts, _context) do
    case sealing(changeset, opts) do
      [] -> {:ok, changeset}
      _present -> {:not_atomic, "sealing content under its erasure scope needs the scope's key"}
    end
  end

  defp sealing(changeset, opts) do
    for {field, source} <- sources(opts),
        match?({:ok, _}, value_of(changeset, field, source)),
        do: {field, source}
  end

  defp sources(opts) do
    Enum.flat_map([{:fields, :argument}, {:changes, :change}], fn {key, source} ->
      for field <- List.wrap(opts[key]), do: {field, source}
    end)
  end

  defp value_of(changeset, field, :argument), do: Ash.Changeset.fetch_argument(changeset, field)
  defp value_of(changeset, field, :change), do: Ash.Changeset.fetch_change(changeset, field)

  defp seal(changeset, fields) do
    case Ash.Changeset.get_attribute(changeset, @scope_attribute) do
      nil ->
        Ash.Changeset.add_error(changeset,
          field: @scope_attribute,
          message: "is required: content is sealed under the erasure scope it came in through"
        )

      scope_id ->
        fields
        |> Enum.reduce(changeset, &seal_field(&2, &1, scope_id))
        |> Ash.Changeset.before_action(&recheck_scope_live(&1, scope_id))
    end
  end

  # The seal above ran before the write's transaction. A shred that commits
  # between then and the insert would let the row land under a scope that is
  # already shredded. Inside the transaction, take a FOR SHARE lock on the
  # scope row and re-check it: `Scope.shred` updates that row, so the two
  # writes serialize -- either this landing commits first (and the shred then
  # reaches it), or the shred does and this landing is refused.
  defp recheck_scope_live(changeset, scope_id) do
    Scope
    |> Ash.Query.filter(id == ^scope_id)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Scope{status: :active}} ->
        changeset

      {:ok, %Scope{status: :shredded}} ->
        Ash.Changeset.add_error(changeset,
          field: @scope_attribute,
          message: "erasure scope %{scope} has been shredded; nothing may land under it",
          vars: [scope: scope_id]
        )

      {:ok, nil} ->
        Ash.Changeset.add_error(changeset,
          field: @scope_attribute,
          message: "erasure scope %{scope} does not exist",
          vars: [scope: scope_id]
        )

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp seal_field(changeset, {field, source}, scope_id) do
    {:ok, value} = value_of(changeset, field, source)
    # Law 10: the encrypted_<field> attribute is declared by the erasure DSL for each
    # sealed field (a closed set) — to_existing_atom is the safe spelling.
    target = String.to_existing_atom("encrypted_#{field}")

    case sealed_value(changeset.resource, field, source, value, scope_id) do
      {:ok, sealed} ->
        changeset
        |> Ash.Changeset.force_change_attribute(target, sealed)
        |> drop(field, source)

      {:error, :shredded} ->
        Ash.Changeset.add_error(changeset,
          field: @scope_attribute,
          message: "erasure scope %{scope} has been shredded; nothing may land under it",
          vars: [scope: scope_id]
        )

      {:error, :unknown_scope} ->
        Ash.Changeset.add_error(changeset,
          field: @scope_attribute,
          message: "erasure scope %{scope} does not exist",
          vars: [scope: scope_id]
        )
    end
  end

  # A sealed argument is deleted, so `ash_cloak`'s own encrypt hook finds nothing; a
  # sealed change is cleared, so its plaintext never reaches the column.
  defp drop(changeset, field, :argument), do: Ash.Changeset.delete_argument(changeset, field)
  defp drop(changeset, field, :change), do: Ash.Changeset.clear_change(changeset, field)

  defp sealed_value(_resource, _field, _source, nil, _scope_id), do: {:ok, nil}

  defp sealed_value(resource, field, source, value, scope_id) do
    with {:ok, sealed} <- Keyring.seal(scope_id, serialize(resource, field, source, value)) do
      {:ok, Base.encode64(sealed)}
    end
  end

  # Mirrors AshCloak's private `serialize/3`, which its decrypt calculation is
  # the inverse of. Kept in step deliberately: the round-trip test for every
  # cloaked type in this app is what notices if ash_cloak changes the format.
  defp serialize(resource, field, source, value) do
    %{type: type, constraints: constraints} = spec_of(resource, field, source)

    case Ash.Type.dump_to_embedded(type, value, constraints) do
      {:ok, dumped} when dumped !== value ->
        :erlang.term_to_binary({:__ash_cloak__, dumped})

      {:ok, _dumped} ->
        :erlang.term_to_binary(value)

      other ->
        raise ArgumentError, "cannot serialize #{inspect(field)} for sealing: #{inspect(other)}"
    end
  end

  # An argument's type is the calculation `ash_cloak` left in the attribute's place; a
  # change's is the attribute's own.
  defp spec_of(resource, field, :argument), do: Ash.Resource.Info.calculation(resource, field)
  defp spec_of(resource, field, :change), do: Ash.Resource.Info.attribute(resource, field)
end
