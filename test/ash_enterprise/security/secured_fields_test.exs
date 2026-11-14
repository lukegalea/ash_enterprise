defmodule AshEnterprise.Security.SecuredFieldsTest do
  @moduledoc """
  Column security as grants (`AshEnterprise.Platform.Resource`'s `secured_fields`): a
  secured column is read through a role granting the column's own `:read` privilege,
  `"<Resource>#<field>"`, at a depth that reaches the row, and through nothing else. The
  first secured column is `Credential.number`, the licence number.

  The refusals come first. Every way to get this wrong shows a value it should not, and
  none of them raises.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Accounts.BusinessUnit
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.Credential
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Platform.Verifiers.SecuredFields
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Security.Checks.RoleGrant
  alias AshEnterprise.Test.DailyFixtures
  alias Spark.Dsl.Transformer

  @number_key "AshEnterprise.Credentialing.Credential#number"

  setup do
    admin = DailyFixtures.tenant!()
    opts = [actor: admin.actor, tenant: admin.tenant]
    clinic = Credentialing.register_clinic!("Secured #{System.unique_integer([:positive])}", opts)

    clinician =
      Credentialing.register_clinician!(
        %{first_name: "Synthetic", last_name: "Person", job_title: "Nurse", clinic_id: clinic.id},
        opts
      )

    credential = credential!(admin, clinician, "SYN-#{System.unique_integer([:positive])}")
    %{admin: admin, clinician: clinician, credential: credential}
  end

  describe "a reader without the column's grant" do
    test "a reader without the field grant gets ForbiddenField for the secured column", ctx do
      reader = DailyFixtures.member!(ctx.admin, "Reviewer", [{Credential, :read, :global}])

      read = Credentialing.get_credential!(ctx.credential.id, as(reader))

      assert %Ash.ForbiddenField{field: :number} = read.number
      # The row is readable; only the column is withheld.
      assert read.expires_on == ctx.credential.expires_on
      assert read.kind == :licence
    end

    test "a field grant held in another tenant does not reveal the column here", ctx do
      reader = DailyFixtures.member!(ctx.admin, "Reviewer", [{Credential, :read, :global}])

      # The same person holds the column's grant at :global in a second tenant.
      other = DailyFixtures.tenant!()
      other_unit = other.user.owning_business_unit_id
      role = role!(other, [{@number_key, :read, :global}])

      Security.UserRole
      |> Ash.Changeset.for_create(
        :assign,
        %{user_id: reader.user.id, role_id: role.id, scoping_business_unit_id: other_unit},
        authorize?: false,
        tenant: other.tenant
      )
      |> Ash.create!()

      there = ActorContext.build(reader.user, tenant: other.tenant)
      assert ActorContext.grant(there, @number_key, :read).global?

      here =
        ActorContext.attach(
          reader.user,
          ActorContext.build(reader.user, tenant: ctx.admin.tenant)
        )

      refute ActorContext.grant(ActorContext.for_actor(here), @number_key, :read).global?

      read =
        Credentialing.get_credential!(ctx.credential.id, actor: here, tenant: ctx.admin.tenant)

      assert %Ash.ForbiddenField{} = read.number
    end

    test "a field grant at :local reveals the column only on records in reach", ctx do
      root = ctx.admin.user.owning_business_unit_id

      branch =
        BusinessUnit
        |> Ash.Changeset.for_create(:create, %{name: "Branch", parent_business_unit_id: root},
          authorize?: false,
          tenant: ctx.admin.tenant
        )
        |> Ash.create!()

      in_branch = credential!(ctx.admin, ctx.clinician, "SYN-BRANCH", branch.id)

      # Rows everywhere (a :global read), the column only in the branch (:local there).
      reader = DailyFixtures.member!(ctx.admin, "Reviewer", [{Credential, :read, :global}])
      role = role!(ctx.admin, [{@number_key, :read, :local}])

      Security.UserRole
      |> Ash.Changeset.for_create(
        :assign,
        %{user_id: reader.user.id, role_id: role.id, scoping_business_unit_id: branch.id},
        authorize?: false,
        tenant: ctx.admin.tenant
      )
      |> Ash.create!()

      reader = %{reader | actor: DailyFixtures.actor(reader.user)}

      assert Credentialing.get_credential!(in_branch.id, as(reader)).number == "SYN-BRANCH"

      assert %Ash.ForbiddenField{} =
               Credentialing.get_credential!(ctx.credential.id, as(reader)).number
    end

    test "filtering on a secured column without the grant matches nothing", ctx do
      reader = DailyFixtures.member!(ctx.admin, "Reviewer", [{Credential, :read, :global}])
      number = ctx.credential.number

      assert [] =
               Credentialing.list_credentials!(
                 Keyword.put(as(reader), :query, filter: [number: number])
               )

      # A search a page builds from what a person typed, and a client's filter.
      assert [] =
               Credential
               |> Ash.Query.filter(contains(number, ^String.slice(number, 0, 4)))
               |> Ash.read!(as(reader))

      assert [] =
               Credential
               |> Ash.Query.filter_input(%{number: %{eq: number}})
               |> Ash.read!(as(reader))

      # Across a relationship: the clinician whose credential has this number.
      assert [] =
               AshEnterprise.Credentialing.Clinician
               |> Ash.Query.filter(exists(credentials, number == ^number))
               |> Ash.read!(
                 actor:
                   DailyFixtures.member!(ctx.admin, "Clinicians", [
                     {AshEnterprise.Credentialing.Clinician, :read, :global},
                     {Credential, :read, :global}
                   ]).actor,
                 tenant: ctx.admin.tenant
               )

      holder =
        DailyFixtures.member!(ctx.admin, "Holder", [
          {Credential, :read, :global},
          {@number_key, :read, :global}
        ])

      assert [%{id: id}] =
               Credentialing.list_credentials!(
                 Keyword.put(as(holder), :query, filter: [number: number])
               )

      assert id == ctx.credential.id
    end
  end

  describe "a reader with the column's grant" do
    test "a reader with the field grant sees the column", ctx do
      holder =
        DailyFixtures.member!(ctx.admin, "Holder", [
          {Credential, :read, :global},
          {@number_key, :read, :global}
        ])

      assert Credentialing.get_credential!(ctx.credential.id, as(holder)).number ==
               ctx.credential.number
    end

    test "the column's grant alone reads no row", ctx do
      only_column =
        DailyFixtures.member!(ctx.admin, "Column only", [{@number_key, :read, :global}])

      assert [] = Credentialing.list_credentials!(as(only_column))
    end

    test "a record a write returns still shows the column to its holder", ctx do
      coordinator =
        DailyFixtures.member!(ctx.admin, "Coordinator", [
          {Credential, :read, :global},
          {Credential, :write, :global},
          {@number_key, :read, :global}
        ])

      corrected =
        Credentialing.correct_credential!(
          ctx.credential,
          %{number: "SYN-CORRECTED"},
          as(coordinator)
        )

      assert corrected.number == "SYN-CORRECTED"
    end
  end

  describe "the check" do
    test "the field check reads the context and issues no query", ctx do
      holder =
        DailyFixtures.member!(ctx.admin, "Holder", [
          {Credential, :read, :global},
          {@number_key, :read, :global}
        ])

      reader = DailyFixtures.member!(ctx.admin, "Reviewer", [{Credential, :read, :global}])
      read = %{resource: Credential, action: Ash.Resource.Info.action(Credential, :read)}
      update = %{resource: Credential, action: Ash.Resource.Info.action(Credential, :correct)}

      handler = "secured-fields-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:ash_enterprise, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:queried, metadata[:source]})
        end,
        nil
      )

      try do
        # The verb is :read whatever the action: a field grant is a grant to see.
        assert RoleGrant.filter(holder.actor, read, field: :number) == true
        assert RoleGrant.filter(holder.actor, update, field: :number) == true
        assert RoleGrant.filter(reader.actor, read, field: :number) == false
        refute_received {:queried, _source}

        Credentialing.list_credentials!(as(reader))
      after
        :telemetry.detach(handler)
      end

      sources = collect_sources([])
      assert "credentialing_credentials" in sources
      refute Enum.any?(sources, &(&1 in ["privileges", "role_privileges", "user_roles"]))
    end

    test "the catalogue holds one read privilege per secured field and Administrator holds it",
         ctx do
      assert %{resource_name: @number_key, access_right: :read, name: "prvReadCredential.number"} =
               Enum.find(Seeder.desired_privileges(), &(&1.resource_name == @number_key))

      refute Enum.any?(
               Seeder.desired_privileges(),
               &(&1.resource_name == @number_key and &1.access_right != :read)
             )

      privilege =
        Security.Privilege
        |> Ash.Query.filter(resource_name == @number_key)
        |> Ash.read_one!(authorize?: false)

      assert privilege.can_be_global and privilege.can_be_basic

      administrator =
        Security.Role
        |> Ash.Query.filter(name == "Administrator")
        |> Ash.read_one!(authorize?: false, tenant: ctx.admin.tenant)

      held =
        Security.RolePrivilege
        |> Ash.Query.filter(role_id == ^administrator.id and privilege_id == ^privilege.id)
        |> Ash.read_one!(authorize?: false, tenant: ctx.admin.tenant)

      assert held.depth == :global

      assert Credentialing.get_credential!(ctx.credential.id,
               actor: ctx.admin.actor,
               tenant: ctx.admin.tenant
             ).number == ctx.credential.number
    end
  end

  describe "the verifier" do
    test "a secured field that is not an attribute does not compile" do
      assert refusal(credential_with(secured_fields: [:document_findings])) =~
               "secured_fields :document_findings: no such attribute"

      assert refusal(credential_with(secured_fields: [:numbr])) =~
               "secured_fields :numbr: no such attribute"
    end

    test "the primary key, an ownership column or the tenant column cannot be secured" do
      assert refusal(credential_with(secured_fields: [:id])) =~ "is the primary key"

      for column <- [:owner_id, :owning_business_unit_id, :organization_id] do
        assert refusal(credential_with(secured_fields: [column])) =~
                 "is an ownership or tenant column"
      end
    end

    test "a resource with its own field policies cannot also declare secured fields" do
      dsl =
        Transformer.set_option(LinkedAccount.spark_dsl_config(), [:platform], :secured_fields, [
          :label
        ])

      assert refusal(dsl) =~ "declares its own field policy"
      assert :ok = SecuredFields.verify(LinkedAccount.spark_dsl_config())
    end

    test "the credential's declaration is well formed" do
      assert :ok = SecuredFields.verify(Credential.spark_dsl_config())
    end
  end

  # The field policy covers the column. A calculation or an aggregate the application
  # declares is evaluated in the data layer and is not rewritten (Ash applies no field
  # policy to a column an expression reads across a relationship), so one that reads a
  # secured column would hand its value to every reader of the row it sits on.
  describe "nothing derived reads a secured column" do
    test "no expression calculation or aggregate in the application reads a secured column" do
      offenders =
        for resource <- app_resources(),
            {name, hits} <- derived_reads(resource),
            hits != [],
            do: {resource, name, hits}

      assert offenders == []
    end

    test "the scan finds a read of a secured column, here and across a relationship" do
      import Ash.Expr, only: [expr: 1]

      assert [{Credential, :number}] = secured_reads(Credential, expr(number <> "x"))

      assert [{Credential, :number}] =
               secured_reads(Credentialing.LicenceDocument, expr(credential.number))

      assert [{Credential, :number}] =
               secured_reads(
                 Credentialing.Clinician,
                 expr(exists(credentials, number == "x"))
               )

      assert [] = secured_reads(Credential, expr(expires_on))
    end
  end

  defp app_resources do
    :ash_enterprise
    |> Ash.Info.domains()
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
  end

  defp secured_fields_of(resource) do
    if AshEnterprise.Platform.SystemAttributes in Spark.extensions(resource),
      do: Spark.Dsl.Extension.get_opt(resource, [:platform], :secured_fields, []),
      else: []
  end

  defp derived_reads(resource) do
    calculations =
      for %{calculation: {Ash.Resource.Calculation.Expression, opts}} = calculation <-
            Ash.Resource.Info.calculations(resource),
          do: {calculation.name, secured_reads(resource, opts[:expr])}

    aggregates =
      for aggregate <- Ash.Resource.Info.aggregates(resource) do
        target =
          if aggregate.related?,
            do: Ash.Resource.Info.related(resource, aggregate.relationship_path),
            else: aggregate.resource

        field =
          if target && aggregate.field && aggregate.field in secured_fields_of(target),
            do: [{target, aggregate.field}],
            else: []

        {aggregate.name, field ++ secured_reads(target, aggregate.filter)}
      end

    calculations ++ aggregates
  end

  # Every `{resource, column}` a secured column `expr`, read on `resource`, refers to.
  defp secured_reads(resource, expr), do: expr |> walk(resource, []) |> Enum.uniq()

  defp walk(_expr, nil, _path), do: []

  defp walk(%Ash.Query.Ref{attribute: attribute, relationship_path: rel}, resource, path) do
    name = if is_atom(attribute), do: attribute, else: Map.get(attribute, :name)
    target = Ash.Resource.Info.related(resource, path ++ rel)

    if target && name in secured_fields_of(target), do: [{target, name}], else: []
  end

  defp walk(%Ash.Query.Exists{related?: true} = exists, resource, path),
    do: walk(exists.expr, resource, path ++ exists.at_path ++ exists.path)

  defp walk(%Ash.Query.Exists{} = exists, _resource, _path),
    do: walk(exists.expr, exists.resource, [])

  defp walk(%_{} = struct, resource, path),
    do: struct |> Map.from_struct() |> Map.values() |> walk(resource, path)

  defp walk(map, resource, path) when is_map(map),
    do: map |> Map.values() |> walk(resource, path)

  defp walk(list, resource, path) when is_list(list),
    do: Enum.flat_map(list, &walk(&1, resource, path))

  defp walk(tuple, resource, path) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> walk(resource, path)

  defp walk(_other, _resource, _path), do: []

  defp refusal(dsl) do
    assert {:error, %Spark.Error.DslError{message: message}} = SecuredFields.verify(dsl)
    message
  end

  defp credential_with(changes) do
    Enum.reduce(changes, Credential.spark_dsl_config(), fn {option, value}, dsl ->
      Transformer.set_option(dsl, [:platform], option, value)
    end)
  end

  defp as(member), do: [actor: member.actor, tenant: member.tenant]

  defp credential!(admin, clinician, number, business_unit_id \\ nil) do
    Credential
    |> Ash.Changeset.for_create(
      :record,
      %{kind: :licence, number: number, expires_on: ~D[2030-01-31], clinician_id: clinician.id},
      actor: admin.actor,
      tenant: admin.tenant
    )
    |> then(fn changeset ->
      if business_unit_id,
        do:
          Ash.Changeset.force_change_attribute(
            changeset,
            :owning_business_unit_id,
            business_unit_id
          ),
        else: changeset
    end)
    |> Ash.create!()
  end

  # A role in `admin`'s tenant granting `grants` (`{privilege name, verb, depth}`).
  defp role!(admin, grants) do
    role =
      Security.Role
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Columns #{System.unique_integer([:positive])}",
          owning_business_unit_id: admin.user.owning_business_unit_id
        },
        authorize?: false,
        tenant: admin.tenant
      )
      |> Ash.create!()

    for {name, verb, depth} <- grants do
      privilege =
        Security.Privilege
        |> Ash.Query.filter(resource_name == ^name and access_right == ^verb)
        |> Ash.read_one!(authorize?: false)

      Security.RolePrivilege
      |> Ash.Changeset.for_create(
        :create,
        %{role_id: role.id, privilege_id: privilege.id, depth: depth},
        authorize?: false,
        tenant: admin.tenant
      )
      |> Ash.create!()
    end

    role
  end

  defp collect_sources(acc) do
    receive do
      {:queried, source} -> collect_sources([source | acc])
    after
      0 -> acc
    end
  end
end
