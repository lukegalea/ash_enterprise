defmodule AshEnterprise.AI.RequestClassifier do
  @moduledoc """
  Holds the prompt-backed action that classifies an administrative request.

  A resource with **no data layer**, because there is nothing to store. Ash puts
  generic actions on resources rather than domains, so this exists to give the
  action a home — it is not an entity in the domain model, and it deliberately
  has no attributes, no table and no policies.
  """

  use Ash.Resource,
    domain: AshEnterprise.AI,
    extensions: [AshAi]

  # `prompt/2` is a macro in AshAi.Actions, not a function in AshAi, and it is
  # not auto-imported by the extension.
  import AshAi.Actions, only: [prompt: 2]

  code_interface do
    define :interpret_request, args: [:request]
  end

  actions do
    action :interpret_request, AshEnterprise.AI.Intent do
      description """
      Classify an administrative request written in natural language.

      Returns an intent describing what was asked for. Performs nothing: name
      resolution and execution happen afterwards, as the requesting human.
      """

      argument :request, :string, allow_nil?: false

      # A capture, not a call. `prompt/2` is a macro and its arguments are
      # evaluated while this module compiles, so `AshEnterprise.AI.model()`
      # baked whatever config existed at *build* time into the action -- a
      # release could never be repointed at another provider, which is the one
      # thing `:interpreter_model` exists to allow. AshAi resolves a 0-arity
      # function per call instead.
      run prompt(
            &AshEnterprise.AI.model/0,
            # `tools: false` is load-bearing, not a default. A model holding a
            # mutation tool can perform the mutation regardless of what the
            # prompt says or what a user injects into their request. Denying
            # tools here makes that structurally impossible rather than merely
            # discouraged.
            tools: false,
            prompt: """
            You classify administrative requests for an enterprise access-control
            system.

            Supported request kinds:
              - :assign_role -- granting a named security role to a named user.

            Anything else is :unknown.

            Extract names and email addresses EXACTLY as the user wrote them. Do
            not guess, correct, or complete them: the application resolves them
            against records the requesting user is allowed to see, and a
            "corrected" value silently targets the wrong record.

            Request: <%= @input.arguments.request %>
            """
          )
    end
  end
end
