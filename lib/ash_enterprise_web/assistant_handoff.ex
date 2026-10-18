defmodule AshEnterpriseWeb.AssistantHandoff do
  @moduledoc """
  Carries a question from the Helper (`AshEnterpriseWeb.AgentLive`) to the
  assistant (`AshEnterpriseWeb.AssistantLive`), which asks it.

  The Helper is an administrative console: it has no tools for a person's
  own calendar, mail or tasks. When its classifier reads a request as one of
  those (`:ask_assistant`), the Helper navigates to `/app/agent?ask=<token>`
  and the assistant asks the question as the signed-in person.

  The token is **encrypted**, not merely signed, and short-lived:

    * the question is the person's own words, and a URL lands in browser
      history and request logs, so the text never travels in the clear;
    * it binds the person who asked: the assistant asks it only for that
      user, so a link someone else crafted or forwarded asks nothing;
    * it expires after #{60} seconds, enough for one navigation.

  Asking runs a read-only model turn as the person (the assistant's tools
  read and propose; nothing changes until they confirm), so the token
  guards whose question it is, not a write.
  """

  @salt "assistant handoff"
  @max_age 60

  @doc "A token carrying `question` from `user` to the assistant."
  @spec token(%{id: term()}, String.t()) :: String.t()
  def token(%{id: user_id}, question) when is_binary(question) do
    Phoenix.Token.encrypt(AshEnterpriseWeb.Endpoint, @salt, %{"u" => user_id, "q" => question})
  end

  @doc """
  The question `token` carries for `user`: `{:ok, question}`, or `:error`
  when it is expired, tampered with, or another person's.
  """
  @spec question(%{id: term()} | nil, String.t()) :: {:ok, String.t()} | :error
  def question(%{id: user_id}, token) when is_binary(token) do
    case Phoenix.Token.decrypt(AshEnterpriseWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{"u" => ^user_id, "q" => question}} when is_binary(question) -> {:ok, question}
      _expired_tampered_or_not_theirs -> :error
    end
  end

  def question(_user, _token), do: :error
end
