defmodule AshEnterprise.BrandTest do
  # async: false -- these tests write the application env every other test reads.
  use ExUnit.Case, async: false

  alias AshEnterprise.Brand

  setup do
    previous = Application.fetch_env(:ash_enterprise, :product_name)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_enterprise, :product_name, value)
        :error -> Application.delete_env(:ash_enterprise, :product_name)
      end
    end)
  end

  test "unconfigured, the product is the template's own name" do
    Application.delete_env(:ash_enterprise, :product_name)
    assert Brand.product_name() == "Ash Enterprise"

    Application.put_env(:ash_enterprise, :product_name, "")
    assert Brand.product_name() == "Ash Enterprise"
  end

  test "a deployment renames itself by configuration" do
    Application.put_env(:ash_enterprise, :product_name, "Dogfood")
    assert Brand.product_name() == "Dogfood"
  end

  test "the ACP agent introduces itself by the product name" do
    Application.put_env(:ash_enterprise, :product_name, "Dogfood Ops")

    assert %{name: "dogfood-ops", title: "Dogfood Ops", version: version} =
             Brand.acp_agent_info()

    assert version == to_string(Application.spec(:ash_enterprise, :vsn))
  end
end
