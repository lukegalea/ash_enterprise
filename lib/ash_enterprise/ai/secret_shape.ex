defmodule AshEnterprise.AI.SecretShape do
  @moduledoc """
  The paste guard: text a person wrote that is shaped like a secret (a private key, a
  provider's access key or token, a bearer token, a password or key assignment, a URL
  with a password in it) never reaches a model.

  Two places check it, both before anything is recorded or sent:

    * the assistant's message intake (`AshEnterprise.Assistant.Ask.ask/3`), which
      refuses the question before it is stored, so the thread never holds it;
    * every model call through `AshEnterprise.AI.Models.GuardedReqLLM`, over the
      person-written (`user`) messages of the request: a refused request writes no
      `AshEnterprise.AI.ModelCall` row and makes no transport call.

  A refusal names the *kind* of secret it saw and points to the connection screen
  (`connection_path/0`), where an account is linked without anyone pasting its key.
  It never carries, logs or echoes the text that matched.

  The shapes are the well-known ones, matched on their prefixes and structure, not on
  entropy: a record reference or an id is not a secret, and refusing every long string
  would refuse the questions the assistant exists for. Tool results and system text are
  not checked; what a tool read is the reader's own data, read as them.
  """

  @connection_path "/app/accounts"

  # {kind, pattern}. Kinds are what a refusal names; the patterns stay here.
  @shapes [
    {:private_key, ~r/-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----/},
    {:access_key, ~r/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/},
    {:access_key, ~r/\bAIza[0-9A-Za-z_-]{35}/},
    {:access_key, ~r/\b[sr]k_(?:live|test)_[0-9A-Za-z]{16,}/},
    {:access_key, ~r/\bsk-(?:[a-z]+-)?[A-Za-z0-9_-]{20,}/},
    {:token, ~r/\bgh[pousr]_[A-Za-z0-9]{30,}/},
    {:token, ~r/\bgithub_pat_[A-Za-z0-9_]{30,}/},
    {:token, ~r/\bglpat-[0-9A-Za-z_-]{20,}/},
    {:token, ~r/\bxox[abposr]-[A-Za-z0-9-]{10,}/},
    {:token, ~r/\bxapp-\d-[A-Za-z0-9-]{10,}/},
    {:token, ~r/\bnpm_[A-Za-z0-9]{30,}/},
    {:token, ~r/\bya29\.[0-9A-Za-z_-]{20,}/},
    {:token, ~r/\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/},
    {:token, ~r/\bBearer\s+[A-Za-z0-9._~+\/-]{20,}=*/i},
    {:password, ~r|\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]{3,}@|i},
    {:password,
     ~r/\b(?:api[_-]?key|secret[_-]?key|client[_-]?secret|access[_-]?key|auth[_-]?token|access[_-]?token|token|secret|password|passwd|pwd)\s*[:=]\s*["']?(?!%\{)[^\s"']{8,}/i}
  ]

  @type kind :: :private_key | :access_key | :token | :password

  defmodule Refused do
    @moduledoc """
    A model request refused by the paste guard (`AshEnterprise.AI.SecretShape`):
    nothing was recorded or sent. Carries the kind of secret and the caller, never the
    text.
    """
    defexception [:kind, :caller]

    @type t :: %__MODULE__{kind: AshEnterprise.AI.SecretShape.kind(), caller: String.t() | nil}

    @impl true
    def message(%{kind: kind, caller: caller}) do
      "#{caller || "unnamed"}: refused: the request holds text shaped like " <>
        "#{AshEnterprise.AI.SecretShape.describe(kind)}, so nothing was sent. " <>
        AshEnterprise.AI.SecretShape.advice()
    end
  end

  @doc "The connection screen a refusal points to: where accounts are linked."
  @spec connection_path() :: String.t()
  def connection_path, do: @connection_path

  @doc "What a refusal tells the person to do instead."
  @spec advice() :: String.t()
  def advice do
    "Never paste a key, token or password into a question: link the account on " <>
      "Accounts & syncs (#{@connection_path}) and the assistant reads it as you."
  end

  @doc "The kind of secret, as the end of \"shaped like …\"."
  @spec describe(kind()) :: String.t()
  def describe(:private_key), do: "a private key"
  def describe(:access_key), do: "an access key"
  def describe(:token), do: "an access token"
  def describe(:password), do: "a password or key"

  @doc """
  `:ok`, or `{:refused, kind}` for the first secret-shaped stretch of `text`. Anything
  that is not a string is `:ok`: there is nothing a person wrote in it.
  """
  @spec check(term()) :: :ok | {:refused, kind()}
  def check(text) when is_binary(text) do
    Enum.find_value(@shapes, :ok, fn {kind, pattern} ->
      if Regex.match?(pattern, text), do: {:refused, kind}
    end)
  end

  def check(_other), do: :ok

  @doc """
  `check/1` over the person-written messages of a model request: a `ReqLLM.Context`, a
  list of messages, or a prompt string (which is the person's).
  """
  @spec check_request(term()) :: :ok | {:refused, kind()}
  def check_request(context) do
    context
    |> user_text()
    |> Enum.find_value(:ok, fn text ->
      case check(text) do
        :ok -> nil
        refused -> refused
      end
    end)
  end

  defp user_text(text) when is_binary(text), do: [text]
  defp user_text(%{messages: messages}) when is_list(messages), do: user_text(messages)
  defp user_text(messages) when is_list(messages), do: Enum.flat_map(messages, &message_text/1)
  defp user_text(_other), do: []

  defp message_text(%{role: role, content: content}) when role in [:user, "user"],
    do: content_text(content)

  defp message_text(%{"role" => "user", "content" => content}), do: content_text(content)
  defp message_text(_message), do: []

  defp content_text(text) when is_binary(text), do: [text]

  defp content_text(parts) when is_list(parts) do
    Enum.flat_map(parts, fn
      text when is_binary(text) -> [text]
      %{text: text} when is_binary(text) -> [text]
      %{"text" => text} when is_binary(text) -> [text]
      _part -> []
    end)
  end

  defp content_text(_content), do: []
end
