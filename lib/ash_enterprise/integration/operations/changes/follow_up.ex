defmodule AshEnterprise.Integration.Operations.Changes.FollowUp do
  @moduledoc """
  `Delivery.mark_followed_up`: act on a registry webhook delivery, which is only a nudge.

  The delivery names an activation id and nothing else, and none of it is trusted. The
  follow-up reads that activation from the registry through a declared operation
  (`RegistryApi.get_activation`, as the `oban` system actor), parses the credential reference
  the **registry** answered with into a tenant and a credential, and finds the governed
  activations of that credential left `outcome_unknown` in that tenant and not already
  handed to a person (`resolution_requested_at` unset, as the `:reconcile` trigger also requires). It enqueues their
  reconcile and marks the delivery `followed_up`; when there is nothing to settle, or the
  registry's answer names no one, it marks it `ignored`.

  **It decides nothing.** The reconcile asks the registry again through `list_activations`,
  and only that answer settles an invocation; the webhook only makes the question run sooner.
  A delivery can therefore be forged to cost a read, never to change an outcome, and the tenant
  is never taken from a payload.

  The registry is read before the update's transaction opens, so no transaction is held while
  the call is out; the reconcile jobs are enqueued inside it, so they commit with the delivery's
  state. A failed read leaves the delivery `received` and the job retries.
  """

  use Ash.Resource.Change

  alias AshAgent.Invocation.Executor
  alias AshEnterprise.Credentialing.RegistryApi
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Platform.SystemActor

  require Ash.Query

  @activate "AshEnterprise.Credentialing.Credential.activate_credential"

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_transaction(&read_provider/1)
    |> Ash.Changeset.after_action(&enqueue/2)
  end

  defp read_provider(changeset) do
    subject_id = Ash.Changeset.get_attribute(changeset, :subject_id)

    case RegistryApi.get_activation(%{activation_id: subject_id}, actor: SystemActor.oban()) do
      {:ok, %{"subjectReference" => reference}} ->
        rows = waiting(reference)
        state = if rows == [], do: :ignored, else: :followed_up

        changeset
        |> Ash.Changeset.force_change_attribute(:state, state)
        |> Ash.Changeset.put_context(:waiting, rows)

      {:ok, _no_reference} ->
        Ash.Changeset.force_change_attribute(changeset, :state, :ignored)

      {:error, error} ->
        if absent?(error),
          do: Ash.Changeset.force_change_attribute(changeset, :state, :ignored),
          else: Ash.Changeset.add_error(changeset, error)
    end
  end

  defp absent?(error), do: AshOperations.Error.reason(error) in [:not_found, :gone]

  defp waiting(reference) do
    case RegistryApi.parse_reference(reference) do
      {:ok, {tenant, credential_id}} ->
        opts = [tenant: tenant, actor: SystemActor.oban()]

        # `args` is sealed (a calculation) and not filterable: read the tenant's unknown
        # activations and match the credential on the opened arguments.
        Invocation
        |> Ash.Query.filter(
          target == ^@activate and status == :outcome_unknown and
            is_nil(resolution_requested_at)
        )
        |> Ash.read!(opts)
        |> Enum.filter(&(Executor.stored_args(&1, opts)["id"] == credential_id))

      :error ->
        []
    end
  end

  defp enqueue(changeset, delivery) do
    for row <- changeset.context[:waiting] || [], do: AshOban.run_trigger(row, :reconcile)
    {:ok, delivery}
  end
end
