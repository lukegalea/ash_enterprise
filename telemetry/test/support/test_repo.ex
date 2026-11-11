defmodule AshEnterprise.Telemetry.TestRepo do
  use Ecto.Repo, otp_app: :ash_enterprise_telemetry, adapter: Ecto.Adapters.Postgres
end
