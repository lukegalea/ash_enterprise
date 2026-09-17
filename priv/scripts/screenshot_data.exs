# Demo data for the compliance screenshots: a handful of legacy subjects in
# different states (the ingestion path), plus officer reviews with full
# evidence (the compliant path). Run with the server up:
#   mix run priv/scripts/screenshot_data.exs
#
org = AshEnterprise.Legacy.Estate.organization_id()
stamp = System.system_time(:millisecond)

require Ash.Query

subjects = [
  {"ada#{stamp}", "ada#{stamp}@example.com", "Ada", "Able", "active"},
  {"ben#{stamp}", "ben#{stamp}@corp.example", "Ben", "Breach", "active"},
  {"cyd#{stamp}", "cyd#{stamp}@example.org", "Cyd", "Clean", "active"},
  {"dom#{stamp}", "dom#{stamp}@example.net", "Dom", "Drift", "suspended"},
  {"eva#{stamp}", "eva#{stamp}@example.gov", "Eva", "Edge", "pending"}
]

Enum.each(subjects, fn {login, email, first, last, state} ->
  AshEnterprise.Repo.query!(
    "INSERT INTO legacy.users (login, email, first_name, last_name, state) VALUES ($1, $2, $3, $4, $5)",
    [login, email, first, last, state]
  )
end)

IO.puts("inserted #{length(subjects)} legacy subjects; the wake will drain them")

# The officer review: full evidence for one subject, so the compliant story is
# on screen next to the unknowns the legacy estate cannot answer.
admin =
  AshEnterprise.Accounts.User
  |> Ash.Query.filter(email == ^"admin@legacy.example")
  |> Ash.read_one!(authorize?: false)

officer =
  AshEnterprise.Security.ActorContext.attach(
    admin,
    AshEnterprise.Security.ActorContext.build(admin, tenant: org)
  )

# Wait for the drain to project "cyd" (the compliant candidate), then review.
wait_for_projection = fn login ->
  wait_for_projection =
    fn wait ->
      AshEnterprise.Accounts.ProjectedUser
      |> Ash.Query.filter(login == ^login)
      |> Ash.read_one!(authorize?: false, tenant: org)
      |> case do
        nil ->
          Process.sleep(1000)
          wait.(wait)

        user ->
          user
      end
    end

  wait_for_projection.(wait_for_projection)
end

cyd = wait_for_projection.("cyd#{stamp}")

:ok =
  AshEnterprise.Compliance.Kyc.record_review(
    org,
    Integer.to_string(cyd.legacy_id),
    [
      ["customer", "status", "active"],
      ["customer", "jurisdiction", "regulated"],
      ["customer", "email_domain", "example.org"],
      ["customer", "identity_confirmed", true],
      ["customer", "sanctions_cleared", true],
      ["customer", "risk_tier", "low"],
      ["customer", "review_completed", true],
      ["customer", "mfa_enrolled", true],
      ["customer", "open_remedications", 0]
    ],
    actor: officer
  )

IO.puts("recorded the officer review for #{cyd.login}")

# Give the projector server a moment to fold everything, then summarize.
Process.sleep(8000)

findings =
  AshCompliance.Resources.Finding
  |> Ash.Query.filter(organization_id == ^org)
  |> Ash.read!(authorize?: false)

IO.puts("findings on file: #{length(findings)}")

Enum.group_by(findings, & &1.status)
|> Enum.each(fn {status, group} -> IO.puts("  #{status}: #{length(group)}") end)
