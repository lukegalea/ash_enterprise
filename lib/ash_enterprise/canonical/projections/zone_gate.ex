defmodule AshEnterprise.Canonical.Projections.ZoneGate do
  @moduledoc """
  Zone admission for the Gmail and Slack projectors (ADR 0042): may this landed
  record be projected into the canonical model?

  `AshEnterprise.Canonical.Projections.Gmail` and `.Slack` ask once per landed
  record and project only the records admitted. The gate is configured per
  projection, never an argument:

      config :ash_enterprise, AshEnterprise.Canonical.Projections.Gmail,
        zone_gate: AshEnterprise.Canonical.Projections.ZoneAdmission

      config :ash_enterprise, AshEnterprise.Canonical.Projections.Slack,
        zone_gate: AshEnterprise.Canonical.Projections.ZoneAdmission

  The default, `AshEnterprise.Canonical.Projections.ZoneGate.DenyAll`, admits
  nothing: a template deployment declares no zone, so the honest default is to
  refuse everything. `AshEnterprise.Canonical.Projections.ZoneAdmission` is
  the real check — the record's tags (its linked account's) against the
  canonical store's declared zone.

  A refusal is an atom naming the rule, never the data. Projections count
  refusals by reason and log the counts; nothing about a refused record's
  content is read, written or logged.
  """

  @typedoc """
  The projection's replay context: whose rows these are (`owner_id`,
  `tenant_id`) and the linked accounts the records may have come through,
  by id (`linked_accounts`), so a gate never queries per record.
  """
  @type context :: %{
          required(:owner_id) => Ash.UUID.t(),
          required(:tenant_id) => Ash.UUID.t(),
          required(:linked_accounts) => %{Ash.UUID.t() => struct()},
          optional(atom()) => term()
        }

  @doc """
  Admit or refuse one landed record. `source` is the landed row (at least
  `external_id`, `raw_payload` and `source_metadata`, whose
  `"linked_account_id"` names the account it came through).
  """
  @callback admit(source :: map(), context :: context()) :: :ok | {:deny, atom()}

  @doc "The gate configured for `projection`, or `DenyAll`."
  @spec configured(module()) :: module()
  def configured(projection) do
    :ash_enterprise
    |> Application.get_env(projection, [])
    |> Keyword.get(:zone_gate, AshEnterprise.Canonical.Projections.ZoneGate.DenyAll)
  end

  @doc """
  Splits `sources` into the admitted and a count of the refused by reason.
  """
  @spec partition(module(), [map()], context()) :: {[map()], %{atom() => pos_integer()}}
  def partition(gate, sources, context) do
    Enum.reduce(sources, {[], %{}}, fn source, {admitted, refused} ->
      case gate.admit(source, context) do
        :ok ->
          {[source | admitted], refused}

        {:deny, reason} when is_atom(reason) ->
          {admitted, Map.update(refused, reason, 1, &(&1 + 1))}
      end
    end)
    |> then(fn {admitted, refused} -> {Enum.reverse(admitted), refused} end)
  end

  @doc """
  Logs a projection run's refusals: the projection, the reasons and their
  counts. Structural only — no ids, no content.
  """
  @spec log_refusals(atom(), %{atom() => pos_integer()}) :: :ok
  def log_refusals(_projection, refused) when map_size(refused) == 0, do: :ok

  def log_refusals(projection, refused) do
    require Logger

    Logger.warning(
      "zone admission refused #{refused |> Map.values() |> Enum.sum()} landed record(s) " <>
        "for the #{projection} projection: #{inspect(refused)}"
    )
  end
end
