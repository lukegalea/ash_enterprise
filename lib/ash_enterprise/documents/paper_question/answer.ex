defmodule AshEnterprise.Documents.PaperQuestion.Answer do
  @moduledoc """
  `PaperQuestion.confirm` and `deny`: answers the question named by the row id
  (`"<run id>/<predicate>"`) by creating an `AshEnterprise.Documents.PaperAnswer`
  as the actor, which checks the run and the predicate itself.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Documents
  alias AshEnterprise.Security.ActorContext

  @impl true
  def run(input, opts, context) do
    tenant = context.tenant || ActorContext.tenant(context.actor)

    with {:ok, run_id, predicate} <- parse(input.arguments.record_id),
         {:ok, _answer} <-
           Documents.answer_paper_question(
             %{run_id: run_id, predicate: predicate, holds: Keyword.fetch!(opts, :holds)},
             actor: context.actor,
             tenant: tenant
           ) do
      :ok
    end
  end

  defp parse(record_id) do
    with [run_id, predicate] <- String.split(record_id, "/", parts: 2),
         {:ok, run_id} <- Ecto.UUID.cast(run_id) do
      {:ok, run_id, predicate}
    else
      _malformed -> {:error, "Not a question of yours."}
    end
  end
end
