defmodule Demo.Document do
  use Ecto.Schema

  import Ecto.Changeset

  schema "documents" do
    field(:title, :string)
    field(:machine, :string)

    has_many(:sections, Demo.Section, preload_order: [asc: :inserted_at])

    timestamps()
  end

  @required_attrs [:title, :machine]

  def changeset(document, params \\ %{}) do
    document
    |> cast(params, @required_attrs)
    |> validate_required(@required_attrs)
  end
end
