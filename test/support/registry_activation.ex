defmodule AshEnterprise.Test.RegistryActivation do
  @moduledoc """
  Fixtures for the governed credential activation against a `Req.Test` registry: a request
  approved by another person and ready to execute, and a registry that accepts an activation
  and then loses the answer. The caller owns the application env, so a test using these is
  `async: false` and restores `Transport`'s env itself.
  """

  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing.RegistryApi.Transport
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Approval
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.ActorContext

  require Ash.Query

  @activate "AshEnterprise.Credentialing.Credential.activate_credential"

  @doc "Put an application env value back, or delete it when there was none."
  def restore_env(key, nil), do: Application.delete_env(:ash_enterprise, key)
  def restore_env(key, previous), do: Application.put_env(:ash_enterprise, key, previous)

  @doc "The target name of the governed activation."
  def target, do: @activate

  def as_person(user, tenant),
    do: [
      actor: ActorContext.attach(user, ActorContext.build(user, tenant: tenant)),
      tenant: tenant
    ]

  def oban(tenant), do: [actor: SystemActor.oban(), tenant: tenant]

  @doc """
  Request the activation as the coordinator, approve it as a committee member and apply the
  decision: the invocation is `ready` to execute.
  """
  def ready!(clinic, credential, tenant) do
    row =
      Execution.invoke!(
        @activate,
        %{"id" => credential.id},
        %{key: "registry-test:activate:#{credential.id}"},
        as_person(clinic.coordinator, tenant)
      )

    approval_key = Approval.key()
    row_id = row.id

    task =
      HumanTask
      |> Ash.Query.filter(subject_id == ^row_id and node_id == ^approval_key)
      |> Ash.read_one!(authorize?: false, tenant: tenant)

    HumanTask
    |> Ash.ActionInput.for_action(
      :approve,
      %{record_id: task.id},
      as_person(hd(clinic.committee), tenant)
    )
    |> Ash.run_action!()

    Execution.apply_invocation_decision!(row, oban(tenant))
  end

  @doc """
  A registry that takes an activation and then loses the answer (the POST times out), whose
  list then shows it. Returns the agent that counts `posts` and `gets` and keeps the
  `accepted` credential reference. The transport is pointed at the stub.
  """
  def lossy_registry! do
    {:ok, log} = Agent.start_link(fn -> %{posts: 0, gets: 0, accepted: nil} end)

    Req.Test.stub(Transport, fn
      %{method: "POST"} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"subjectReference" => reference} = Jason.decode!(body)
        Agent.update(log, &%{&1 | posts: &1.posts + 1, accepted: reference})
        Req.Test.transport_error(conn, :timeout)

      %{method: "GET"} = conn ->
        Agent.update(log, &%{&1 | gets: &1.gets + 1})
        reference = Agent.get(log, & &1.accepted)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "data" => [
              %{"id" => "act-77", "subjectReference" => reference, "status" => "active"}
            ]
          })
        )
    end)

    point_transport!(residency: :in_cluster)
    log
  end

  @doc "Point the transport at the `Req.Test` stub, with no waiting between attempts."
  def point_transport!(opts \\ []) do
    Application.put_env(
      :ash_enterprise,
      Transport,
      Keyword.merge(
        [
          base_url: "http://registry.test",
          api_key: "synthetic-key",
          residency: :in_cluster,
          req_options: [plug: {Req.Test, Transport}],
          sleep: fn _ms -> :ok end,
          base_backoff_ms: 1
        ],
        opts
      )
    )
  end
end
