defmodule AshEnterpriseWeb.ModelProfilesLiveTest do
  @moduledoc """
  The model-profile surface (`/app/models`, AGT-64): the in-zone generative profile with
  its permitted use, readiness and restrictions. Readiness is only what was recorded:
  a profile nothing vouches for reads unknown and is never offered as ready, and one
  not configured, outside the store's zone, or whose last call failed is not ready.
  Nothing here calls a model.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshEnterprise.AI.{ModelCall, ModelProfiles, Models}
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Surfaces
  alias AshEnterprise.Test.AssistantFixtures, as: F

  @system [authorize?: false]

  defp sign_in(user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp call!(outcome) do
    target = F.target()

    ModelCall.record!(
      %{
        caller: "test.profile",
        profile: target.profile,
        model: target.label,
        residency: :in_zone,
        zone: target.zone,
        operation: :stream_text,
        outcome: outcome,
        duration_ms: 1
      },
      actor: SystemActor.system()
    )
  end

  describe "readiness, as recorded" do
    setup do
      F.in_zone!()
      :ok
    end

    test "configured with no call on record is unknown, not ready" do
      row = ModelProfiles.in_zone(F.target(), @system)
      assert row.readiness == :unknown
      refute row.ready
      assert row.readiness_note =~ "not known"
    end

    test "an answered call within the day is ready; older than a day is unknown again" do
      call!(:ok)

      assert %{readiness: :ready, ready: true} = ModelProfiles.in_zone(F.target(), @system)

      later = DateTime.add(DateTime.utc_now(), 2 * 86_400, :second)
      row = ModelProfiles.in_zone(F.target(), @system, later)
      assert row.readiness == :unknown
      refute row.ready
      assert row.readiness_note =~ "more than a day ago"
    end

    test "a last call that failed or was refused is not ready" do
      call!(:error)
      assert %{readiness: :not_ready, ready: false} = ModelProfiles.in_zone(F.target(), @system)

      call!(:refused)
      row = ModelProfiles.in_zone(F.target(), @system)
      assert row.readiness == :not_ready
      assert row.readiness_note =~ "was refused"
    end

    test "a call record that cannot be read leaves readiness unknown" do
      call!(:ok)
      # No actor, authorization on: the record is not the reader's to read.
      row = ModelProfiles.in_zone(F.target(), actor: nil, authorize?: true)
      assert row.readiness == :unknown
      refute row.ready
    end

    test "a profile outside the store's zone is not ready, whatever its calls say" do
      F.in_zone!(profile_zone: "SYNTHETIC-elsewhere")
      call!(:ok)

      row = ModelProfiles.in_zone(F.target(), @system)
      assert row.readiness == :not_ready
      assert row.readiness_note =~ "zone"
    end

    test "with no profile configured it is not configured, and names no model" do
      Application.put_env(:ash_enterprise, :ai, [])
      row = ModelProfiles.in_zone(Models.resolve(Models.default_spec()), @system)

      assert row.readiness == :not_configured
      refute row.ready
      assert row.model == nil
      assert row.key == "in_zone_generative"
    end

    test "permitted use and restrictions are stated, the paste guard among them" do
      row = ModelProfiles.in_zone(F.target(), @system)
      assert Enum.any?(row.permitted_use, &(&1 =~ "agent version"))
      assert Enum.any?(row.restrictions, &(&1 =~ "/app/accounts"))
      assert Enum.any?(row.restrictions, &(&1 =~ "REQUIRE_IN_ZONE_MODELS"))
    end
  end

  describe "the page" do
    setup do
      F.in_zone!()
      F.tenant!()
    end

    test "is in the registry and shows the profile under the context band", ctx do
      assert %{path: "/app/models", live: AshEnterpriseWeb.ModelProfilesLive} =
               Surfaces.fetch(:model_profiles)

      {:ok, view, _html} = live(sign_in(ctx.user), "/app/models")

      assert has_element?(view, "#context-band")
      assert has_element?(view, "#page-header h1", "Model profiles")
      assert has_element?(view, "#profile-in_zone_generative[data-ready=false]")
      assert has_element?(view, "#profile-in_zone_generative-readiness", "Readiness unknown")
      refute has_element?(view, "#profile-in_zone_generative-readiness", "Ready")
      assert has_element?(view, "#profile-in_zone_generative-use li")
      assert has_element?(view, "#profile-in_zone_generative-restrictions li", "/app/accounts")
    end

    test "says not configured when there is no profile", ctx do
      Application.put_env(:ash_enterprise, :ai, [])
      {:ok, view, _html} = live(sign_in(ctx.user), "/app/models")

      assert has_element?(view, "#profile-in_zone_generative[data-readiness=not_configured]")
      assert has_element?(view, "#profile-in_zone_generative-readiness", "Not configured")
    end

    test "a signed-out visitor is sent to sign in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/app/models")
    end
  end
end
