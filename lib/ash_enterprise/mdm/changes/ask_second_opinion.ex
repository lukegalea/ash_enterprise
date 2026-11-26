defmodule AshEnterprise.Mdm.Changes.AskSecondOpinion do
  @moduledoc """
  When the matcher bands a staged pair review, enqueues the job that asks
  the model's second opinion on it (`AshEnterprise.Mdm.SecondOpinionWorker`,
  S1-83), while the second opinion is enabled
  (`AshEnterprise.Mdm.SecondOpinion.enabled?/0`).

  The change asks nothing itself: the model is called by the job, after the
  band is committed, never inside this write (law 3). The job is inserted in
  `after_action`, inside the band's own transaction, so a band that rolls
  back enqueues nothing. A golden pair (no staged record) is not asked.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Mdm.{SecondOpinion, SecondOpinionWorker}

  @impl true
  def change(changeset, _opts, _context) do
    if banding_review?(changeset) and SecondOpinion.enabled?() do
      Ash.Changeset.after_action(changeset, &enqueue/2)
    else
      changeset
    end
  end

  # The hook is the whole change, so the atomic form is the same changeset:
  # banding stays an atomic update.
  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp banding_review?(changeset) do
    Ash.Changeset.changing_attribute?(changeset, :band) and
      Ash.Changeset.get_attribute(changeset, :band) == :review
  end

  defp enqueue(_changeset, %{staged_record_id: nil} = candidate), do: {:ok, candidate}

  defp enqueue(_changeset, candidate) do
    with {:ok, _job} <- candidate |> SecondOpinionWorker.new_for() |> Oban.insert() do
      {:ok, candidate}
    end
  end
end
