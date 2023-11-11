defmodule Demo.Section do
  use Ecto.Schema

  import Ecto.Query
  import Ecto.Changeset
  import Pgvector.Ecto.Query

  alias __MODULE__

  schema "sections" do
    field(:page, :integer)
    field(:text, :string)
    field(:filepath, :string)
    field(:embedding, Pgvector.Ecto.Vector)

    belongs_to(:document, Demo.Document)

    timestamps()
  end

  @required_attrs [:page, :text, :document_id, :filepath]
  @optional_attrs [:embedding]

  def changeset(section, params \\ %{}) do
    section
    |> cast(params, @required_attrs ++ @optional_attrs)
    |> validate_required(@required_attrs)
  end

  def search_document_embedding(document_id, embedding) do
    from(s in Section,
      select: {s.id, s.page, s.text, s.document_id},
      where: s.document_id == ^document_id,
      order_by: max_inner_product(s.embedding, ^embedding),
      limit: 4
    )
    |> Demo.Repo.all()
  end

  def search_document_text(document_id, search) do
    from(s in Section,
      select: {s.id, s.page, s.text, s.document_id},
      where:
        s.document_id == ^document_id and
          fragment("to_tsvector('english', ?) @@ plainto_tsquery('english', ?)", s.text, ^search),
      order_by: [
        desc:
          fragment(
            "ts_rank_cd(to_tsvector('english', ?), plainto_tsquery('english', ?))",
            s.text,
            ^search
          )
      ],
      limit: 4
    )
    |> Demo.Repo.all()
  end
end
