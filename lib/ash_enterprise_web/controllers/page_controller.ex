defmodule AshEnterpriseWeb.PageController do
  use AshEnterpriseWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
