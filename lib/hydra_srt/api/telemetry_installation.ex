defmodule HydraSrt.Api.TelemetryInstallation do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}

  schema "telemetry_installation" do
    field :installation_id, :string
    field :last_heartbeat_at, :utc_datetime_usec
    field :last_seen_version, :string
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{} | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(installation, attrs) do
    installation
    |> cast(attrs, [:id, :installation_id, :last_heartbeat_at, :last_seen_version])
    |> validate_required(:id)
    |> validate_number(:id, equal_to: 1)
    |> validate_change(:installation_id, fn :installation_id, value ->
      if is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value)),
        do: [],
        else: [format: "must be a UUID"]
    end)
    |> validate_length(:last_seen_version, max: 64)
  end
end
