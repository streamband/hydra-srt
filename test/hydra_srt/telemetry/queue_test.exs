defmodule HydraSrt.Telemetry.QueueTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Telemetry.{Queue, StartedEvent}

  setup do
    original = Application.get_env(:hydra_srt, :telemetry)
    on_exit(fn -> Application.put_env(:hydra_srt, :telemetry, original) end)
    :ok
  end

  test "enqueue is bounded by count and drops the oldest event" do
    Application.put_env(:hydra_srt, :telemetry, queue_max_events: 3, queue_max_bytes: 1_048_576)
    start_supervised!(Queue)

    events = Enum.map(1..4, &started_event("0.#{&1}.0"))
    Enum.each(events, &Queue.enqueue/1)

    assert %{count: 3, bytes: bytes} = Queue.size()
    assert bytes > 0

    assert [
             %StartedEvent{version: "0.2.0"},
             %StartedEvent{version: "0.3.0"},
             %StartedEvent{version: "0.4.0"}
           ] =
             Queue.take_batch(10)
  end

  test "byte bound also drops oldest entries" do
    event = started_event("0.6.9")
    {:ok, encoded} = HydraSrt.Telemetry.Event.encode(event)

    Application.put_env(:hydra_srt, :telemetry,
      queue_max_events: 10,
      queue_max_bytes: byte_size(encoded) - 1
    )

    start_supervised!(Queue)

    Queue.enqueue(event)
    assert Queue.size() == %{count: 0, bytes: 0}
  end

  test "take_batch drains only the requested batch and discard_signal resets a lane" do
    Application.put_env(:hydra_srt, :telemetry, queue_max_events: 10, queue_max_bytes: 1_048_576)
    start_supervised!(Queue)

    events = Enum.map(1..3, &started_event("0.#{&1}.0"))
    Enum.each(events, &Queue.enqueue/1)

    assert [%StartedEvent{version: "0.1.0"}, %StartedEvent{version: "0.2.0"}] =
             Queue.take_batch(2)

    assert %{count: 1, bytes: bytes} = Queue.size()
    assert bytes > 0
    assert :ok = Queue.discard_signal(:usage)
    assert Queue.size() == %{count: 0, bytes: 0}
  end

  test "requeue restores encoded events" do
    Application.put_env(:hydra_srt, :telemetry, queue_max_events: 10, queue_max_bytes: 1_048_576)
    start_supervised!(Queue)
    event = started_event("0.6.9")

    assert :ok = Queue.requeue([event])
    assert [%StartedEvent{}] = Queue.take_batch(1)
  end

  def started_event(version) do
    %StartedEvent{
      version: version,
      distribution: :source,
      installation_id: Ecto.UUID.generate(),
      session_id: Ecto.UUID.generate()
    }
  end
end
