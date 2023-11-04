defmodule Demo.Repo.Migrations.AddDocumentIndex do
  use Ecto.Migration

  def change do
    create index(:sections, [:document_id])
  end
end
