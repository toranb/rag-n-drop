defmodule Demo.Repo.Migrations.AddDocumentSection do
  use Ecto.Migration

  def change do
    create table(:documents) do
      add :title, :string, null: false
      add :machine, :string, null: false

      timestamps()
    end

    create table(:sections) do
      add :page, :integer, null: false
      add :text, :text, null: false
      add :embedding, :vector, size: 384

      add :document_id, references(:documents), null: false

      timestamps()
    end

    create index("sections", ["embedding vector_cosine_ops"], using: :hnsw)
  end
end
