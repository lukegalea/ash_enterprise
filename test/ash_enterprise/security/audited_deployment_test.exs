defmodule AshEnterprise.Security.AuditedDeploymentTest do
  @moduledoc """
  The audited deployment class: `DEPLOYMENT_CLASS=audited` boots only under the production
  configuration, with self-registration and the showcase's fault panel off, and names each
  missing piece. Unset, nothing is checked: a demo boots as it always has.

  The `config/runtime.exs` tests set OS environment variables, which are global: not async.
  """
  use ExUnit.Case, async: false

  alias AshEnterprise.Security.AuditedDeployment

  @audited %{"DEPLOYMENT_CLASS" => "audited"}

  describe "problems/2" do
    test "a production audited environment has none" do
      assert AuditedDeployment.problems(@audited, :prod) == []
      assert AuditedDeployment.assert!(@audited, :prod) == :ok
    end

    test "no class checks nothing, whatever else is set" do
      env = %{"SELF_REGISTRATION" => "true", "SHOWCASE_FAULT_CONTROLS" => "1"}

      for config_env <- [:dev, :test, :prod] do
        assert AuditedDeployment.problems(env, config_env) == []

        assert AuditedDeployment.problems(Map.put(env, "DEPLOYMENT_CLASS", " "), config_env) ==
                 []
      end
    end

    test "an unknown class is a problem rather than silently unaudited" do
      assert [problem] = AuditedDeployment.problems(%{"DEPLOYMENT_CLASS" => "Audited"}, :prod)
      assert problem =~ "DEPLOYMENT_CLASS"
    end

    test "the dev and test configurations" do
      for config_env <- [:dev, :test] do
        assert [problem] = AuditedDeployment.problems(@audited, config_env)
        assert problem =~ "MIX_ENV=prod"
        assert problem =~ "#{config_env} configuration"
      end
    end

    test "self-registration turned on" do
      for value <- ["1", "true", " TRUE "] do
        env = Map.put(@audited, "SELF_REGISTRATION", value)
        assert [problem] = AuditedDeployment.problems(env, :prod)
        assert problem =~ "SELF_REGISTRATION"
      end

      assert AuditedDeployment.problems(Map.put(@audited, "SELF_REGISTRATION", "false"), :prod) ==
               []
    end

    test "the showcase's fault panel turned on" do
      env = Map.put(@audited, "SHOWCASE_FAULT_CONTROLS", "true")
      assert [problem] = AuditedDeployment.problems(env, :prod)
      assert problem =~ "SHOWCASE_FAULT_CONTROLS"
    end

    test "every problem is named at once" do
      env = Map.merge(@audited, %{"SELF_REGISTRATION" => "1", "SHOWCASE_FAULT_CONTROLS" => "1"})
      assert length(AuditedDeployment.problems(env, :dev)) == 3

      error = assert_raise RuntimeError, fn -> AuditedDeployment.assert!(env, :dev) end
      assert error.message =~ "DEPLOYMENT_CLASS=audited"
      assert error.message =~ "MIX_ENV=prod"
      assert error.message =~ "SELF_REGISTRATION"
      assert error.message =~ "SHOWCASE_FAULT_CONTROLS"
    end
  end

  describe "config/runtime.exs" do
    @prod %{
      "DATABASE_URL" => "ecto://u:p@db.invalid/ash_enterprise",
      "SECRET_KEY_BASE" => String.duplicate("k", 64),
      "TOKEN_SIGNING_SECRET" => String.duplicate("t", 64),
      "ERASURE_MASTER_KEY" => Base.encode64(String.duplicate("e", 32)),
      "SESSION_SIGNING_SALT" => String.duplicate("s", 32),
      "LIVE_VIEW_SIGNING_SALT" => String.duplicate("l", 32),
      "PHX_HOST" => "audited.example.test"
    }

    @cleared ~w(DEPLOYMENT_CLASS SELF_REGISTRATION SHOWCASE_FAULT_CONTROLS)

    defp read(env, config_env) do
      keys = Enum.uniq(Map.keys(env) ++ @cleared)
      previous = Map.new(keys, &{&1, System.get_env(&1)})
      Enum.each(@cleared, &System.delete_env/1)
      Enum.each(env, fn {key, value} -> System.put_env(key, value) end)

      try do
        Config.Reader.read!("config/runtime.exs", env: config_env, target: :host)
      after
        Enum.each(previous, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)
      end
    end

    test "an audited production deployment boots, and says it is audited" do
      config = read(Map.merge(@prod, @audited), :prod)

      assert get_in(config, [:ash_enterprise, :deployment_class]) == :audited
      assert get_in(config, [:ash_enterprise, :self_registration?]) == nil
    end

    test "an audited deployment with self-registration on does not boot, and the message names it" do
      env = @prod |> Map.merge(@audited) |> Map.put("SELF_REGISTRATION", "true")

      error = assert_raise RuntimeError, fn -> read(env, :prod) end
      assert error.message =~ "audited"
      assert error.message =~ "SELF_REGISTRATION"
    end

    test "an audited deployment on the dev configuration does not boot" do
      env = Map.merge(@audited, %{"ERASURE_MASTER_KEY" => @prod["ERASURE_MASTER_KEY"]})

      error = assert_raise RuntimeError, fn -> read(env, :dev) end
      assert error.message =~ "MIX_ENV=prod"
    end

    test "a production deployment without the class boots with its demo switches" do
      env = Map.merge(@prod, %{"SELF_REGISTRATION" => "true", "SHOWCASE_FAULT_CONTROLS" => "1"})
      config = read(env, :prod)

      assert get_in(config, [:ash_enterprise, :deployment_class]) == nil
      assert get_in(config, [:ash_enterprise, :self_registration?]) == true
    end
  end
end
