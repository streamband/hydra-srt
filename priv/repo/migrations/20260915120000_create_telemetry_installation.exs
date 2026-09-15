defmodule HydraSrt.Repo.Migrations.CreateTelemetryInstallation do
  use Ecto.Migration

  def change do
    create table(:telemetry_installation, primary_key: false) do
      add :id, :integer, primary_key: true
      add :installation_id, :string
      add :last_heartbeat_at, :utc_datetime_usec
      add :last_seen_version, :string
      timestamps(type: :utc_datetime_usec)
    end
  end
end
