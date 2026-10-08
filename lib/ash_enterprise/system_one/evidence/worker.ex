defmodule AshEnterprise.SystemOne.Evidence.Worker do
  @moduledoc """
  Oban wrapper for one adjudication run (AST-152) — the service-task
  placement (the banding-pipeline pattern, d582f88; the TapWorker arg
  discipline): model-bound work that never runs in a request, a guard path
  or a policy check (law 3).

  Job args carry the run's input set: the claim, the asserting tenant (a
  uuid — attribution, not content), the document version, the call shape
  and the admission handoff keys. Wiring — which declared questions
  adjudicate — is application config, never args. Args are payload-class: the host's Oban retention prunes
  completed jobs, and the durable records keep digests and ids only. The
  run creates its own evaluation row (with the loop's complete bookkeeping
  — the package's `start` contract) and runs as the system actor, the
  background-job runner persona (`AshEnterprise.Platform.SystemActor`);
  where a run must carry a person's or an automation principal's
  attribution instead, the caller runs
  `AshEnterprise.SystemOne.Evidence.adjudicate/2` in its own lane and
  passes the actor.

  Enqueue via `AshEnterprise.SystemOne.Evidence.open_adjudication/1`. The
  run's wiring — which declared questions adjudicate which documents — is
  application config (`:system_one_evidence_worker`), never job args: args
  select a run, they never select wiring.
  """

  use Oban.Worker,
    queue: :system_one,
    max_attempts: 3,
    # A run is idempotent by its recorded rows (the assertion id is the
    # orchestrator's idempotency key); a retry re-runs the judge calls as
    # NEW observations (re-inference is a new row, law 2) and records a new
    # assertion — the unique period collapses rapid re-enqueues.
    unique: [period: 60]

  alias AshEnterprise.SystemOne.Evidence

  @impl true
  def perform(%Oban.Job{args: %{"claim" => claim} = args}) do
    case run_args(args) do
      {:ok, opts} -> adjudicate(claim, opts)
      {:error, message} -> {:error, message}
    end
  end

  # Args carry the run's input set; the wiring — the declared questions and
  # the test fake — comes from application config, the same way a deployment
  # routes its lane.
  defp run_args(%{
         "tenant" => tenant,
         "document_version_id" => version_id,
         "call_shape" => call_shape,
         "subject" => subject,
         "predicate" => predicate,
         "profile" => profile
       }) do
    {:ok,
     opts()
     |> Keyword.merge(
       tenant: tenant,
       document_version_id: version_id,
       call_shape: String.to_existing_atom(call_shape),
       subject: subject,
       predicate: predicate,
       profile: profile
     )}
  end

  defp run_args(args), do: {:error, "adjudication job args missing keys, got: #{inspect(args)}"}

  defp adjudicate(claim, opts) do
    case Evidence.adjudicate(claim, opts) do
      {:ok, _summary} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp opts, do: Application.get_env(:ash_enterprise, :system_one_evidence_worker, [])
end
