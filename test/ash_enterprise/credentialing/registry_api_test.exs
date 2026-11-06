defmodule AshEnterprise.Credentialing.RegistryApiTest do
  @moduledoc """
  The credential registry's declared operations, as wiring: what this host declares and
  grants. Engine semantics (the retry table, spec pinning, error typing) belong to the
  `ash_operations` suite (ADR 0063); here are the host's own facts: every operation is a
  generic action with a code interface, none carries a credential, the pin names the vendored
  file, the transport resolves its key at call time, and only the governed act reaches the
  registry.
  """

  # async: false. It swaps this transport's application env, which is node-global.
  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  alias AshEnterprise.Credentialing.{DemoData, RegistryApi}
  alias AshEnterprise.Credentialing.RegistryApi.Transport
  alias AshEnterprise.Security.ActorContext

  @moduletag evidence: true

  setup do
    previous = Application.get_env(:ash_enterprise, Transport)
    on_exit(fn -> AshEnterprise.Test.RegistryActivation.restore_env(Transport, previous) end)
    :ok
  end

  test "every registry operation is a generic action with a code interface" do
    operations = AshOperations.Info.operations(RegistryApi)

    assert Enum.sort(Enum.map(operations, & &1.name)) == [
             :activate,
             :get_activation,
             :list_activations
           ]

    for %{name: name} <- operations do
      assert %{type: :action} = Ash.Resource.Info.action(RegistryApi, name)
      assert function_exported?(RegistryApi, name, 2), "no code interface for #{name}"
    end
  end

  test "no registry operation takes a credential, connection or tenant argument" do
    forbidden = ~r/^(credential|tenant|authorization|bearer)$|key|token|secret|connection/

    names =
      for %{name: name} <- AshOperations.Info.operations(RegistryApi),
          argument <- Ash.Resource.Info.action(RegistryApi, name).arguments,
          do: Atom.to_string(argument.name)

    assert names != []
    refute Enum.filter(names, &Regex.match?(forbidden, &1)) != [], inspect(names)
  end

  test "the resource pins the vendored spec file" do
    path = AshOperations.Info.spec(RegistryApi)
    assert path == "priv/vendor/credential_registry/openapi.json"

    sha = path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    assert AshOperations.Info.spec_sha256(RegistryApi) == sha
    assert File.exists?("priv/vendor/credential_registry/README.md")
  end

  test "the transport reads its key at call time and is not configured without a URL and key" do
    # No URL: the in-process fake answers, in the cluster.
    Application.put_env(:ash_enterprise, Transport, base_url: nil, api_key: nil)

    assert {:ok, %{req_options: [plug: AshEnterprise.Credentialing.Registry.FakeProvider]}} =
             Transport.config()

    assert Transport.residency() == :in_cluster

    # A URL with no key is not configured: nothing is sent, and no key is invented.
    Application.put_env(:ash_enterprise, Transport,
      base_url: "https://registry.test",
      api_key: nil
    )

    assert Transport.config() == {:error, :not_configured}

    Application.put_env(:ash_enterprise, Transport,
      base_url: "https://registry.test",
      api_key: ""
    )

    assert Transport.config() == {:error, :not_configured}

    # The key is read on every call, so a rotation needs no restart.
    Application.put_env(:ash_enterprise, Transport,
      base_url: "https://registry.test",
      api_key: "one"
    )

    assert {:ok, %{auth: {:bearer, "one"}}} = Transport.config()

    Application.put_env(:ash_enterprise, Transport,
      base_url: "https://registry.test",
      api_key: "two"
    )

    assert {:ok, %{auth: {:bearer, "two"}, base_url: "https://registry.test"}} =
             Transport.config()

    assert Transport.residency() == :sub_processor
  end

  test "a direct call as a committee member is forbidden; a governed call is admitted" do
    admin = tenant!()
    clinic = DemoData.populate(admin.tenant)
    Oban.drain_queue(queue: :execution)

    member = hd(clinic.committee)
    member_actor = ActorContext.attach(member, ActorContext.build(member, tenant: admin.tenant))

    for actor <- [member_actor, admin.actor] do
      opts = [actor: actor, tenant: admin.tenant]
      assert {:error, %Ash.Error.Forbidden{}} = RegistryApi.list_activations(%{}, opts)

      assert {:error, %Ash.Error.Forbidden{}} =
               RegistryApi.get_activation(%{activation_id: "x"}, opts)

      refute Ash.can?(
               Ash.ActionInput.for_action(RegistryApi, :list_activations, %{}, opts),
               actor
             )

      # The governed act's own context (what the executor and the reconciler pass) is
      # admitted, with no role grant at all.
      governed = Keyword.put(opts, :context, %{ash_agent: %{invocation_id: Ash.UUID.generate()}})

      assert Ash.can?(
               Ash.ActionInput.for_action(RegistryApi, :list_activations, %{}, governed),
               actor
             )
    end
  end

  test "a credential reference is the organization and the credential, and nothing else" do
    {org, credential} = {Ash.UUID.generate(), Ash.UUID.generate()}
    reference = RegistryApi.reference(org, credential)
    assert RegistryApi.parse_reference(reference) == {:ok, {org, credential}}
    assert RegistryApi.parse_reference("not-a-reference") == :error
    assert RegistryApi.parse_reference(nil) == :error
  end
end
