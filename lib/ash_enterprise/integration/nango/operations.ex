defmodule AshEnterprise.Integration.Nango.Operations do
  @moduledoc """
  The provider-operation DSL (ADR 0011): declare what a provider API offers,
  get one generic Ash action per operation.

      nango do
        integration "google-calendar"
        errors :google

        operation :list_events, :get, "/calendar/v3/calendars/{calendar_id}/events" do
          description "events.list"
          param :calendar_id, :string, in: :path, allow_nil?: false
          param :sync_token, :string, as: "syncToken"
          param :page_token, :string, as: "pageToken"
        end
      end

  generates, on the resource,

      action :list_events, :map do
        argument :calendar_id, :string, allow_nil?: false
        argument :sync_token, :string
        argument :page_token, :string
        argument :linked_account_id, :uuid
        run {AshEnterprise.Integration.Nango.RunOperation, operation: :list_events}
      end

  plus a code interface `list_events/1,2`. The action returns the provider's
  decoded JSON body.

  ## What the generated action guarantees

    * **Policy-gated** like any action on a platform resource: a generic action
      maps to the `:read` verb, so the actor needs a role granting read on the
      operation resource.
    * **The connection is derived, never named.** Every action gets exactly one
      routing argument, `linked_account_id` — a `LinkedAccount` row that must be
      owned by the actor, read under the actor's policies. The Nango connection
      id and provider config key are never inputs; the
      `NoConnectionParams` verifier refuses a declaration that tries to make
      them one.

  Kept deliberately small: this is the in-repo exercise of AST-155, built so it
  can be promoted to an `ash_nango` package (or stay, with a recorded reason).
  """

  alias AshEnterprise.Integration.Nango.{Operation, Param}

  @param %Spark.Dsl.Entity{
    name: :param,
    describe: "One input to the operation: an action argument and a request parameter.",
    target: Param,
    args: [:name, :type],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true, doc: "The action argument name (snake_case)."],
      type: [type: :any, required: true, doc: "The Ash type of the argument."],
      as: [type: :string, doc: "The provider's own name for the parameter. Defaults to `name`."],
      in: [
        type: {:one_of, [:query, :path, :body]},
        default: :query,
        doc: "Where the value goes on the request."
      ],
      allow_nil?: [type: :boolean, default: true, doc: "Whether the argument may be omitted."],
      default: [type: :any, doc: "Default argument value."],
      constraints: [type: :keyword_list, default: [], doc: "Ash type constraints."],
      description: [type: :string, doc: "Argument description."]
    ]
  }

  @operation %Spark.Dsl.Entity{
    name: :operation,
    describe: "A provider operation proxied through Nango; becomes one generic action.",
    target: Operation,
    args: [:name, :method, :path],
    identifier: :name,
    entities: [params: [@param]],
    schema: [
      name: [type: :atom, required: true, doc: "The generated action's name."],
      method: [type: {:one_of, [:get, :post]}, required: true, doc: "The HTTP method."],
      path: [
        type: :string,
        required: true,
        doc:
          "Provider path relative to the integration's base URL; `{param}` placeholders allowed."
      ],
      description: [type: :string, doc: "The generated action's description."]
    ]
  }

  @nango %Spark.Dsl.Section{
    name: :nango,
    describe: "Provider operations proxied through Nango, one generic action each.",
    schema: [
      integration: [
        type: :string,
        required: true,
        doc: """
        The Nango integration (provider config key) these operations run
        against, e.g. `"google-calendar"`. Linked accounts are matched on it.
        """
      ],
      errors: [
        type: {:one_of, [:http, :google, :slack]},
        default: :http,
        doc: """
        How provider responses are classified into typed errors. `:google`
        reads Google's error envelope (403 rate-limit reasons retry like 429);
        `:slack` reads Slack's `ok: false` bodies. See
        `AshEnterprise.Integration.Nango.Classify`.
        """
      ]
    ],
    entities: [@operation]
  }

  use Spark.Dsl.Extension,
    sections: [@nango],
    transformers: [AshEnterprise.Integration.Nango.Transformers.AddOperationActions],
    verifiers: [AshEnterprise.Integration.Nango.Verifiers.NoConnectionParams]
end
