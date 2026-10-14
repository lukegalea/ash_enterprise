defmodule AshEnterprise.Mdm.MappingMissing do
  @moduledoc """
  The batch's pinned mapping row vanished after `:open` — a data-integrity
  refusal, not a transient bug: the batch is marked `:failed`, and Oban
  retries only re-raise until a human intervenes.
  """

  use Splode.Error, fields: [:batch_id], class: :invalid

  def message(%{batch_id: id}),
    do:
      "the mapping pinned by batch #{id} at open no longer exists — " <>
        "the batch is failed, not retried"
end
