defmodule AshEnterprise.Test.PaperFacts do
  @moduledoc """
  Test setup for the paper lanes that issue a kind with a requirement: answers
  whatever the kind's requirement asks about the person's rows for `subject`,
  through the same interview and the same materialiser a person's
  `PaperAnswer` uses, but without opening a blocked run first — so a test that
  counts runs still counts only its own. Repeats until the requirement asks
  nothing more.

  The interview itself is tested in `AshEnterprise.Documents.PaperInterviewTest`,
  through the person's own action.
  """

  alias AshEnterprise.Documents.Paper.Actions.Issue
  alias AshEnterprise.Documents.Paper.Interview

  @rounds 5

  @doc """
  Answers `holds` to every question `kind` asks about `person`'s rows for
  `subject` (read as them, the way an issue reads them).
  """
  @spec answer_all!(map(), String.t(), map(), String.t(), boolean()) :: :ok
  def answer_all!(person, kind, subject, title, holds \\ true) do
    case Issue.payload(kind, subject, title, actor: person.actor, tenant: person.tenant) do
      {:ok, payload} -> answer_rounds!(person.tenant, kind, payload, holds, @rounds)
      # A subject the kind or the payload refuses never reaches the requirement.
      {:error, _refused} -> :ok
    end
  end

  defp answer_rounds!(_tenant, kind, _payload, _holds, 0),
    do: raise("the #{kind} requirement kept asking after #{@rounds} rounds")

  defp answer_rounds!(tenant, kind, payload, holds, rounds) do
    case Interview.check(kind, payload, tenant) do
      {:blocked, {:missing_facts, entries}} ->
        Enum.each(entries, &answer!(tenant, &1, holds))
        answer_rounds!(tenant, kind, payload, holds, rounds - 1)

      _decided ->
        :ok
    end
  end

  defp answer!(tenant, entry, holds) do
    {:ok, _verdict} =
      Interview.record(%{
        id: Ash.UUID.generate(),
        organization_id: tenant,
        predicate: entry["predicate"],
        holds: holds,
        scope: entry["scope"],
        subject_state_digest: entry["digest"],
        # No expiry: these fixtures are fixed years, and an answer that lapsed
        # with the calendar would turn every test that uses them red.
        valid_until: nil
      })
  end
end
