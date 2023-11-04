defmodule Demo.Section do
  use Ecto.Schema

  import Ecto.Query
  import Ecto.Changeset
  import Pgvector.Ecto.Query

  alias __MODULE__

  schema "sections" do
    field(:page, :integer)
    field(:text, :string)
    field(:embedding, Pgvector.Ecto.Vector)

    belongs_to(:document, Demo.Document)

    timestamps()
  end

  @required_attrs [:page, :text, :document_id]
  @optional_attrs [:embedding]

  def changeset(section, params \\ %{}) do
    section
    |> cast(params, @required_attrs ++ @optional_attrs)
    |> validate_required(@required_attrs)
  end

  def search(embedding) do
    Demo.Repo.all(
      from s in Section, order_by: max_inner_product(s.embedding, ^embedding), limit: 1
    )
    |> List.first()
  end
end
