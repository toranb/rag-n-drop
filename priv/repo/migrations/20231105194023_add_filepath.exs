defmodule Demo.Repo.Migrations.AddFilepath do
  use Ecto.Migration

  def change do
    alter table(:sections) do
      add :filepath, :string, null: false
    end
  end
end
