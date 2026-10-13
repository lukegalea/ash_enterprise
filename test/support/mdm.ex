defmodule AshEnterprise.Mdm.TestSupport do
  @moduledoc """
  Shared helpers for the MDM host tests: a tenant, a person actor (the
  System One conformance drill), and Mapping lifecycle shorthands.
  """

  require Ash.Query

  alias AshEnterprise.Mdm.Mapping

  @doc "A tenant id — MDM resources scope by organization_id; no org row is needed."
  def tenant, do: Ash.UUID.generate()

  defdelegate person_actor!(opts \\ []), to: AshEnterprise.SystemOne.Support, as: :person

  def person_rules do
    [
      %{"path" => "Email", "target" => "email", "op" => "trim", "args" => %{}},
      %{"path" => "Full Name", "target" => "name", "op" => "identity", "args" => %{}}
      # Canonical.Person carries exactly name + email beyond the base's
      # system attributes — total accounting is two rules.
    ]
  end

  def draft_host_mapping!(tenant, opts) do
    attrs =
      Keyword.merge(
        [
          direction: :ingress,
          source: "manual_csv",
          stream: "acme_contacts",
          target_resource: "AshEnterprise.Canonical.Person",
          field_rules: person_rules(),
          observed_schema: %{"Email" => %{}, "Full Name" => %{}}
        ],
        opts
      )
      |> Map.new()

    Mapping
    |> Ash.Changeset.for_create(:draft, attrs, tenant: tenant, authorize?: false)
    |> Ash.create!(tenant: tenant, authorize?: false)
  end

  def validate_host_mapping!(mapping, tenant) do
    mapping
    |> Ash.Changeset.for_update(:validate, %{}, tenant: tenant, authorize?: false)
    |> Ash.update!(tenant: tenant, authorize?: false)
  end

  def activate_host_mapping!(mapping, tenant, person) do
    mapping
    |> validate_host_mapping!(tenant)
    |> Ash.reload!(tenant: tenant, authorize?: false)
    |> Ash.Changeset.for_update(:activate, %{activation_note: "test"},
      tenant: tenant,
      actor: person,
      authorize?: true
    )
    |> Ash.update!(tenant: tenant, actor: person, authorize?: true)
  end

  def stringify(nil), do: nil

  def stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  def stringify(other), do: other
end
