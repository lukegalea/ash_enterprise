defmodule AshEnterprise.Journeys.World do
  @moduledoc """
  The world a journey runs in (`AshJourneys.World`): one SYNTHETIC organization,
  seeded the way `mix ash_enterprise.seed` and `mix ash_enterprise.demo` seed one,
  with the people a journey binds.

  Only the browser tier calls it, inside a test's sandbox, before a journey's
  first step.

  ## Bindings

  A journey binds each person as `{kind, name}`: `{:tenant_admin, "admin"}` is the
  organization's administrator, `{:member, "dana"}` a person in its root business
  unit with no role. Each is `<name>@example.com`, so a figure shows the same
  people on every run. A world has exactly one administrator. Each bound user
  carries its kind as `__metadata__.journey_role`, which
  `AshEnterprise.Journeys.Personas` checks a persona's role against.

  Nobody signs in with a password (the browser tier signs a persona in by its
  session cookie), so each person gets a random one.

  ## Timestamps

  `pin_timestamps/3` writes each listed attribute as the world's clock plus its
  offset, with `Ash.Seed.update!/2`, after the records were created through their
  actions. The data stays what the actions made; only the instant it shows is
  chosen, so a figure that displays it is the same on every run.
  """

  @behaviour AshJourneys.World

  alias AshEnterprise.Platform.DemoData
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Platform.SystemActor

  @kinds [:tenant_admin, :member]
  @organization "Example Corp"

  @doc "The name of the organization every journey's world seeds."
  @spec organization_name() :: String.t()
  def organization_name, do: @organization

  @impl true
  def seed(%{packs: [_pack | _rest] = packs}, _opts),
    do: {:error, "this world seeds no packs, and #{inspect(packs)} were asked for"}

  def seed(%{bind: bind}, _opts) do
    with :ok <- check_kinds(bind),
         [{admin, {:tenant_admin, admin_name}}] <-
           Enum.filter(bind, &match?({_binding, {:tenant_admin, _name}}, &1)) do
      seeded =
        Seeder.seed_tenant(
          name: @organization,
          unique_name: "example",
          email: email(admin_name),
          password: password()
        )

      tenant = seeded.organization.id
      root = DemoData.root_business_unit!(tenant, SystemActor.seed())

      {:ok,
       Map.new(bind, fn
         {^admin, _ref} ->
           {admin, role(seeded.user, :tenant_admin)}

         {binding, {:member, name}} ->
           {binding, role(DemoData.ensure_user!(email(name), root, tenant, password()), :member)}
       end)}
    else
      {:error, _reason} = error -> error
      _not_one -> {:error, "a world binds exactly one {:tenant_admin, name}"}
    end
  end

  @impl true
  def pin_timestamps(bindings, clock, pins) do
    Enum.each(pins, fn {binding, attributes} ->
      values =
        Map.new(attributes, fn {attribute, seconds} ->
          {attribute, DateTime.add(clock, seconds)}
        end)

      Ash.Seed.update!(Map.fetch!(bindings, binding), values)
    end)
  end

  defp check_kinds(bind) do
    case Enum.reject(
           bind,
           &match?({_binding, {kind, name}} when kind in @kinds and is_binary(name), &1)
         ) do
      [] ->
        :ok

      unknown ->
        {:error,
         "unknown bindings #{inspect(unknown)}; a binding is {kind, name}, kind one of #{inspect(@kinds)}"}
    end
  end

  defp role(user, kind), do: Ash.Resource.put_metadata(user, :journey_role, kind)

  defp email(name), do: "#{name}@example.com"

  defp password, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
end
