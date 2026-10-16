defmodule AshEnterprise.Audit.Changes.RedactSensitive do
  @moduledoc """
  Keeps `sensitive?` values out of the audit log. Runs on every event the log
  records, before the row is inserted and hashed into its chain.

  `ash_events` already writes a sensitive attribute or argument as `nil` in an
  event's `data`, but it builds `changed_attributes` (the attributes an action
  set that were not inputs) without checking `sensitive?`. Anything a change
  computes therefore landed in the log in the clear. The first case found was
  `User.hashed_password`, which `HashPasswordChange` sets from the `password`
  argument, so every registration and password change wrote a bcrypt hash into
  a table that can never be cleaned.

  The rule, for the source resource and action an event describes:

    * a `sensitive?` attribute keeps its key in `data`, `changed_attributes`
      and `metadata`, with the value `nil`. The key stays so the log still
      shows *that* the attribute changed (a password change is an auditable
      fact). The value goes. `nil` is the same marker `ash_events` uses in
      `data`, so the log has one convention;
    * a `sensitive?` argument of the action gets the same treatment;
    * **except** the `encrypted_*` columns `ash_cloak` adds for a cloaked
      attribute. `ash_cloak` marks them `sensitive?`, but their value is
      ciphertext sealed under an erasure-scope key, and ADR 0024 relies on the
      audit copy being that ciphertext: shredding the key makes it unreadable
      without changing a row. In this application every cloaked attribute is
      sealed by `AshEnterprise.Erasure.Changes.SealUnderScope`; the app vault
      refuses to encrypt anything itself.

  There is no per-attribute audit opt-out other than `sensitive?`. A value that
  must never reach the log is marked `sensitive?` on the resource, and this
  change does the rest.
  """

  use Ash.Resource.Change

  @fields [:data, :changed_attributes, :metadata]

  @impl true
  def change(changeset, _opts, _context) do
    resource = Ash.Changeset.get_attribute(changeset, :resource)
    action = Ash.Changeset.get_attribute(changeset, :action)

    case redacted_names(resource, action) do
      [] -> changeset
      names -> redact_fields(changeset, MapSet.new(names, &to_string/1))
    end
  end

  @doc """
  The attribute and argument names whose values the log must not hold for an
  event on `resource`'s `action`.
  """
  @spec redacted_names(module() | term(), atom() | term()) :: [atom()]
  def redacted_names(resource, action) do
    if is_atom(resource) and Ash.Resource.Info.resource?(resource) do
      Enum.uniq(sensitive_attributes(resource) ++ sensitive_arguments(resource, action))
    else
      []
    end
  end

  defp redact_fields(changeset, names) do
    Enum.reduce(@fields, changeset, &redact_field(&2, &1, names))
  end

  defp redact_field(changeset, field, names) do
    case Ash.Changeset.get_attribute(changeset, field) do
      map when is_map(map) and map_size(map) > 0 ->
        Ash.Changeset.force_change_attribute(changeset, field, redact(map, names))

      _ ->
        changeset
    end
  end

  defp sensitive_attributes(resource) do
    ciphertext = ciphertext_columns(resource)

    for %{sensitive?: true, name: name} <- Ash.Resource.Info.attributes(resource),
        to_string(name) not in ciphertext,
        do: name
  end

  defp sensitive_arguments(resource, action) when is_atom(action) and not is_nil(action) do
    case Ash.Resource.Info.action(resource, action) do
      %{arguments: arguments} -> for %{sensitive?: true, name: name} <- arguments, do: name
      _ -> []
    end
  end

  defp sensitive_arguments(_resource, _action), do: []

  # `ash_cloak` renames a cloaked attribute `x` to `encrypted_x`. Compared as
  # strings so no atom is built from configuration.
  defp ciphertext_columns(resource) do
    if AshCloak in Spark.extensions(resource) do
      resource
      |> AshCloak.Info.cloak_attributes!()
      |> Enum.map(&"encrypted_#{&1}")
    else
      []
    end
  end

  defp redact(map, names) do
    Map.new(map, fn {key, value} ->
      if MapSet.member?(names, to_string(key)), do: {key, nil}, else: {key, value}
    end)
  end
end
