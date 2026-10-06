defmodule AshEnterprise.Canonical.Projection do
  @moduledoc """
  Raw → canonical projections (epic E4, ADR 0037's host-declared pattern,
  dogfood §11).

  The host declares the mapping; there is no library convention to fork. This
  module reads `AshEnterprise.Ingestion.SourceObject` rows and deterministically
  upserts canonical rows derived from their `raw_payload` maps — pure-ish by
  contract: everything projected is a function of the payload, never of wall
  clocks, actors or process state (the only inputs beyond the payload are the
  replay context below: *whose* rows these are).

  Deterministic replay is the correctness proof: delete every canonical row,
  run `replay/2` again, and the projected rows come back byte-identical. The
  fixture test proves exactly that. Re-landing the same raw rows (landing is
  upsert-refresh, not append-only) then re-replaying is equally a no-op: the
  upserts converge on the same values, so zero diffs.

  ## Replay context

  Canonical rows are the operator's own (`:user_owned`) or the workspace's
  (`:organization_owned`), so a replay must say whose tenant and which owner it
  writes as. Resolution order:

    1. Explicit opts: `replay(:calendar, owner: user, tenant: org)`.
    2. Config: `replay_owner_email` / `replay_tenant_unique_name` under
       `config :ash_enterprise, AshEnterprise.Canonical`.
    3. Defaults equal to `AshEnterprise.Platform.Seeder.seed_tenant/1`'s
       ("admin@example.com" / "example") — the single-operator dev deployment
       this program is.

  Configuration, never action arguments — the same rule ADR 0011 sets for
  connection ids. A multi-tenant deployment must declare (1) or (2); an
  unresolvable context raises rather than guessing.

  ## Systems and projectors

  `:all` replays every system that HAS a projector (currently `:calendar`).
  Naming a system without a projector raises — a silent no-op would look like
  success while projecting nothing.

  ## Zones — READ BEFORE ADDING A PROJECTOR (ADR 0042)

  TODO(E4, Gmail/Slack verticals): Gmail and Slack SourceObjects are personal
  data NOT admitted into any declared zone — zone admission is not yet on the
  SourceObject land path (an E1 follow-up owns that). Do NOT add projectors for
  `external_system: "gmail"` or `"slack"` until admission checks each landed
  item's residency tag at `land` time. The `:calendar` projector is exempt:
  its SourceObjects come from the deterministic fixture tap, synthetic data
  with no residency exposure.
  """

  alias AshEnterprise.Canonical.{CalendarEvent, Person}
  alias AshEnterprise.Ingestion.SourceObject

  require Ash.Query

  @systems_with_projectors [:calendar]

  # The stream this projector consumes. SourceObject identity does not include
  # the stream (E1 review; fix owned by a dedicated E1 follow-up), so the
  # projector filters on it here: two streams sharing an external id cannot
  # both feed this projection.
  @calendar_stream "events"

  # Seed defaults; see the moduledoc's "Replay context".
  @default_operator_email "admin@example.com"
  @default_tenant_unique_name "example"

  @type replay_opt :: {:owner, AshEnterprise.Accounts.User.t() | Ash.UUID.t()} | {:tenant, term()}

  @spec replay(atom() | [atom()], [replay_opt()]) ::
          {:ok,
           %{
             atom() => %{
               source_objects: non_neg_integer(),
               calendar_events: non_neg_integer(),
               people: non_neg_integer()
             }
           }}

  def replay(system \\ :all, opts \\ [])

  def replay(:all, opts), do: replay(@systems_with_projectors, opts)

  def replay(system, opts) when is_atom(system) and system != :all,
    do: replay([system], opts)

  def replay(systems, opts) when is_list(systems) do
    context = replay_context(opts)

    {:ok,
     systems
     |> Map.new(&{&1, project(&1, context)})}
  end

  def replay(other, _opts) do
    raise ArgumentError,
          "replay/2 takes a system atom or a list of them (or :all), got: #{inspect(other)}"
  end

  @doc """
  The systems this module can currently project. `replay(:all)` is exactly this
  list.
  """
  def systems, do: @systems_with_projectors

  # --- per-system projectors ---------------------------------------------------

  defp project(:calendar, context) do
    # The stream filter is the mitigation for the missing-stream identity gap:
    # see @calendar_stream.
    sources =
      SourceObject
      |> Ash.Query.filter(external_system == "calendar")
      |> Ash.Query.filter(source_metadata["stream"] == ^@calendar_stream)
      |> Ash.Query.sort(:external_id)
      |> Ash.read!(authorize?: false)

    people =
      sources
      |> Enum.reduce(MapSet.new(), fn source, seen ->
        project_calendar_event(source, context, seen)
      end)
      |> MapSet.size()

    %{
      source_objects: length(sources),
      calendar_events: length(sources),
      people: people
    }
  end

  defp project(system, _context) do
    raise ArgumentError,
          "no projector for #{inspect(system)}; known systems: #{inspect(@systems_with_projectors)}"
  end

  # One raw calendar row → one upserted CalendarEvent, plus Person upserts for
  # the organizer and every attendee with an email (the v1 linkage key).
  defp project_calendar_event(source, context, people_seen) do
    payload = source.raw_payload

    organizer =
      payload
      |> Map.get("organizer", %{})
      |> upsert_person(context)

    attendees =
      payload
      |> Map.get("attendees", [])
      |> List.wrap()
      |> Enum.map(&upsert_person(&1, context))

    # Distinct person ids touched by this replay — ids, not structs: the same
    # row returned by two upserts can carry different timestamps, and the
    # count is about how many people were linked, not how many times.
    people =
      [organizer | attendees]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.id)
      |> Enum.into(people_seen)

    CalendarEvent
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      %{
        external_system: source.external_system,
        external_id: source.external_id,
        external_uid: payload["iCalUID"],
        title: required(payload, "summary", source),
        starts_at: required_datetime(payload, ["start", "dateTime"], source),
        ends_at: required_datetime(payload, ["end", "dateTime"], source),
        location: payload["location"],
        organizer_id: organizer && organizer.id,
        owner_id: context.owner_id,
        owner_type: :user,
        owning_user_id: context.owner_id,
        owning_business_unit_id: context.business_unit_id
      },
      tenant: context.tenant_id,
      authorize?: false
    )
    |> Ash.create!()

    people
  end

  # Upserts on the email identity. `upsert_fields` depends on the payload: a
  # name-less source conflicts and changes nothing (see Person.upsert_from_source).
  defp upsert_person(%{"email" => email} = contact, context) when email not in [nil, ""] do
    name = contact["displayName"]

    Person
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      %{
        email: String.trim(email),
        name: name,
        owner_id: context.owner_id,
        owner_type: :user,
        owning_user_id: context.owner_id,
        owning_business_unit_id: context.business_unit_id
      },
      tenant: context.tenant_id,
      authorize?: false
    )
    # The full upsert option set must be repeated at call time: a partial set
    # (upsert_fields alone) does not inherit the action's upsert configuration,
    # and the "upsert" silently becomes an insert. Verified against duplicates
    # before this comment existed to prevent exactly that regression.
    |> Ash.create!(
      upsert?: true,
      upsert_identity: :unique_email,
      upsert_fields: if(name in [nil, ""], do: [], else: [:name])
    )
  end

  # v1 has no fuzzy resolution: a contact without an email is not linked.
  defp upsert_person(_contact, _context), do: nil

  # --- payload readers -----------------------------------------------------------

  defp required(payload, key, source) do
    case Map.get(payload, key) do
      nil ->
        raise ArgumentError,
              "calendar SourceObject #{inspect(source.external_id)} cannot be projected: " <>
                "raw_payload is missing #{inspect(key)}"

      value ->
        value
    end
  end

  defp required_datetime(payload, path, source) do
    value =
      case get_in(payload, path) do
        nil -> nil
        iso when is_binary(iso) -> DateTime.from_iso8601(iso)
        _ -> :error
      end

    case value do
      {:ok, datetime, _offset} ->
        datetime

      _ ->
        raise ArgumentError,
              "calendar SourceObject #{inspect(source.external_id)} cannot be projected: " <>
                "#{Enum.join(path, ".")} is missing or not an ISO8601 datetime " <>
                "(got: #{inspect(get_in(payload, path))})"
    end
  end

  # --- replay context -----------------------------------------------------------

  defp replay_context(opts) do
    owner = Keyword.get_lazy(opts, :owner, &resolve_owner/0)
    tenant = Keyword.get_lazy(opts, :tenant, &resolve_tenant/0)

    owner_id = uuid_of(owner, "owner")
    tenant_id = uuid_of(tenant, "tenant")

    business_unit_id =
      case owner do
        %{owning_business_unit_id: bu} -> bu
        _ -> nil
      end

    %{
      owner_id: owner_id,
      tenant_id: tenant_id,
      business_unit_id: business_unit_id
    }
  end

  defp uuid_of(id, kind) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> raise ArgumentError, "replay context #{kind} id is not a UUID: #{inspect(id)}"
    end
  end

  defp uuid_of(%{id: id}, kind), do: uuid_of(id, kind)

  defp uuid_of(other, kind) do
    raise ArgumentError, "replay context #{kind} must be a record or UUID, got: #{inspect(other)}"
  end

  defp resolve_owner do
    email = config_get(:replay_owner_email, @default_operator_email)

    owner =
      AshEnterprise.Accounts.User
      |> Ash.Query.filter(email == ^email)
      |> Ash.Query.sort(:id)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(authorize?: false)

    owner ||
      raise ArgumentError,
            "replay cannot resolve the operator: no User with email #{inspect(email)}. " <>
              "Run `mix ash_enterprise.seed`, or set `replay_owner_email` (or pass " <>
              "`owner:` to replay/2) under config :ash_enterprise, AshEnterprise.Canonical."
  end

  defp resolve_tenant do
    unique_name = config_get(:replay_tenant_unique_name, @default_tenant_unique_name)

    tenant =
      AshEnterprise.Accounts.Organization
      |> Ash.Query.filter(unique_name == ^unique_name)
      |> Ash.Query.sort(:id)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(authorize?: false)

    tenant ||
      raise ArgumentError,
            "replay cannot resolve the tenant: no Organization with unique_name " <>
              "#{inspect(unique_name)}. Run `mix ash_enterprise.seed`, or set " <>
              "`replay_tenant_unique_name` (or pass `tenant:` to replay/2) under " <>
              "config :ash_enterprise, AshEnterprise.Canonical."
  end

  defp config_get(key, default) do
    :ash_enterprise
    |> Application.get_env(AshEnterprise.Canonical, [])
    |> Keyword.get(key, default)
  end
end
