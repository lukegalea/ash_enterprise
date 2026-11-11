defmodule AshEnterprise.Telemetry.TestDomain do
  @moduledoc false
  # Only its short name is used, by the standard metrics.
  use Ash.Domain, validate_config_inclusion?: false

  resources do
  end
end
