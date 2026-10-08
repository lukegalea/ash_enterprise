ExUnit.start()

# `:instrument_contract` runs only under `mix test --only instrument_contract`
# (the dual contract test needs a reachable instrument); include wins over
# exclude in ExUnit, so the --only flag still selects it. Same posture as
# ash_judgments' own helper.
ExUnit.configure(exclude: [:instrument_contract])

Ecto.Adapters.SQL.Sandbox.mode(AshEnterprise.Repo, :manual)
# The evidence substrate's repo rides the same test database (AST-152); its
# sandbox follows the host's.
Ecto.Adapters.SQL.Sandbox.mode(AshEvidence.Repo, :manual)
