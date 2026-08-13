defmodule AshEnterprise.AI.Intent do
  @moduledoc """
  What the model understood a request to mean.

  A plain typed struct with no behaviour, deliberately. It is the *only* thing
  the model produces, and it cannot do anything — it names an intent and the
  values it mentioned. Turning it into a mutation is
  `AshEnterprise.AI.Proposal`'s job, and executing one is the human's.

  The struct also **is** the schema: `ash_ai` derives the JSON schema the model
  is constrained to from these field definitions, so there is no separate schema
  to drift. Adding a field here changes what the model may return, with no
  second place to edit.
  """

  use Ash.TypedStruct

  typed_struct do
    field :kind, :atom,
      constraints: [one_of: [:assign_role, :unknown]],
      allow_nil?: false,
      description: "What the user is asking for. Use :unknown if it is not a supported request."

    field :user_email, :string,
      description: "The email address of the user the request is about, exactly as written."

    field :role_name, :string, description: "The name of the role mentioned, exactly as written."

    field :reasoning, :string,
      description: "One sentence explaining the interpretation, shown to the human for review."
  end
end
