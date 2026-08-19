defmodule AshEnterprise.AI.Intent do
  @moduledoc """
  What the model understood a request to mean.

  A plain typed struct with no behaviour, deliberately. It is the *only* thing
  the model produces, and it cannot do anything — it names an intent and the
  values it mentioned. Turning it into a mutation is
  `AshEnterprise.AI.Proposal`'s job, and executing one is the human's.

  ## Reads and writes take different paths, on purpose

  `:assign_role` changes something, so it becomes a proposal that a person reads
  and approves before anything happens. `:show_surface` and `:design_surface` do
  not: they render a table, and a table is filtered by the viewer's own policies
  before a single row reaches the page. Asking somebody to approve a *read* they
  are already authorized for teaches them to click through confirmations, which
  is exactly what makes the confirmation on the write worth reading.

  The struct also **is** the schema: `ash_ai` derives the JSON schema the model
  is constrained to from these field definitions, so there is no separate schema
  to drift. Adding a field here changes what the model may return, with no
  second place to edit.
  """

  use Ash.TypedStruct

  typed_struct do
    field :kind, :atom,
      constraints: [one_of: [:assign_role, :show_surface, :design_surface, :unknown]],
      allow_nil?: false,
      description: "What the user is asking for. Use :unknown if it is not a supported request."

    field :user_email, :string,
      description: "The email address of the user the request is about, exactly as written."

    field :role_name, :string, description: "The name of the role mentioned, exactly as written."

    field :surface, :string,
      description:
        "For :show_surface, the name of the declared surface that answers the request. " <>
          "Must be one of the names listed in the prompt, copied exactly."

    field :reasoning, :string,
      description: "One sentence explaining the interpretation, shown to the human for review."
  end
end
