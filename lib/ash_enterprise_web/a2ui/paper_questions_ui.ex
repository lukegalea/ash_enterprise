defmodule AshEnterpriseWeb.A2ui.PaperQuestionsUI do
  @moduledoc """
  Document questions: what a requirement still needs from the signed-in
  person before one of their documents can be issued
  (`AshEnterprise.Documents.PaperQuestion`). One row per missing fact of
  their own blocked runs, with the asking rule's message and evidence text;
  Yes or No records the answer (`confirm`, `deny`) and the list is read again,
  so an answered question leaves it. Issue the document again to continue: a
  new round's questions, if any, appear here.

  Nobody designs the rows: they come from the requirements, so the surface is
  read fresh each round rather than laid out as fixed wizard steps. Served at
  `/app/documents/paper-questions`.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Documents.PaperQuestion
    surface_id "paper_questions"
    title "Document questions"
    record_label "question"

    component :table do
      fields [:document_kind, :about, :question, :message, :evidence, :reason]
      read_action :open
      row_actions [:confirm, :deny]
    end

    action :confirm do
      label "Yes"
    end

    action :deny do
      label "No"
    end

    field :document_kind do
      label "Document"
    end

    field :about do
      label "For"
    end

    field :question do
      label "Question"
    end

    field :message do
      label "Why it is asked"
    end

    field :evidence do
      label "What would satisfy it"
    end

    field :reason do
      label "Status"
    end
  end
end
