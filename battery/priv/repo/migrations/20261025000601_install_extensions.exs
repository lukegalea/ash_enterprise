# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshCompliance.Repo.Migrations.InstallExtensions do
  @moduledoc false
  use Ecto.Migration

  # ash_functions (AshPostgres' error-expression functions) is deliberately
  # NOT installed here: the lifecycle actions run their validations in Elixir
  # (require_atomic? false), so no SQL-side error functions are needed — and
  # vanilla CI Postgres images do not ship the extension.
  def up do
    execute("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"")
    execute("CREATE EXTENSION IF NOT EXISTS \"citext\"")
  end

  def down do
    execute("DROP EXTENSION IF EXISTS \"citext\"")
    execute("DROP EXTENSION IF EXISTS \"uuid-ossp\"")
  end
end
