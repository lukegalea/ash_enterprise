defmodule AshEnterprise.Documents.PaperAnswer.Changes.FromRun do
  @moduledoc """
  Fills an answer from the run it was asked on, and admits it as a fact
  (`AshEnterprise.Documents.PaperAnswer`'s moduledoc says what is checked).

  The checks read, so they run in a `before_action` hook, inside the
  transaction, never while the changeset is built: the run through
  `PaperRun.mine` as the actor, the requirement from the run's kind, the
  question from the run's recorded `missing_fact` problems. Each refusal is a
  field error the person can read. The fact is written in an `after_action`
  hook, so a fact that cannot be written fails the answer.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Documents
  alias AshEnterprise.Documents.Paper.Interview

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.before_action(&from_run(&1, context.actor))
    |> Ash.Changeset.after_action(fn _changeset, answer ->
      case Interview.record(answer) do
        {:ok, _verdict} -> {:ok, answer}
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp from_run(changeset, actor) do
    run_id = Ash.Changeset.get_attribute(changeset, :run_id)
    predicate = Ash.Changeset.get_attribute(changeset, :predicate)

    with {:ok, run} <- own_run(run_id, actor, changeset.tenant),
         {:ok, _name} <- answerable(run.document_kind, predicate),
         {:ok, question} <- asked(run, predicate, changeset.tenant),
         {:ok, valid_until} <- still_valid(run.document_kind, question["scope"]) do
      Ash.Changeset.force_change_attributes(changeset, %{
        document_kind: run.document_kind,
        scope: question["scope"],
        subject_state_digest: question["digest"],
        valid_until: valid_until
      })
    else
      {:error, field, message} ->
        Ash.Changeset.add_error(changeset, field: field, message: message)
    end
  end

  defp own_run(run_id, actor, tenant) do
    case Documents.my_paper_runs(actor: actor, tenant: tenant, query: [filter: [id: run_id]]) do
      {:ok, [run]} -> {:ok, run}
      _none -> {:error, :run_id, "is not one of your runs in this organization"}
    end
  end

  defp answerable(kind, predicate) do
    case Interview.answerable(kind, predicate) do
      {:ok, name} ->
        {:ok, name}

      {:error, :no_requirement} ->
        {:error, :predicate, "is not asked: a #{kind} has no requirement"}

      {:error, :undeclared} ->
        {:error, :predicate, "is not a fact the #{kind} requirement declares"}

      {:error, :not_asked} ->
        {:error, :predicate, "is decided by the document, not asked of a person"}
    end
  end

  # An answer that would be expired the moment it is written would be read as
  # unknown at once and asked again: refused, so the person learns why.
  defp still_valid(kind, scope) do
    valid_until = Interview.valid_until(kind, scope)

    if valid_until && DateTime.compare(valid_until, DateTime.utc_now()) != :gt do
      {:error, :predicate,
       "can no longer be answered in this scope: an answer for it held only until #{Date.to_iso8601(DateTime.to_date(valid_until))}"}
    else
      {:ok, valid_until}
    end
  end

  # The question as the run recorded it, in this tenant only.
  defp asked(run, predicate, tenant) do
    question =
      Enum.find(run.problems, fn problem ->
        problem["kind"] == "missing_fact" and problem["predicate"] == predicate
      end)

    cond do
      is_nil(question) ->
        {:error, :predicate, "was not asked on this run"}

      get_in(question, ["scope", "organization"]) != tenant ->
        {:error, :run_id, "was asked in another organization"}

      true ->
        {:ok, question}
    end
  end
end
