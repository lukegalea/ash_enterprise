defmodule AshEnterpriseWeb.A2ui.StalledReviewsUI do
  @moduledoc """
  Stalled reviews: the process tasks the signed-in person may read that opened more
  than two days ago and are still open or claimed, oldest first (`HumanTask.stalled`).

  The view the assistant's `stalled_reviews` tool puts in an answer, reached without
  chat: the same read, as the reader, so the page and the chat show one set. Read only;
  a task is decided where it waits (`/app/approvals`, `/app/tasks`), each subject links
  to its record.

  Served at `/app/reviews/stalled`.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource(AshEnterprise.Bpmn.HumanTask)
    surface_id("stalled_reviews")
    title("Stalled reviews")
    record_label("task")

    component :table, :stalled do
      fields([:name, :subject_label, :waiting_since, :status, :assignee_label, :due_at])
      read_action(:stalled)
    end

    field :name do
      label("Step")
    end

    field :subject_label do
      label("About")
      link({:record, :subject_ref})
    end

    field :waiting_since do
      label("Waiting since")
    end

    field :assignee_label do
      label("Claimed by")
    end

    field :due_at do
      label("Due")
    end
  end
end
