defmodule AshEnterprise.Execution do
  @moduledoc """
  Governed execution (ADR 0055): every consequential act this application runs on
  someone's behalf is one `AshEnterprise.Execution.Invocation` row, with a stable key, a
  keyed digest of its arguments, a lease that fences stale workers and a typed outcome.

  The entry point is `invoke/4`:

      AshEnterprise.Execution.invoke(
        "AshEnterprise.Security.UserRole.assign",
        %{"user_id" => user_id, "role_id" => role_id},
        %{key: "access-review:\#{review_id}"},
        actor: actor,
        tenant: tenant
      )

  It returns the invocation row, the same row again for the same key and request, or an
  `AshAgent.Invocation.IdempotencyConflict` for the same key with a different request.
  A ready row runs on the `:execute` trigger, as the requesting person, rebuilt from
  their grants when it is claimed.

  The resources come from the `ash_agent` package's fragments instantiated on the
  platform base (ADR 0056); this domain names them and their code interfaces.
  """

  use Ash.Domain

  resources do
    resource AshEnterprise.Execution.Invocation do
      define :invoke, action: :invoke, args: [:target, :args]
      define :request_invocation, action: :request
      define :get_invocation, action: :read, get_by: [:id]
      define :list_invocations, action: :read
      define :claim_invocation, action: :claim
      define :apply_invocation_decision, action: :apply_decision
      define :request_invocation_cancel, action: :request_cancel
      define :execute_invocation, action: :execute, args: [:primary_key]
    end
  end
end
