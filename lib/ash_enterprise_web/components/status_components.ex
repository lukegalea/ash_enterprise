defmodule AshEnterpriseWeb.StatusComponents do
  @moduledoc """
  Status messages, and the cue that tells a test run from a live one.

  ## Status messages

  A status message is news a page gives without moving focus: a result, a
  warning, an error, a search that found nothing (WCAG 2.2 SC 4.1.3,
  https://www.w3.org/WAI/WCAG22/Understanding/status-messages.html). A screen
  reader announces it only if it arrives inside a live region that was already
  on the page, so the region is rendered whether or not there is a message, and
  only its content comes and goes. A region inserted together with its message
  is often not announced at all.

    * `status_message/1` is the common case: a callout inside a region.
    * `live_region/1` is the region alone, for a page that announces something
      that is not a callout (a list of search results, an empty state).

  The role is the WAI-ARIA one (https://www.w3.org/TR/wai-aria-1.2/#status):
  `status` for advice that waits its turn, `alert` for an error that
  interrupts, `log` for a stream of additions read in order. Each carries its
  implicit `aria-live` and `aria-atomic`, so neither is set here. Nothing in
  this module moves focus.

  ## Test or live

  `run_mode/1` is the cue a run carries wherever it is shown: a run of mode
  `:live` really ran its tool calls; `:eval`, `:shadow` and `:adhoc` (and a
  suite run's `:offline`, whose cases run as `:eval`) are tests, answered from
  fixtures. Anything else, a missing mode included, is shown as unknown and
  never as live. Tests assert it with `AshEnterpriseWeb.RunCueAssertions`.
  """

  use Phoenix.Component
  use Gettext, backend: AshEnterpriseWeb.Gettext

  import AshEnterpriseWeb.CoreComponents, only: [badge: 1, callout: 1, icon: 1]

  @roles ~w(status alert log)

  @doc """
  A live region: present on every render, so what changes inside it is
  announced. The caller renders or omits the content; the region stays.

  ## Examples

      <.live_region id="search-results">
        <p :if={@results == []}>Nothing matches.</p>
      </.live_region>
  """
  attr :id, :string, required: true
  attr :role, :string, values: @roles, default: "status"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def live_region(assigns) do
    ~H"""
    <div id={@id} role={@role} class={@class} {@rest}>{render_slot(@inner_block)}</div>
    """
  end

  @doc """
  A status message: a callout of `kind` inside a live region of `role`.

  `id` names the callout, which is there only while `show` is true; the region
  around it is `"<id>-region"` and is always there. While there is nothing to
  say the region is visually hidden but stays in the accessibility tree, so it
  takes no space and still announces what arrives.

  ## Examples

      <.status_message id="save-result" show={@saved?} kind={:success}>
        Saved.
      </.status_message>

      <.status_message id="save-error" role="alert" show={@error != nil} kind={:error}>
        {@error}
      </.status_message>
  """
  attr :id, :string, required: true
  attr :role, :string, values: @roles, default: "status"
  attr :kind, :atom, values: [:info, :success, :warning, :error], default: :info
  attr :show, :boolean, default: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def status_message(assigns) do
    ~H"""
    <.live_region id={"#{@id}-region"} role={@role} class={!@show && "sr-only"}>
      <.callout :if={@show} id={@id} kind={@kind} class={@class}>
        {render_slot(@inner_block)}
      </.callout>
    </.live_region>
    """
  end

  @test_modes ~w(eval shadow adhoc offline)

  @doc """
  Whether a run of `mode` is live, a test, or unknown. Takes the atom a record
  carries or the string a payload does; never creates an atom.

      iex> AshEnterpriseWeb.StatusComponents.run_environment(:shadow)
      :test
      iex> AshEnterpriseWeb.StatusComponents.run_environment(nil)
      :unknown
  """
  @spec run_environment(term()) :: :live | :test | :unknown
  def run_environment(mode) when is_atom(mode) and not is_nil(mode),
    do: mode |> Atom.to_string() |> run_environment()

  def run_environment("live"), do: :live
  def run_environment(mode) when mode in @test_modes, do: :test
  def run_environment(_unknown), do: :unknown

  @doc """
  The test-versus-live cue for a run of `mode`: "Test run" with the kind of
  test, "Live run", or "Run mode unknown" for a mode it does not know, a
  missing one included. Carries `data-run-environment` (`test`, `live` or
  `unknown`) and `data-run-mode` for tests and for the page's own styling.

  ## Examples

      <.run_mode mode={run.mode} id={"run-" <> run.id <> "-mode"} />
  """
  attr :mode, :any, required: true, doc: "the run's mode, an atom or a string, or nil"
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  def run_mode(assigns) do
    assigns = assign(assigns, :environment, run_environment(assigns.mode))

    ~H"""
    <.badge
      id={@id}
      tone={tone(@environment)}
      class={@class}
      data-run-environment={@environment}
      data-run-mode={if(@environment != :unknown, do: to_string(@mode))}
    >
      <.icon name={icon_name(@environment)} class="size-3.5" />
      {label(@environment, @mode)}
    </.badge>
    """
  end

  defp tone(:live), do: "green"
  defp tone(:test), do: "violet"
  defp tone(:unknown), do: "neutral"

  defp icon_name(:live), do: "hero-bolt-micro"
  defp icon_name(:test), do: "hero-beaker-micro"
  defp icon_name(:unknown), do: "hero-question-mark-circle-micro"

  defp label(:live, _mode), do: gettext("Live run")
  defp label(:unknown, _mode), do: gettext("Run mode unknown")
  defp label(:test, mode), do: gettext("Test run: %{kind}", kind: test_kind(to_string(mode)))

  defp test_kind("shadow"), do: gettext("shadow, beside live work")
  defp test_kind("adhoc"), do: gettext("experiment")
  defp test_kind(_eval_or_offline), do: gettext("evaluation")
end
