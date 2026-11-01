defmodule AshEnterprise.Showcase.Credentialing do
  @moduledoc """
  The credentialing slice of the showcase (`/app/showcase/credentialing`): what the tour
  reads, and the fault panel's controls.

  ## What the tour reads

  Everything as the viewer, through the application's own reads: the clinic's
  credentials (`credentials/1`), and the activation requests the viewer may see
  (`activations/1`) with what each shows of its governance: its status and outcome, the
  approval digest and whether it is bound to the request, the approval task's address,
  and how many activations the registry took for its credential.

  ## The licence reader (slice 2)

  `start_reading/2` starts the licence reader (`AshEnterprise.Credentialing.LicenceReader`)
  on a credential, as the viewer, about its clinician; `readings/1` reads its runs back
  with their journal, model calls, lookups and findings; `extend_budget/3` gives a run
  waiting on its budget more (F8); `erase_clinician/2` shreds a clinician's erasure scope
  (F11), and `chain_verifies?/1` says whether the audit chain still verifies after it.
  The budget and the erasure are the application's own actions, not fault controls:
  they run under the viewer's grants and refuse anyone they would refuse elsewhere.

  ## The fault panel

  Each control produces one failure scenario through the application's own paths, never
  a path written for the showcase, and refuses unless the demo flag is on
  (`AshEnterprise.Showcase.fault_controls?/0`):

  | Control | Scenario | What it does |
  |---|---|---|
  | `correct_during_approval/2` | F4 | corrects the credential's expiry date through `Credential.correct`, as a colleague would while its activation waits for approval |
  | `revoke_requester_grant/1` | F5 | removes the coordinator's role assignment through `UserRole.destroy`, as an administrator would before the activation runs |
  | `restore/1` | — | runs the clinic's demo data again (`AshEnterprise.Credentialing.DemoData.populate/1`), which gives the coordinator their role back |
  | `kill_after_registry_accepts/0` | F2 | arms the fault point `:credential_registry_accepted` with `:kill`: the next activation's worker dies after the registry accepted it and before anything was recorded |
  | `time_out_model_after_lookups/0` | F1 | arms the fault point `:model_stream_reading` with `:raise`, skipping one call: the next reading's model fails in the middle of the turn after its lookups |

  The edit and the revocation stand in for another person's act, so they run as the
  demo data's own actor (`SystemActor.seed/0`), the one that set the clinic up, and the
  audit trail says so.
  """

  require Ash.Query

  alias AshEnterprise.AI.ModelCall
  alias AshEnterprise.Audit.Chain
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing

  alias AshEnterprise.Credentialing.{
    Clinician,
    Credential,
    DemoData,
    Findings,
    LicenceReader,
    Registry
  }

  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.Scope
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Approval
  alias AshEnterprise.Faults
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase

  @activate "AshEnterprise.Credentialing.Credential.activate_credential"
  @kill_point :credential_registry_accepted
  @reader LicenceReader.key()
  @read_text "AshEnterprise.Credentialing.LicenceDocument.read_text"
  @timeout_point :model_stream_reading
  @erasure_reason "The clinician asked to be erased."

  @doc "The governed target the slice is about."
  @spec target() :: String.t()
  def target, do: @activate

  @doc "The fault point the kill control arms."
  @spec kill_point() :: atom()
  def kill_point, do: @kill_point

  @doc "The clinic's credentials `actor` may read, with their clinicians, by number."
  @spec credentials(term()) :: [Credential.t()]
  def credentials(actor) do
    Credentialing.list_credentials!(
      actor: actor,
      tenant: ActorContext.tenant(actor),
      load: [:clinician],
      query: [sort: [number: :asc]]
    )
  end

  @doc """
  The activation requests `actor` may read, newest first, each as
  `%{invocation:, credential_id:, bound?:, task_id:, registry_activations:}`.
  """
  @spec activations(term()) :: [map()]
  def activations(actor) do
    tenant = ActorContext.tenant(actor)

    rows =
      Execution.list_invocations!(
        actor: actor,
        tenant: tenant,
        query: [filter: [target: @activate], sort: [created_on: :desc]]
      )

    tasks = approval_tasks(rows, tenant)

    Enum.map(rows, fn row ->
      credential_id = credential_id(row)

      %{
        invocation: row,
        credential_id: credential_id,
        bound?: bound?(row),
        task_id: Map.get(tasks, row.id),
        registry_activations: if(credential_id, do: Registry.activations(credential_id), else: 0)
      }
    end)
  end

  @doc """
  Whether `row`'s approval binds exactly this request: its `approval_digest` is the
  digest of its `authorization_details` (RFC 9396), and those name the row's own target,
  target digest and argument digest (ADR 0055, "Approval binding"). `nil` for a row that
  needs no approval.
  """
  @spec bound?(Execution.Invocation.t()) :: boolean() | nil
  def bound?(%{approval_digest: nil}), do: nil

  def bound?(row) do
    case row.authorization_details do
      [
        %{
          "type" => "urn:ash-agent:action:" <> target,
          "target_digest" => target_digest,
          "args_digest" => args_digest
        }
      ] = details ->
        AshAgent.Invocation.Approval.digest(details) == row.approval_digest and
          {target, target_digest, args_digest} == {row.target, row.target_digest, row.args_digest}

      _other ->
        false
    end
  end

  # The approval task's id per invocation. Read without authorization, as
  # `RequestInvocation` reads it: the requester may not read a task they are excluded
  # from deciding, and only its address leaves here.
  defp approval_tasks([], _tenant), do: %{}

  defp approval_tasks(rows, tenant) do
    ids = Enum.map(rows, & &1.id)
    key = Approval.key()

    HumanTask
    |> Ash.Query.filter(subject_id in ^ids and node_id == ^key)
    |> Ash.Query.select([:id, :subject_id])
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Map.new(&{&1.subject_id, &1.id})
  end

  defp credential_id(%{preconditions: [%{"id" => id} | _]}), do: id
  defp credential_id(_row), do: nil

  # --- slice 2: the licence reader --------------------------------------------------

  @doc "The agent the second slice runs: the licence reader's key."
  @spec reader() :: String.t()
  def reader, do: @reader

  @doc "The fault point the model timeout control arms."
  @spec timeout_point() :: atom()
  def timeout_point, do: @timeout_point

  @doc "The input a reading of the credential numbered `number` is given."
  @spec reading_input(String.t()) :: String.t()
  def reading_input(number),
    do:
      "Read the documents of credential #{number} and record the licence number and " <>
        "the date the licence is valid until."

  @doc """
  `actor` starts the licence reader on the credential `credential_id`: a run about its
  clinician, so its content is sealed under the clinician's erasure scope.
  """
  @spec start_reading(Ash.UUID.t(), term()) :: {:ok, struct()} | {:error, term()}
  def start_reading(credential_id, actor) do
    opts = [actor: actor, tenant: ActorContext.tenant(actor)]

    with {:ok, credential} <- Credentialing.get_credential(credential_id, opts) do
      Execution.start_agent_run(
        @reader,
        reading_input(credential.number),
        %{subject_type: inspect(Clinician), subject_id: credential.clinician_id},
        opts
      )
    end
  end

  @doc """
  The licence reader's runs `actor` may read, newest first, each as `%{run:,
  credential:, steps:, model_calls:, lookups:, findings:, erased?:}`:

    * `steps`, the journal in order, each with `recorded?` (false once erased);
    * `model_calls`, the run's model calls in order, as `AshEnterprise.AI.ModelCall`
      recorded them (outcome and error class only);
    * `lookups`, the run's `read_text` calls, each with how many times it was claimed
      (`attempt_count`): a step repeated after a timeout reads them again, never runs
      them again;
    * `findings`, the judgments the run recorded (`AshEnterprise.Credentialing.Findings`);
    * `calls`, every tool call, with its arguments as read now (erased once shredded).
  """
  @spec readings(term()) :: [map()]
  def readings(actor) do
    tenant = ActorContext.tenant(actor)
    opts = [actor: actor, tenant: tenant]

    runs =
      Execution.list_agent_runs!(
        Keyword.put(opts, :query, filter: [agent_key: @reader], sort: [created_on: :desc])
      )

    readings(runs, actor, opts)
  end

  defp readings([], _actor, _opts), do: []

  defp readings(runs, actor, opts) do
    ids = Enum.map(runs, & &1.id)
    credentials = Map.new(credentials(actor), &{&1.clinician_id, &1})

    steps =
      Execution.list_agent_steps!(
        Keyword.merge(opts,
          query: [filter: [run_id: [in: ids]], sort: [seq: :asc]],
          load: [:recorded?]
        )
      )
      |> Enum.group_by(& &1.run_id)

    calls =
      Execution.list_invocations!(
        Keyword.merge(opts,
          query: [filter: [run_id: [in: ids]], sort: [invocation_key: :asc]],
          load: [:args, :recorded?]
        )
      )
      |> Enum.group_by(& &1.run_id)

    documents =
      Credentialing.list_licence_documents!(
        Keyword.put(opts, :query,
          filter: [credential_id: [in: Enum.map(Map.values(credentials), & &1.id)]]
        )
      )

    findings =
      documents
      |> Findings.for_documents(opts, Enum.map(ids, &to_string/1))
      |> Enum.group_by(& &1.judgment.run_id)

    model_calls = model_calls(runs)

    Enum.map(runs, fn run ->
      run_calls = Map.get(calls, run.id, [])

      %{
        run: run,
        credential: Map.get(credentials, run.subject_id),
        steps: Map.get(steps, run.id, []),
        model_calls: Map.get(model_calls, run.id, []),
        lookups: Enum.filter(run_calls, &(&1.target == @read_text)),
        calls: run_calls,
        findings: Map.get(findings, to_string(run.id), []),
        erased?: Enum.any?(Map.get(steps, run.id, []), &(not &1.recorded?))
      }
    end)
  end

  # The runs' model calls, by run, in order: a step's call is named
  # `run:<run id>:<step seq>`, and a run's next step is `step_seq + 1`. Read without
  # authorization, as the approval tasks are above: the runs were read as the viewer,
  # and only each call's outcome, error class and tokens leave here (a model call
  # records no prompt).
  defp model_calls(runs) do
    callers =
      for run <- runs, seq <- 1..((run.step_seq || 0) + 1), into: %{} do
        {"run:#{run.id}:#{seq}", run.id}
      end

    names = Map.keys(callers)

    ModelCall
    |> Ash.Query.filter(caller in ^names)
    |> Ash.Query.select([
      :id,
      :caller,
      :outcome,
      :error_class,
      :input_tokens,
      :output_tokens,
      :created_on
    ])
    |> Ash.Query.sort(created_on: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.group_by(&Map.fetch!(callers, &1.caller))
  end

  @doc """
  `actor` gives the run `run_id` `tokens` more tokens of budget, as an administrator
  does for a run waiting on its budget (`Run.extend`, through the grant union).
  """
  @spec extend_budget(Ash.UUID.t(), pos_integer(), term()) :: {:ok, struct()} | {:error, term()}
  def extend_budget(run_id, tokens, actor) do
    opts = [actor: actor, tenant: ActorContext.tenant(actor)]

    with {:ok, run} <- Execution.get_agent_run(run_id, opts) do
      Execution.extend_agent_run_budget(run, tokens, opts)
    end
  end

  @doc """
  The clinician of the credential `credential_id` asked to be erased: `actor` shreds the
  clinician's erasure scope (`AshEnterprise.Erasure.shred_scope/4`), as the platform
  operator does from `mix ash_enterprise.erasure.shred`. Only a person holding a write
  grant on erasure scopes may; every copy a run about the clinician made becomes
  unreadable, and the rows, their transitions and the audit chain stay.

  The credential is read as `actor`; the scope is read without authorization, as the
  shred task reads it, and the shred itself runs under `actor`'s grants.
  """
  @spec erase_clinician(Ash.UUID.t(), term()) :: {:ok, struct()} | {:error, term()}
  def erase_clinician(credential_id, actor) do
    opts = [actor: actor, tenant: ActorContext.tenant(actor)]

    with {:ok, credential} <-
           Credentialing.get_credential(credential_id, Keyword.put(opts, :load, :clinician)),
         %{erasure_scope_id: scope_id} when is_binary(scope_id) <- credential.clinician,
         {:ok, scope} <- Ash.get(Scope, scope_id, authorize?: false) do
      Erasure.shred_scope(scope, scope.ref, @erasure_reason, actor: actor)
    else
      %{} -> {:error, :no_scope}
      other -> other
    end
  end

  @doc "Whether `tenant`'s audit hash chain verifies (`AshEnterprise.Audit.Chain.verify/1`)."
  @spec chain_verifies?(Ash.UUID.t()) :: boolean()
  def chain_verifies?(tenant), do: Chain.verify(tenant).findings == []

  # --- the fault panel -------------------------------------------------------------

  @doc """
  F1: the model times out in the middle of the next reading, after its lookups: the
  fault point `:model_stream_reading` is armed to let one model call through (the turn
  that asks for the lookups) and raise in the stream of the next.
  """
  @spec time_out_model_after_lookups() :: :ok | {:error, :fault_controls_off}
  def time_out_model_after_lookups do
    with :ok <- on(), do: Faults.arm(@timeout_point, :raise, skip: 1)
  end

  @doc "F2: the next activation's worker is killed after the registry accepted it."
  @spec kill_after_registry_accepts() :: :ok | {:error, :fault_controls_off}
  def kill_after_registry_accepts do
    with :ok <- on(), do: Faults.arm(@kill_point, :kill)
  end

  @doc "F4: a colleague corrects the credential's expiry date while it waits for approval."
  @spec correct_during_approval(Ash.UUID.t(), Ash.UUID.t()) ::
          {:ok, Credential.t()} | {:error, term()}
  def correct_during_approval(credential_id, tenant) do
    opts = [actor: SystemActor.seed(), tenant: tenant]

    with :ok <- on(),
         {:ok, credential} <- Credentialing.get_credential(credential_id, opts) do
      expires_on = Date.add(credential.expires_on || Date.utc_today(), 1)
      Credentialing.correct_credential(credential, %{expires_on: expires_on}, opts)
    end
  end

  @doc """
  F5: an administrator removes the coordinator's credentialing role before their
  activation runs. Returns how many assignments were removed.
  """
  @spec revoke_requester_grant(Ash.UUID.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke_requester_grant(tenant) do
    opts = [actor: SystemActor.seed(), tenant: tenant]
    email = DemoData.coordinator_email()
    role = DemoData.coordinator_role()

    with :ok <- on(),
         {:ok, assignments} <-
           Security.UserRole
           |> Ash.Query.filter(user.email == ^email and role.name == ^role)
           |> Ash.read(opts) do
      destroy_all(assignments, opts)
    end
  end

  defp destroy_all(assignments, opts) do
    Enum.reduce_while(assignments, {:ok, 0}, fn assignment, {:ok, count} ->
      case Ash.destroy(assignment, opts) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc "Runs the clinic's demo data again, which restores the coordinator's role."
  @spec restore(Ash.UUID.t()) :: {:ok, map()} | {:error, :fault_controls_off}
  def restore(tenant) do
    with :ok <- on(), do: {:ok, DemoData.populate(tenant)}
  end

  defp on, do: if(Showcase.fault_controls?(), do: :ok, else: {:error, :fault_controls_off})
end
