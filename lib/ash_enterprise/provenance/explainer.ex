defmodule AshEnterprise.Provenance.Explainer do
  @moduledoc """
  One explainer of ADR 0078's dispatch: asked about a subject, it either does
  not answer for it (`:pass`, so the next explainer is asked) or answers with
  the steps and typed gaps it knows, the antecedents the walk dispatches again,
  and the correlation ids of the audit events its activities name.

  The subject is `%{address, resource, record, field, value}` — the record was
  read as the reader, and `value` is what the reader got for the field, possibly
  `%Ash.ForbiddenField{}`. The context is `%{actor, tenant, base, registry,
  cache}`; `cache` is the walk's per-call memo of labels, keyed by the walk, so
  one read of one person serves every step that names them.

  Every read an explainer makes is the reader's own, through the record's own
  read action, with their actor and tenant (ADR 0078, section 5). An explainer
  that reads past a policy is a bug.
  """

  @type subject :: %{
          required(:address) => AshProvenance.Address.t(),
          required(:resource) => Ash.Resource.t(),
          required(:record) => Ash.Resource.record(),
          required(:field) => atom() | nil,
          required(:value) => term()
        }

  @type ctx :: %{
          required(:actor) => term(),
          required(:tenant) => term(),
          required(:base) => String.t(),
          required(:registry) => module(),
          required(:cache) => map()
        }

  @type answer :: %{
          required(:steps) => [AshProvenance.Step.t()],
          required(:gaps) => [AshProvenance.Gap.t()],
          required(:antecedents) => [subject()],
          optional(:correlation_ids) => %{String.t() => Ecto.UUID.t()},
          optional(:cache) => map()
        }

  @callback explain(subject(), ctx()) :: :pass | {:ok, answer()}

  alias AshProvenance.Address

  @doc """
  What a step may show of a field the reader read.

  A value the reader may not see is masked, never empty (ADR 0078, section 6):
  an empty string or null would read as a known, empty value. A readable scalar
  is shown; maps, lists and `sensitive?` fields — including secured columns,
  which are always `sensitive?` — are not shown at all.
  """
  @spec render_value(Ash.Resource.t(), atom() | nil, term()) ::
          :masked | {:value, String.t() | number() | boolean()} | nil
  def render_value(_resource, _field, %Ash.ForbiddenField{}), do: :masked

  def render_value(resource, field, raw) do
    cond do
      sensitive?(resource, field) ->
        nil

      shown = scalar(raw) ->
        {:value, shown}

      true ->
        nil
    end
  end

  # A readable scalar is shown. The marker a shredded value renders as is not
  # (`AshEnterprise.Erasure.Shredded.rendered/0`): no step carries the
  # shredded value or the marker that stands in for it (ADR 0078, section 3) —
  # the `:erased` gap says why instead.
  defp scalar(raw) when is_binary(raw) do
    if raw == AshEnterprise.Erasure.Shredded.rendered() or not String.valid?(raw),
      do: nil,
      else: raw
  end

  defp scalar(raw) when is_number(raw) or is_boolean(raw), do: raw

  defp scalar(_other), do: nil

  @doc """
  Whether `field` is an ADR 0073 secured column: readable only through a role
  granting the column's own privilege. What a derivation reads of it, and that
  it changed at all, is what the grant withholds — so it is never dispatch
  material and never shown.
  """
  @spec secured?(Ash.Resource.t(), atom()) :: boolean()
  def secured?(resource, field) do
    field in Spark.Dsl.Extension.get_opt(resource, [:platform], :secured_fields, [])
  end

  @doc """
  Whether `field` of `resource` is sensitive: an attribute's own `sensitive?`,
  or that of the calculation or aggregate the field names.
  """
  @spec sensitive?(Ash.Resource.t(), atom() | nil) :: boolean()
  def sensitive?(_resource, nil), do: false

  def sensitive?(resource, field) when is_atom(field) do
    Enum.any?(
      [
        Ash.Resource.Info.attribute(resource, field),
        Ash.Resource.Info.calculation(resource, field),
        Ash.Resource.Info.aggregate(resource, field)
      ],
      &(&1 && &1.sensitive?)
    )
  end

  @doc "The address of `field` on the same record a subject was read from."
  @spec field_address(subject(), atom()) :: {:ok, Address.t()} | {:error, term()}
  def field_address(%{address: address}, field) when is_atom(field) do
    Address.new(%{
      base: address.base,
      type: address.type,
      id: address.id,
      as_of: address.as_of,
      attribute: Atom.to_string(field)
    })
  end

  @doc "The subject of `field`, read from the same record the subject was read from."
  @spec field_subject(subject(), atom()) :: {:ok, subject()} | {:error, term()}
  def field_subject(%{record: record, resource: resource, value: _} = subject, field) do
    with {:ok, address} <- field_address(subject, field) do
      {:ok,
       %{
         address: address,
         resource: resource,
         record: record,
         field: field,
         value: Map.get(record, field)
       }}
    end
  end
end
