defmodule AshEnterprise.BusinessEvents.Changes.Derive do
  @moduledoc """
  Records the business events a canonical write implies, in the write's own
  transaction (ADR 0051).

  On `CalendarEvent` and `Message`'s `upsert_from_source` — the one path
  every projector writes through — so every projection, present and future,
  emits without knowing the ledger exists. After the upsert, the written row
  goes to `AshEnterprise.BusinessEvents.Recorder`; a failed record fails the
  write, so the canonical row and its facts commit together or not at all.

  A ledger failure carries no content: the facts hold ids and timestamps
  only (`AshEnterprise.BusinessEvents.Derivation`), and the projectors
  reduce a failed write to field names before it leaves them
  (`AshEnterprise.Canonical.Projections.Write`).

  Off when `AshEnterprise.BusinessEvents.emit?/0` is false (the test
  default; see the domain's moduledoc).
  """

  use Ash.Resource.Change

  alias AshEnterprise.BusinessEvents
  alias AshEnterprise.BusinessEvents.Recorder

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :subject) do
      {:ok, subject} when subject in [:calendar_event, :message] -> {:ok, opts}
      _ -> {:error, "subject must be :calendar_event or :message"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    if BusinessEvents.emit?() do
      Ash.Changeset.after_action(changeset, fn _changeset, row ->
        record(opts[:subject], row)
      end)
    else
      changeset
    end
  end

  defp record(subject, row) do
    case derive(subject, row) do
      {:ok, _facts} -> {:ok, row}
      {:error, _} = error -> error
    end
  end

  defp derive(:calendar_event, row), do: Recorder.calendar_event(row)
  defp derive(:message, row), do: Recorder.message(row)
end
