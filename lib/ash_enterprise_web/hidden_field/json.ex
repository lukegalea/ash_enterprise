# A secured column read without its grant (`AshEnterpriseWeb.HiddenField`) is `null` on
# the JSON wire, as AshJsonApi renders a forbidden field.
defimpl Jason.Encoder, for: Ash.ForbiddenField do
  def encode(_hidden, _opts), do: "null"
end
