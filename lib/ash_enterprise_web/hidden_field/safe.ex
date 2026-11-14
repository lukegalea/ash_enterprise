# A secured column read without its grant (`AshEnterpriseWeb.HiddenField`): a template
# shows the masked text, escaped like any other string.
defimpl Phoenix.HTML.Safe, for: Ash.ForbiddenField do
  def to_iodata(_hidden),
    do: Phoenix.HTML.Engine.html_escape(AshEnterpriseWeb.HiddenField.masked())
end
