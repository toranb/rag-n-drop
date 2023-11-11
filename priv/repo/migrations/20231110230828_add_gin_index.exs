defmodule Demo.Repo.Migrations.AddGinIndex do
  use Ecto.Migration

  def change do
    execute """
      CREATE INDEX sections_text_search_idx ON sections USING GIN (to_tsvector('english', text));
    """
  end
end
