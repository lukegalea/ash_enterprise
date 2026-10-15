defmodule Mix.Tasks.AshEnterprise.Erasure.Shred do
  @shortdoc "Destroys an erasure scope's key, irreversibly (crypto-shredding, ADR 0024)"

  @moduledoc """
  Shreds one erasure scope: destroys its key, so every value sealed under it —
  raw landings, canonical rows, and the ciphertext in their audit events —
  becomes permanently unreadable. Rows, structural columns and the audit hash
  chain are untouched.

      mix ash_enterprise.erasure.shred connection:<ref> --as you@example.com \\
        --reason "left VendorPM"

  * The scope is named `kind:ref` exactly as `mix ash_enterprise.erasure.scopes`
    prints it. Typing the ref is the confirmation the action requires.
  * `--as` names the human the shred is attributed to. It runs under that
    user's grants: they must hold `write` on `AshEnterprise.Erasure.Scope` at
    global depth. No system actor can shred.
  * `--reason` is recorded in the audit trail.
  * Asks for a final `y` unless `--yes` is given.

  **Shredding stops nothing from arriving.** Delete the Nango connection and
  revoke the provider app's tokens first — see
  `docs/runbooks/crypto-shredding.md`, which also lists what a key destroy does
  not reach (backups, WAL, logs, Oban args, Nango-held tokens, lineage facets).
  """

  use Mix.Task

  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.Scope
  alias AshEnterprise.Mix.Helpers
  alias AshEnterprise.Security.ActorContext

  @requirements ["app.config"]

  # An allow-list, not String.to_atom/1 on argv (iron law #10).
  @kinds %{"connection" => :connection, "data_subject" => :data_subject}

  @impl Mix.Task
  def run(argv) do
    {opts, args, _invalid} =
      OptionParser.parse(argv, strict: [as: :string, reason: :string, yes: :boolean])

    {kind, ref} = parse_scope!(args)
    email = opts[:as] || Mix.raise("--as <email> is required: a shred is a person's decision")
    reason = opts[:reason] || Mix.raise("--reason is required: it is recorded in the audit trail")

    # Repo only: no Oban, no endpoint (iron law #23).
    Helpers.boot_repo()

    # Operator console lookups. The person and the scope are found with
    # authorization off because a console has no actor until we resolve one;
    # the shred itself then runs as that person, under their grants.
    actor = operator!(email)
    scope = scope!(kind, ref)

    Mix.shell().info(
      "Shredding #{kind}:#{ref} (#{scope.label || "no label"}, #{scope.id}) as #{email}.\n" <>
        "Every value sealed under this scope becomes permanently unreadable."
    )

    unless opts[:yes] || Mix.shell().yes?("Destroy this scope's key?") do
      Mix.raise("Aborted; nothing was changed.")
    end

    case Erasure.shred_scope(scope, ref, reason, actor: actor) do
      {:ok, shredded} ->
        Mix.shell().info([
          :green,
          "Shredded #{kind}:#{ref} at #{DateTime.to_iso8601(shredded.shredded_at)}.",
          :reset,
          "\nNow delete the provider connection (Nango) and revoke its tokens, if not done already."
        ])

      {:error, %Ash.Error.Forbidden{}} ->
        Mix.raise("#{email} holds no write grant on erasure scopes; nothing was changed.")

      {:error, error} ->
        Mix.raise("Shred refused: #{Exception.message(error)}")
    end
  end

  defp parse_scope!([scope_arg]) do
    with [kind, ref] when ref != "" <- String.split(scope_arg, ":", parts: 2),
         {:ok, kind} <- Map.fetch(@kinds, kind) do
      {kind, ref}
    else
      _ ->
        Mix.raise(
          "expected the scope as kind:ref, kind one of #{Enum.join(Map.keys(@kinds), ", ")}"
        )
    end
  end

  defp parse_scope!(_args), do: Mix.raise("expected exactly one scope, as kind:ref")

  defp operator!(email) do
    case AshEnterprise.Accounts.get_user_by_email(email, authorize?: false) do
      {:ok, user} -> ActorContext.attach(user, ActorContext.build(user))
      {:error, _} -> Mix.raise("no user with email #{email}")
    end
  end

  defp scope!(kind, ref) do
    case Erasure.scope_by_ref(kind, ref, authorize?: false) do
      {:ok, %Scope{} = scope} -> scope
      {:ok, nil} -> Mix.raise("no erasure scope #{kind}:#{ref}")
    end
  end
end
