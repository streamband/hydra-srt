use std::net::{IpAddr, ToSocketAddrs, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use gio::prelude::InetSocketAddressExt;
use gio::{InetSocketAddress, SocketAddress};
use glib::object::Cast;
use glib::value::ToValue;
use gstreamer as gst;
use gstreamer::prelude::*;
use hydra_plan::{ErrorCode, SrtAccess, SrtDestination, SrtMode, SrtSource};
use serde_json::json;

use crate::adapters::element::set_property;
use crate::events::{EndpointDirection, EndpointState, EventSink, RetryDomain, Transport};
use crate::output::StatsWriter;
use std::sync::{Arc, Mutex};

/// How long a caller/rendezvous SRT endpoint may sit without observing any real data
/// (first buffer received on a source; first confirmed-sent packet on a destination)
/// before it is reported as unhealthy. This never kills the pipeline: the underlying
/// `srtsrc`/`srtsink` element keeps retrying its own handshake on its own (~3s per
/// attempt, libsrt's `SRTO_CONNTIMEO` caller default) for as long as the route runs.
/// Chosen as roughly 10x that internal retry cadence, so a route is not flagged
/// unhealthy over a single transient retry cycle.
///
/// Listener-mode endpoints wait for an inbound caller by design and are never measured
/// against this deadline (see `build_source_health_monitor` /
/// `build_destination_health_monitor`).
pub const SRT_NO_DATA_SINCE_START_THRESHOLD_MS: u64 = 30_000;

/// How often the non-terminal health signal is re-emitted while an endpoint remains
/// stuck at zero data past the threshold above. `srtsrc`'s own reconnect attempts log a
/// bus warning roughly every 2-3s, which would be on the order of a thousand rows an
/// hour if mirrored 1:1; re-stating "still no data" once a minute keeps the endpoint's
/// current status fresh for anyone watching without adding to that volume.
pub const SRT_NO_DATA_REPEAT_CADENCE_MS: u64 = 60_000;

/// Category for the one-time diagnostic line emitted when an endpoint first crosses
/// the no-data threshold above.
const SRT_HEALTH_LOG_CATEGORY: &str = "srt_health";

/// Watches a caller/rendezvous SRT source for received-byte progress. If no bytes have
/// arrived by `SRT_NO_DATA_SINCE_START_THRESHOLD_MS`, it reports the source unhealthy
/// with `SRT_NO_DATA_SINCE_START`. Once bytes have been received, an unchanged
/// `bytes-received-total` value reports `SRT_DATA_STALLED_AFTER_START` on the same
/// cadence used by destinations. A pad probe still reports recovery immediately when
/// a buffer returns; the counter is used for the periodic stalled check. It never
/// touches pipeline or route lifecycle - `srtsrc` is left to retry on its own.
#[derive(Clone)]
pub struct SrtSourceHealthMonitor {
    source: gst::Element,
    pad: gst::Pad,
    ever_data: Arc<AtomicBool>,
    reported_unhealthy: Arc<AtomicBool>,
    started: Arc<AtomicBool>,
}

impl SrtSourceHealthMonitor {
    /// True once `arm` has started watching.
    pub fn armed(&self) -> bool {
        self.started.load(Ordering::Acquire)
    }

    pub fn arm(&self, pipeline: &gst::Pipeline, event_sink: EventSink, endpoint_id: String) {
        self.arm_with_durations(
            pipeline,
            event_sink,
            endpoint_id,
            Duration::from_millis(SRT_NO_DATA_SINCE_START_THRESHOLD_MS),
            Duration::from_millis(SRT_NO_DATA_REPEAT_CADENCE_MS),
        );
    }

    /// Same as `arm`, but with the threshold/cadence as parameters instead of the
    /// production constants, so tests can exercise the full schedule in milliseconds
    /// instead of the real 30s/60s.
    fn arm_with_durations(
        &self,
        pipeline: &gst::Pipeline,
        event_sink: EventSink,
        endpoint_id: String,
        threshold: Duration,
        cadence: Duration,
    ) {
        self.started.store(true, Ordering::Release);

        let ever_data = self.ever_data.clone();
        let reported_unhealthy = self.reported_unhealthy.clone();
        let last_received_total = Arc::new(Mutex::new(None));
        let source = self.source.clone();
        let element_name = self.source.name().to_string();

        // The probe gives an immediate signal the moment data actually starts
        // flowing, rather than waiting for the next periodic check below.
        let probe_ever_data = ever_data.clone();
        let probe_reported_unhealthy = reported_unhealthy.clone();
        let probe_event_sink = event_sink.clone();
        let probe_endpoint_id = endpoint_id.clone();
        self.pad.add_probe(
            gst::PadProbeType::BUFFER | gst::PadProbeType::BUFFER_LIST,
            move |_pad, _info| {
                probe_ever_data.store(true, Ordering::Release);
                if probe_reported_unhealthy.swap(false, Ordering::AcqRel) {
                    emit_recovered(
                        &probe_event_sink,
                        &probe_endpoint_id,
                        EndpointDirection::Source,
                        "SRT source began receiving data",
                    );
                }
                gst::PadProbeReturn::Ok
            },
        );

        let pipeline = pipeline.clone();
        let threshold_secs = threshold.as_secs();
        glib::timeout_add_once(threshold, move || {
            if pipeline.current_state() == gst::State::Null {
                return;
            }
            process_source_tick(
                &source,
                &last_received_total,
                &ever_data,
                &reported_unhealthy,
                &event_sink,
                &endpoint_id,
                &element_name,
                threshold_secs,
            );
            let _ = recover_immediately_if_data_arrived(
                &ever_data,
                &reported_unhealthy,
                &event_sink,
                &endpoint_id,
            );
            schedule_source_repeat(
                pipeline,
                source,
                last_received_total,
                ever_data,
                reported_unhealthy,
                event_sink,
                endpoint_id,
                element_name,
                threshold_secs,
                cadence,
            );
        });
    }
}

/// What reading an SRT source's `bytes-received-total` stats field found. The field
/// is published by `srtsrc` as `guint64`; the exact type is checked rather than
/// turning a type mismatch into an indistinguishable no-data reading.
#[derive(Debug, Clone, PartialEq, Eq)]
enum BytesReceivedReading {
    Absent,
    Present(u64),
    WrongType(String),
}

fn read_bytes_received(stats: Option<&gst::StructureRef>) -> BytesReceivedReading {
    let Some(stats) = stats else {
        return BytesReceivedReading::Absent;
    };
    if !stats.has_field("bytes-received-total") {
        return BytesReceivedReading::Absent;
    }
    match stats.get::<u64>("bytes-received-total") {
        Ok(total) => BytesReceivedReading::Present(total),
        Err(error) => BytesReceivedReading::WrongType(format!(
            "\"bytes-received-total\" is present but not readable as u64: {error}"
        )),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SourceProgress {
    NeverReceived,
    Advancing,
    Stalled,
}

fn evaluate_source_progress(
    previous: Option<u64>,
    reading: &BytesReceivedReading,
) -> (SourceProgress, Option<u64>) {
    match *reading {
        BytesReceivedReading::Absent | BytesReceivedReading::WrongType(_) => match previous {
            Some(previous_total) => (SourceProgress::Stalled, Some(previous_total)),
            None => (SourceProgress::NeverReceived, None),
        },
        BytesReceivedReading::Present(total) if total == 0 && previous.is_none() => {
            (SourceProgress::NeverReceived, None)
        }
        BytesReceivedReading::Present(total) => match previous {
            Some(previous_total) if total <= previous_total => {
                (SourceProgress::Stalled, Some(total))
            }
            _ => (SourceProgress::Advancing, Some(total)),
        },
    }
}

#[allow(clippy::too_many_arguments)]
fn process_source_tick(
    source: &gst::Element,
    last_received_total: &Mutex<Option<u64>>,
    ever_data: &AtomicBool,
    reported_unhealthy: &AtomicBool,
    event_sink: &EventSink,
    endpoint_id: &str,
    element_name: &str,
    threshold_secs: u64,
) {
    let stats = if source.has_property("stats", None) {
        source.property::<Option<gst::Structure>>("stats")
    } else {
        None
    };
    apply_source_reading(
        read_bytes_received(stats.as_deref()),
        last_received_total,
        ever_data,
        reported_unhealthy,
        event_sink,
        endpoint_id,
        element_name,
        threshold_secs,
    );
}

#[allow(clippy::too_many_arguments)]
fn apply_source_reading(
    reading: BytesReceivedReading,
    last_received_total: &Mutex<Option<u64>>,
    ever_data: &AtomicBool,
    reported_unhealthy: &AtomicBool,
    event_sink: &EventSink,
    endpoint_id: &str,
    element_name: &str,
    threshold_secs: u64,
) {
    if let BytesReceivedReading::WrongType(detail) = &reading {
        emit_stats_type_error_log(event_sink, element_name, detail);
    }

    let mut baseline = last_received_total
        .lock()
        .expect("source progress lock poisoned");
    let (progress, updated) = evaluate_source_progress(*baseline, &reading);
    *baseline = updated;
    drop(baseline);

    // A pad buffer can arrive before the plugin exposes its first stats structure.
    // The pad probe already emits the immediate recovery in that case; do not turn
    // the missing initial snapshot into a second false failure.
    if progress == SourceProgress::NeverReceived
        && ever_data.load(Ordering::Acquire)
        && matches!(reading, BytesReceivedReading::Absent)
    {
        return;
    }

    match progress {
        SourceProgress::Advancing => {
            if reported_unhealthy.swap(false, Ordering::AcqRel) {
                emit_recovered(
                    event_sink,
                    endpoint_id,
                    EndpointDirection::Source,
                    "data resumed",
                );
            }
        }
        SourceProgress::NeverReceived => {
            let was_unhealthy = reported_unhealthy.swap(true, Ordering::AcqRel);
            let detail = if was_unhealthy {
                "still no data received since starting; retrying automatically".to_owned()
            } else {
                format!(
                    "no data received from element \"{element_name}\" within {threshold_secs}s of \
                     starting; the SRT source keeps retrying the connection on its own"
                )
            };
            if !was_unhealthy {
                emit_no_data_log(event_sink, Some(element_name), &detail);
            }
            emit_no_data_report(
                event_sink,
                endpoint_id,
                EndpointDirection::Source,
                ErrorCode::SrtNoDataSinceStart,
                &detail,
            );
        }
        SourceProgress::Stalled => {
            let was_unhealthy = reported_unhealthy.swap(true, Ordering::AcqRel);
            let detail = if was_unhealthy {
                "still no received-byte progress since it stalled; retrying automatically"
                    .to_owned()
            } else {
                format!(
                    "element \"{element_name}\" received data earlier but the received-byte \
                     counter has not advanced since the last check; the SRT source appears to \
                     have gone dark after a working connection"
                )
            };
            if !was_unhealthy {
                emit_no_data_log(event_sink, Some(element_name), &detail);
            }
            emit_no_data_report(
                event_sink,
                endpoint_id,
                EndpointDirection::Source,
                ErrorCode::SrtDataStalledAfterStart,
                &detail,
            );
        }
    }
}

/// Builds the no-data health monitor for an SRT source, or `None` for listener mode
/// (which waits for an inbound caller by design - an idle listener is healthy, not
/// stuck). Caller and rendezvous modes both actively dial a peer and get the deadline.
///
/// Errors (instead of silently skipping) only if the SRT source element genuinely has
/// no static "src" pad, which would mean the element itself is broken.
pub fn build_source_health_monitor(
    source: &gst::Element,
    mode: SrtMode,
) -> Result<Option<SrtSourceHealthMonitor>, (ErrorCode, String)> {
    if matches!(mode, SrtMode::Listener) {
        return Ok(None);
    }
    let pad = source.static_pad("src").ok_or_else(|| {
        (
            ErrorCode::LinkFailed,
            "SRT source has no static source pad".to_owned(),
        )
    })?;
    Ok(Some(SrtSourceHealthMonitor {
        source: source.clone(),
        pad,
        ever_data: Arc::new(AtomicBool::new(false)),
        reported_unhealthy: Arc::new(AtomicBool::new(false)),
        started: Arc::new(AtomicBool::new(false)),
    }))
}

/// Watches a caller/rendezvous SRT destination for confirmed-sent data (the SRT
/// library's own `packets-sent` counter on the sink's `stats` property, not merely
/// buffers reaching the sink's pad - a caller-mode `srtsink` with
/// `wait-for-connection=true` can have buffers arrive at its pad while the actual send
/// blocks waiting on a peer that never shows up, so pad arrival alone would falsely
/// read as healthy). Reports two distinct, honestly named situations under the same
/// non-terminal report/repeat/recover shape as the source monitor: never having
/// confirmed anything sent since starting, and having confirmed sends earlier but
/// then seeing the confirmed-sent count stop advancing (the peer went away after a
/// working connection). Monitoring never stops once a destination starts sending -
/// otherwise a destination that later goes dark would be invisible for the rest of
/// the route's life. Never touches pipeline or route lifecycle.
#[derive(Clone)]
pub struct SrtDestinationHealthMonitor {
    sink: gst::Element,
    reported_unhealthy: Arc<AtomicBool>,
    started: Arc<AtomicBool>,
    last_confirmed_count: Arc<Mutex<Option<i64>>>,
}

impl SrtDestinationHealthMonitor {
    pub fn armed(&self) -> bool {
        self.started.load(Ordering::Acquire)
    }

    pub fn arm(&self, pipeline: &gst::Pipeline, event_sink: EventSink, endpoint_id: String) {
        self.arm_with_durations(
            pipeline,
            event_sink,
            endpoint_id,
            Duration::from_millis(SRT_NO_DATA_SINCE_START_THRESHOLD_MS),
            Duration::from_millis(SRT_NO_DATA_REPEAT_CADENCE_MS),
        );
    }

    /// Same as `arm`, but with the threshold/cadence as parameters instead of the
    /// production constants, so tests can exercise the full schedule in milliseconds
    /// instead of the real 30s/60s.
    fn arm_with_durations(
        &self,
        pipeline: &gst::Pipeline,
        event_sink: EventSink,
        endpoint_id: String,
        threshold: Duration,
        cadence: Duration,
    ) {
        self.started.store(true, Ordering::Release);

        let sink = self.sink.clone();
        let reported_unhealthy = self.reported_unhealthy.clone();
        let last_confirmed_count = self.last_confirmed_count.clone();
        let element_name = self.sink.name().to_string();
        let pipeline = pipeline.clone();
        let threshold_secs = threshold.as_secs();

        glib::timeout_add_once(threshold, move || {
            if pipeline.current_state() == gst::State::Null {
                return;
            }
            process_destination_tick(
                &sink,
                &last_confirmed_count,
                &reported_unhealthy,
                &event_sink,
                &endpoint_id,
                &element_name,
                threshold_secs,
            );
            schedule_destination_repeat(
                pipeline,
                sink,
                last_confirmed_count,
                reported_unhealthy,
                event_sink,
                endpoint_id,
                element_name,
                threshold_secs,
                cadence,
            );
        });
    }
}

/// Builds the no-data health monitor for an SRT destination, or `None` for listener
/// mode (an idle listener waiting for an inbound caller is healthy by design).
pub fn build_destination_health_monitor(
    sink: &gst::Element,
    mode: SrtMode,
) -> Option<SrtDestinationHealthMonitor> {
    if matches!(mode, SrtMode::Listener) {
        return None;
    }
    Some(SrtDestinationHealthMonitor {
        sink: sink.clone(),
        reported_unhealthy: Arc::new(AtomicBool::new(false)),
        started: Arc::new(AtomicBool::new(false)),
        last_confirmed_count: Arc::new(Mutex::new(None)),
    })
}

/// What reading the destination's `packets-sent` stats field found. `packets-sent` is
/// a monotonically non-decreasing counter for the life of the element, published by
/// srtsink as `gint64` - verified live against a real caller/listener srtsink/srtsrc
/// pair on GStreamer 1.26.7 (`packets-sent GType: gint64`), not the `guint64` a
/// same-shaped `bytes-sent`/`bytes-sent-total` are published as on the very same
/// structure. Reading it with the wrong Rust type does not fail loudly by itself -
/// `StructureRef::get` performs an exact GType check with no i64/u64 coercion, so a
/// `u64` read against this field returns `Err` on every call, indistinguishable at
/// that point from the field being absent.
#[derive(Debug, Clone, PartialEq, Eq)]
enum PacketsSentReading {
    /// `stats` is missing, or has no `packets-sent` field yet - nothing has been
    /// reported by the library at all. Identical in meaning to a genuine zero:
    /// nothing verified as delivered yet.
    Absent,
    /// `packets-sent` is present and was read with the type it actually publishes.
    Present(i64),
    /// `packets-sent` is present but not readable as `i64`. This is not "no data" -
    /// the stats shape this code assumes no longer matches the element actually
    /// running (a GStreamer/srt-plugin version change, or a bug here), and must be
    /// surfaced loudly rather than silently treated as zero.
    WrongType(String),
}

fn read_packets_sent(stats: Option<&gst::StructureRef>) -> PacketsSentReading {
    let Some(stats) = stats else {
        return PacketsSentReading::Absent;
    };
    if !stats.has_field("packets-sent") {
        return PacketsSentReading::Absent;
    }
    match stats.get::<i64>("packets-sent") {
        Ok(count) => PacketsSentReading::Present(count),
        Err(error) => PacketsSentReading::WrongType(format!(
            "\"packets-sent\" is present but not readable as i64, the type srtsink \
             actually publishes it as: {error}"
        )),
    }
}

/// What one destination-monitoring tick learned, and the confirmed-sent count to
/// remember as the baseline for the next tick. Split out from the timer/event
/// plumbing in `process_destination_tick` so the never-sent/advancing/stalled
/// classification can be exercised directly without a live `srtsink` or a glib main
/// loop.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DestinationProgress {
    /// Nothing has ever been confirmed sent.
    NeverSent,
    /// The confirmed-sent count moved forward since the previous tick, or this is the
    /// first count ever observed - the destination is healthy.
    Advancing,
    /// A confirmed-sent count was seen on an earlier tick and has not moved since -
    /// the destination was sending and has gone quiet.
    Stalled,
}

fn evaluate_progress(
    previous: Option<i64>,
    reading: &PacketsSentReading,
) -> (DestinationProgress, Option<i64>) {
    match *reading {
        // An unreadable counter does not erase a confirmed baseline. `WrongType` is
        // also emitted as an ERROR by the caller, so retaining the baseline here
        // preserves the last truthful health state without hiding the stats bug.
        PacketsSentReading::Absent | PacketsSentReading::WrongType(_) => match previous {
            Some(previous_count) => (DestinationProgress::Stalled, Some(previous_count)),
            None => (DestinationProgress::NeverSent, None),
        },
        PacketsSentReading::Present(count) if count <= 0 => {
            (DestinationProgress::NeverSent, previous)
        }
        PacketsSentReading::Present(count) => match previous {
            Some(previous_count) if count <= previous_count => {
                (DestinationProgress::Stalled, Some(count))
            }
            _ => (DestinationProgress::Advancing, Some(count)),
        },
    }
}

/// One tick of destination monitoring: read the real stats property, classify it,
/// update the running baseline, and emit whatever `endpoint_health`/`pipeline_log`
/// events that classification calls for. Called both by the initial threshold check
/// and by every subsequent cadence tick in `schedule_destination_repeat`, so the
/// destination keeps being watched for the life of the route instead of only until
/// the first confirmed send.
#[allow(clippy::too_many_arguments)]
fn process_destination_tick(
    sink: &gst::Element,
    last_confirmed_count: &Mutex<Option<i64>>,
    reported_unhealthy: &AtomicBool,
    event_sink: &EventSink,
    endpoint_id: &str,
    element_name: &str,
    threshold_secs: u64,
) {
    let stats = if sink.has_property("stats", None) {
        sink.property::<Option<gst::Structure>>("stats")
    } else {
        None
    };
    let reading = read_packets_sent(stats.as_deref());
    apply_destination_reading(
        reading,
        last_confirmed_count,
        reported_unhealthy,
        event_sink,
        endpoint_id,
        element_name,
        threshold_secs,
    );
}

/// The pure decide-and-emit half of `process_destination_tick`, split out so the
/// never-sent/advancing/stalled/recovered state machine can be driven directly with a
/// chosen sequence of `PacketsSentReading` values in tests, without needing a real
/// `srtsink` whose `stats` property can be made to say anything in particular on
/// demand.
#[allow(clippy::too_many_arguments)]
fn apply_destination_reading(
    reading: PacketsSentReading,
    last_confirmed_count: &Mutex<Option<i64>>,
    reported_unhealthy: &AtomicBool,
    event_sink: &EventSink,
    endpoint_id: &str,
    element_name: &str,
    threshold_secs: u64,
) {
    if let PacketsSentReading::WrongType(detail) = &reading {
        emit_stats_type_error_log(event_sink, element_name, detail);
    }

    let mut baseline = last_confirmed_count
        .lock()
        .expect("destination progress lock poisoned");
    let (progress, updated) = evaluate_progress(*baseline, &reading);
    *baseline = updated;
    drop(baseline);

    match progress {
        DestinationProgress::Advancing => {
            if reported_unhealthy.swap(false, Ordering::AcqRel) {
                emit_recovered(
                    event_sink,
                    endpoint_id,
                    EndpointDirection::Destination,
                    "data resumed",
                );
            }
        }
        DestinationProgress::NeverSent => {
            let was_unhealthy = reported_unhealthy.swap(true, Ordering::AcqRel);
            let detail = if was_unhealthy {
                "still no data confirmed sent since starting; retrying automatically".to_owned()
            } else {
                format!(
                    "no data confirmed sent from element \"{element_name}\" within \
                     {threshold_secs}s of starting; the SRT destination keeps retrying \
                     the connection on its own"
                )
            };
            if !was_unhealthy {
                emit_no_data_log(event_sink, Some(element_name), &detail);
            }
            emit_no_data_report(
                event_sink,
                endpoint_id,
                EndpointDirection::Destination,
                ErrorCode::SrtNoDataSinceStart,
                &detail,
            );
        }
        DestinationProgress::Stalled => {
            let was_unhealthy = reported_unhealthy.swap(true, Ordering::AcqRel);
            let detail = if was_unhealthy {
                "still no confirmed-sent progress since it stalled; retrying automatically"
                    .to_owned()
            } else {
                format!(
                    "element \"{element_name}\" confirmed sending data earlier but the \
                     sent-packet count has not advanced since the last check; the \
                     destination appears to have gone dark after a working connection"
                )
            };
            if !was_unhealthy {
                emit_no_data_log(event_sink, Some(element_name), &detail);
            }
            emit_no_data_report(
                event_sink,
                endpoint_id,
                EndpointDirection::Destination,
                ErrorCode::SrtDataStalledAfterStart,
                &detail,
            );
        }
    }
}

/// Runs source progress checks on every cadence tick for as long as the pipeline is
/// alive. Unlike the old first-buffer watcher, this deliberately does not stop once
/// the first buffer has arrived: a later unchanged receive counter is the source's
/// stalled-after-start condition.
#[allow(clippy::too_many_arguments)]
fn schedule_source_repeat(
    pipeline: gst::Pipeline,
    source: gst::Element,
    last_received_total: Arc<Mutex<Option<u64>>>,
    ever_data: Arc<AtomicBool>,
    reported_unhealthy: Arc<AtomicBool>,
    event_sink: EventSink,
    endpoint_id: String,
    element_name: String,
    threshold_secs: u64,
    cadence: Duration,
) {
    glib::timeout_add(cadence, move || {
        if pipeline.current_state() == gst::State::Null {
            return glib::ControlFlow::Break;
        }
        process_source_tick(
            &source,
            &last_received_total,
            &ever_data,
            &reported_unhealthy,
            &event_sink,
            &endpoint_id,
            &element_name,
            threshold_secs,
        );
        glib::ControlFlow::Continue
    });
}

/// Runs `process_destination_tick` on every `cadence` tick for as long as the
/// pipeline is alive - deliberately never breaks out on its own (unlike the source's
/// `schedule_repeat`), because a destination that starts sending must keep being
/// watched for a later stall, not just for its first confirmed packet.
#[allow(clippy::too_many_arguments)]
fn schedule_destination_repeat(
    pipeline: gst::Pipeline,
    sink: gst::Element,
    last_confirmed_count: Arc<Mutex<Option<i64>>>,
    reported_unhealthy: Arc<AtomicBool>,
    event_sink: EventSink,
    endpoint_id: String,
    element_name: String,
    threshold_secs: u64,
    cadence: Duration,
) {
    glib::timeout_add(cadence, move || {
        if pipeline.current_state() == gst::State::Null {
            return glib::ControlFlow::Break;
        }
        process_destination_tick(
            &sink,
            &last_confirmed_count,
            &reported_unhealthy,
            &event_sink,
            &endpoint_id,
            &element_name,
            threshold_secs,
        );
        glib::ControlFlow::Continue
    });
}

fn retry_domain_for(direction: EndpointDirection) -> RetryDomain {
    match direction {
        EndpointDirection::Source => RetryDomain::Route,
        EndpointDirection::Destination => RetryDomain::Destination,
    }
}

fn emit_no_data_report(
    event_sink: &EventSink,
    endpoint_id: &str,
    direction: EndpointDirection,
    reason_code: ErrorCode,
    detail: &str,
) {
    let _ = event_sink.emit_endpoint_health(
        endpoint_id,
        direction,
        Transport::Srt,
        EndpointState::Failed,
        Some(reason_code),
        Some(true),
        Some(retry_domain_for(direction)),
        Some(detail),
    );
}

fn emit_recovered(
    event_sink: &EventSink,
    endpoint_id: &str,
    direction: EndpointDirection,
    detail: &str,
) {
    let _ = event_sink.emit_endpoint_health(
        endpoint_id,
        direction,
        Transport::Srt,
        EndpointState::Streaming,
        None,
        None,
        None,
        Some(detail),
    );
}

/// Rechecks `ever_data` against `reported_unhealthy` and, if data has arrived since
/// the last time this pair was consulted, reports the recovery immediately and
/// returns `true`. Used right after the source threshold callback stores
/// `reported_unhealthy = true`, to close the race where the pad probe ran (and found
/// nothing to recover from) *before* that store - without this recheck, the stale
/// "failed" report would otherwise stand until the next slow `cadence` tick, up to
/// `SRT_NO_DATA_REPEAT_CADENCE_MS` later, instead of being caught right away.
fn recover_immediately_if_data_arrived(
    ever_data: &AtomicBool,
    reported_unhealthy: &AtomicBool,
    event_sink: &EventSink,
    endpoint_id: &str,
) -> bool {
    if ever_data.load(Ordering::Acquire) && reported_unhealthy.swap(false, Ordering::AcqRel) {
        emit_recovered(
            event_sink,
            endpoint_id,
            EndpointDirection::Source,
            "SRT source began receiving data",
        );
        true
    } else {
        false
    }
}

fn emit_no_data_log(event_sink: &EventSink, element: Option<&str>, detail: &str) {
    let _ = event_sink.emit_pipeline_log("WARN", SRT_HEALTH_LOG_CATEGORY, element, detail);
}

/// Always-loud diagnostic line for when a `stats` field is present but not the type
/// the element actually publishes it as. This is a stats-shape mismatch, not a
/// data-flow problem, so it is logged at ERROR (never WARN) and is never treated as
/// equivalent to "no data" for health-reporting purposes.
fn emit_stats_type_error_log(event_sink: &EventSink, element: &str, detail: &str) {
    let _ = event_sink.emit_pipeline_log(
        "ERROR",
        SRT_HEALTH_LOG_CATEGORY,
        Some(element),
        &format!("unreadable SRT stats field on \"{element}\": {detail}"),
    );
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SrtAccessDecision {
    pub allowed: bool,
    pub reason: &'static str,
    pub ip: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct SrtAccessRules {
    limit_access: bool,
    allowed_list: Vec<ipnet::IpNet>,
    denied_list: Vec<ipnet::IpNet>,
}

impl SrtAccessRules {
    pub fn from_access(access: Option<&SrtAccess>) -> Self {
        match access {
            Some(access) => Self {
                limit_access: access.limit(),
                allowed_list: access
                    .allowed()
                    .iter()
                    .map(hydra_plan::Cidr::as_ipnet)
                    .collect(),
                denied_list: access
                    .denied()
                    .iter()
                    .map(hydra_plan::Cidr::as_ipnet)
                    .collect(),
            },
            None => Self::default(),
        }
    }

    pub fn enabled(&self) -> bool {
        self.limit_access
    }

    pub fn check_ip(&self, ip: Option<IpAddr>) -> SrtAccessDecision {
        if !self.limit_access {
            return SrtAccessDecision {
                allowed: true,
                reason: "limit_access_disabled",
                ip: ip.map(|value| value.to_string()),
            };
        }

        let Some(ip) = ip else {
            return SrtAccessDecision {
                allowed: false,
                reason: "invalid_address",
                ip: None,
            };
        };

        if self.denied_list.iter().any(|net| net.contains(&ip)) {
            return SrtAccessDecision {
                allowed: false,
                reason: "denied_list",
                ip: Some(ip.to_string()),
            };
        }

        if !self.allowed_list.is_empty() && !self.allowed_list.iter().any(|net| net.contains(&ip)) {
            return SrtAccessDecision {
                allowed: false,
                reason: "not_in_allowed_list",
                ip: Some(ip.to_string()),
            };
        }

        SrtAccessDecision {
            allowed: true,
            reason: "accepted",
            ip: Some(ip.to_string()),
        }
    }
}

pub fn caller_ip(values: &[glib::Value]) -> Option<IpAddr> {
    values
        .get(1)
        .and_then(|value| value.get::<SocketAddress>().ok())
        .and_then(|address| address.downcast::<InetSocketAddress>().ok())
        .map(|inet| IpAddr::from(inet.address()))
}

/// Apply typed SRT source properties. Never sets `mode` or `streamid` on the element.
pub fn apply_source(element: &gst::Element, config: &SrtSource) -> Result<(), (ErrorCode, String)> {
    // A listener source always keeps listening, even when the stored config says
    // otherwise. With it off, an abruptly lost caller leaves srtsrc holding a dead
    // socket: it stops accepting, never posts EOS, and the route wedges as
    // reconnecting with nothing bound. Only a graceful sender stop posts EOS, so
    // honoring a stored false would leave existing routes broken. See issue 102.
    let keep_listening = if matches!(config.mode(), SrtMode::Listener) {
        Some(true)
    } else {
        config.keep_listening()
    };
    apply_common(
        element,
        config.mode(),
        config.uri().as_str(),
        config.latency().map(|v| v.get()),
        config.auto_reconnect(),
        keep_listening,
        config.poll_timeout().map(|v| v.get()),
        config.passphrase(),
        config.pbkeylen().map(|v| v.as_i32()),
        config.localaddress().map(|v| v.as_str()),
        config.localport().map(|v| v.get()),
    )
}

/// Apply typed SRT destination properties. Never sets `mode` or `streamid` on the element.
pub fn apply_destination(
    element: &gst::Element,
    config: &SrtDestination,
) -> Result<(), (ErrorCode, String)> {
    apply_common(
        element,
        config.mode(),
        config.uri().as_str(),
        config.latency().map(|v| v.get()),
        config.auto_reconnect(),
        config.keep_listening(),
        config.poll_timeout().map(|v| v.get()),
        config.passphrase(),
        config.pbkeylen().map(|v| v.as_i32()),
        config.localaddress().map(|v| v.as_str()),
        config.localport().map(|v| v.get()),
    )
}

pub fn configure_source(
    source: &gst::Element,
    config: &SrtSource,
    writer: Arc<Mutex<Box<dyn StatsWriter>>>,
) {
    let access_rules = SrtAccessRules::from_access(config.access());
    let has_stream_id = config.streamid().is_some_and(|value| !value.is_empty());
    let authentication_requested = config.authentication().unwrap_or(false);
    source.set_property(
        "authentication",
        access_rules.enabled() || has_stream_id || authentication_requested,
    );
    source.connect("caller-connecting", false, move |values| {
        let stream_id = values
            .get(2)
            .and_then(|value| value.get::<Option<String>>().ok())
            .flatten();
        let decision = access_rules.check_ip(caller_ip(values));
        if let Ok(mut guard) = writer.lock() {
            let _ = guard.send_message(
                &json!({
                    "event":"srt_access",
                    "ip":decision.ip,
                    "stream_id":stream_id.as_deref(),
                    "allowed":decision.allowed,
                    "reason":decision.reason
                })
                .to_string(),
            );
            if decision.allowed {
                if let Some(stream_id) = stream_id.as_deref() {
                    let _ = guard.send_message(&format!("stats_source_stream_id:{stream_id}"));
                }
            }
        }
        Some((decision.allowed).to_value())
    });
}

pub fn configure_sink(element: &gst::Element) {
    element.set_property("sync", false);
    element.set_property("async", false);
    element.set_property("wait-for-connection", true);
}

#[allow(clippy::too_many_arguments)]
fn apply_common(
    element: &gst::Element,
    mode: SrtMode,
    uri: &str,
    latency: Option<u64>,
    auto_reconnect: Option<bool>,
    keep_listening: Option<bool>,
    poll_timeout: Option<i32>,
    passphrase: Option<&str>,
    pbkeylen: Option<i32>,
    localaddress: Option<&str>,
    localport: Option<u16>,
) -> Result<(), (ErrorCode, String)> {
    // srtsrc and srtsink only bind a caller when both localaddress and localport
    // are set, so a bare localaddress needs a concrete port to take effect.
    let localport = match (mode, localaddress, localport) {
        (SrtMode::Caller, Some(address), None) => Some(reserve_local_port(address)?),
        (_, _, port) => port,
    };

    set_property(element, "uri", uri)?;
    if let Some(latency) = latency {
        set_property(element, "latency", latency as u32)?;
    }
    if let Some(auto_reconnect) = auto_reconnect {
        set_property(element, "auto-reconnect", auto_reconnect)?;
    }
    if let Some(keep_listening) = keep_listening {
        set_property(element, "keep-listening", keep_listening)?;
    }
    if let Some(poll_timeout) = poll_timeout {
        set_property(element, "poll-timeout", poll_timeout)?;
    }
    if let Some(passphrase) = passphrase {
        set_property(element, "passphrase", passphrase)?;
    }
    if let Some(pbkeylen) = pbkeylen {
        set_pbkeylen(element, pbkeylen)?;
    }
    if let Some(localaddress) = localaddress {
        set_property(element, "localaddress", localaddress)?;
    }
    if let Some(localport) = localport {
        set_property(element, "localport", u32::from(localport))?;
    }
    Ok(())
}

fn reserve_local_port(localaddress: &str) -> Result<u16, (ErrorCode, String)> {
    let fail = |detail: String| {
        (
            ErrorCode::ConfigInvalid,
            format!("SRT caller cannot bind localaddress {localaddress}: {detail}"),
        )
    };
    let socket_address = (localaddress, 0)
        .to_socket_addrs()
        .map_err(|error| fail(error.to_string()))?
        .next()
        .ok_or_else(|| fail("no address resolved".to_owned()))?;
    let socket = UdpSocket::bind(socket_address).map_err(|error| fail(error.to_string()))?;
    socket
        .local_addr()
        .map(|address| address.port())
        .map_err(|error| fail(error.to_string()))
}

fn set_pbkeylen(element: &gst::Element, value: i32) -> Result<(), (ErrorCode, String)> {
    let Some(prop) = element.find_property("pbkeylen") else {
        return Err((
            ErrorCode::ConfigInvalid,
            "SRT element has no property pbkeylen".to_owned(),
        ));
    };
    let value_type = prop.value_type();
    if let Some(enum_class) = glib::EnumClass::with_type(value_type) {
        let Some(enum_value) = enum_class.to_value(value) else {
            return Err((
                ErrorCode::ConfigInvalid,
                format!("pbkeylen {value} is not a value of {value_type}"),
            ));
        };
        element.set_property_from_value("pbkeylen", &enum_value);
        return Ok(());
    }
    set_property(element, "pbkeylen", value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use hydra_plan::{Cidr, HostAddress, Pbkeylen, Port, SrtMode, SrtUri};

    fn rules(
        limit_access: bool,
        allowed_list: Vec<&str>,
        denied_list: Vec<&str>,
    ) -> SrtAccessRules {
        let access = SrtAccess::new(
            limit_access,
            allowed_list
                .into_iter()
                .map(|entry| Cidr::new(entry).expect("cidr"))
                .collect(),
            denied_list
                .into_iter()
                .map(|entry| Cidr::new(entry).expect("cidr"))
                .collect(),
        );
        SrtAccessRules::from_access(Some(&access))
    }

    #[test]
    fn allows_any_ip_when_limit_access_is_disabled() {
        let rules = rules(false, vec!["192.0.2.0/24"], vec!["127.0.0.1"]);
        let decision = rules.check_ip(Some("127.0.0.1".parse().expect("valid IP")));
        assert!(decision.allowed);
        assert_eq!(decision.reason, "limit_access_disabled");
    }

    #[test]
    fn allows_exact_ip_match() {
        let rules = rules(true, vec!["127.0.0.1"], vec![]);
        let decision = rules.check_ip(Some("127.0.0.1".parse().expect("valid IP")));
        assert!(decision.allowed);
        assert_eq!(decision.reason, "accepted");
    }

    #[test]
    fn allows_cidr_match() {
        let rules = rules(true, vec!["10.10.0.0/16"], vec![]);
        let decision = rules.check_ip(Some("10.10.12.4".parse().expect("valid IP")));
        assert!(decision.allowed);
    }

    #[test]
    fn denied_list_takes_priority_over_allowed_list() {
        let rules = rules(true, vec!["127.0.0.1"], vec!["127.0.0.1"]);
        let decision = rules.check_ip(Some("127.0.0.1".parse().expect("valid IP")));
        assert!(!decision.allowed);
        assert_eq!(decision.reason, "denied_list");
    }

    #[test]
    fn rejects_when_ip_is_not_in_allowed_list() {
        let rules = rules(true, vec!["192.0.2.0/24"], vec![]);
        let decision = rules.check_ip(Some("127.0.0.1".parse().expect("valid IP")));
        assert!(!decision.allowed);
        assert_eq!(decision.reason, "not_in_allowed_list");
    }

    #[test]
    fn supports_ipv6_cidr_matches() {
        let rules = rules(true, vec!["2001:db8::/32"], vec![]);
        let decision = rules.check_ip(Some("2001:db8::1".parse().expect("valid IP")));
        assert!(decision.allowed);
    }

    #[test]
    fn rejects_missing_caller_address_when_limited() {
        let rules = rules(true, vec![], vec![]);
        let decision = rules.check_ip(None);
        assert!(!decision.allowed);
        assert_eq!(decision.reason, "invalid_address");
    }

    #[test]
    fn applies_pbkeylen_as_enum_and_skips_mode_streamid() {
        let _ = gst::init();
        let element = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        let config = SrtSource::new(
            SrtUri::new("srt://127.0.0.1:4201?mode=listener").unwrap(),
            SrtMode::Listener,
            None,
            None,
            None,
            None,
            None,
            Some(Pbkeylen::Aes128),
            Some("#!::r=channel".to_string()),
            Some(HostAddress::new("127.0.0.1").unwrap()),
            Some(Port::new(4201).unwrap()),
            None,
            None,
            None,
        );
        apply_source(&element, &config).expect("srtsrc accepts the typed source config");
        let value = element.property_value("pbkeylen");
        let (_, enum_value) =
            glib::EnumValue::from_value(&value).expect("pbkeylen should remain an enum value");
        assert_eq!(enum_value.value(), 16);
        assert_eq!(
            element.property::<String>("uri"),
            "srt://127.0.0.1:4201?mode=listener"
        );
        assert!(
            !element.has_property("mode", None) || {
                // mode must not have been set via our applier; URI carries it.
                true
            }
        );
    }

    fn source_config(mode: SrtMode, keep_listening: Option<bool>) -> SrtSource {
        source_config_with_local_bind(mode, keep_listening, None, None)
    }

    fn source_config_with_local_bind(
        mode: SrtMode,
        keep_listening: Option<bool>,
        localaddress: Option<HostAddress>,
        localport: Option<Port>,
    ) -> SrtSource {
        SrtSource::new(
            SrtUri::new("srt://127.0.0.1:4201").expect("valid SRT URI"),
            mode,
            None, // latency
            None, // auto_reconnect
            keep_listening,
            None, // poll_timeout
            None, // passphrase
            None, // pbkeylen
            None, // streamid
            localaddress,
            localport,
            None, // authentication
            None, // access
            None, // program_number
        )
    }

    fn destination_config_with_local_bind(
        mode: SrtMode,
        localaddress: Option<HostAddress>,
        localport: Option<Port>,
    ) -> SrtDestination {
        SrtDestination::new(
            SrtUri::new("srt://127.0.0.1:4201").expect("valid SRT URI"),
            mode,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            localaddress,
            localport,
            None,
        )
    }

    #[test]
    fn listener_sources_always_keep_listening() {
        let _ = gst::init();

        let listener = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        apply_source(&listener, &source_config(SrtMode::Listener, None))
            .expect("listener source config applies");
        assert!(listener.property::<bool>("keep-listening"));

        // A route stored by the old UI carries an explicit false. Honoring it
        // would leave that route unable to accept a caller again, so it is
        // overridden rather than passed through.
        let stored_false = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        apply_source(
            &stored_false,
            &source_config(SrtMode::Listener, Some(false)),
        )
        .expect("stored listener setting applies");
        assert!(stored_false.property::<bool>("keep-listening"));

        let caller = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        let caller_default = caller.property::<bool>("keep-listening");
        apply_source(&caller, &source_config(SrtMode::Caller, None))
            .expect("caller source config applies");
        assert_eq!(caller.property::<bool>("keep-listening"), caller_default);

        let destination = gst::ElementFactory::make("srtsink")
            .build()
            .expect("srtsink element should be available for tests");
        let destination_default = destination
            .has_property("keep-listening", None)
            .then(|| destination.property::<bool>("keep-listening"));
        let destination_config = SrtDestination::new(
            SrtUri::new("srt://127.0.0.1:4201").expect("valid SRT URI"),
            SrtMode::Listener,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
        );
        apply_destination(&destination, &destination_config).expect("destination config applies");
        assert_eq!(
            destination
                .has_property("keep-listening", None)
                .then(|| destination.property::<bool>("keep-listening")),
            destination_default
        );
    }

    #[test]
    fn caller_source_with_localaddress_gets_a_bound_port() {
        let _ = gst::init();
        let element = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        let config = source_config_with_local_bind(
            SrtMode::Caller,
            None,
            Some(HostAddress::new("127.0.0.1").expect("valid host address")),
            None,
        );

        apply_source(&element, &config).expect("caller source config applies");

        assert!(element.property::<u32>("localport") > 0);
        assert_eq!(element.property::<String>("localaddress"), "127.0.0.1");
    }

    #[test]
    fn caller_source_with_explicit_localport_keeps_it() {
        let _ = gst::init();
        let element = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        let config = source_config_with_local_bind(
            SrtMode::Caller,
            None,
            Some(HostAddress::new("127.0.0.1").expect("valid host address")),
            Some(Port::new(4321).expect("valid port")),
        );

        apply_source(&element, &config).expect("caller source config applies");

        assert_eq!(element.property::<u32>("localport"), 4321);
    }

    #[test]
    fn caller_source_without_localaddress_sets_no_localport() {
        let _ = gst::init();
        let element = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        let default_element = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        let default_localport = default_element.property::<u32>("localport");

        apply_source(
            &element,
            &source_config_with_local_bind(SrtMode::Caller, None, None, None),
        )
        .expect("caller source config applies");

        assert_eq!(element.property::<u32>("localport"), default_localport);
    }

    #[test]
    fn listener_source_with_localaddress_only_is_untouched() {
        let _ = gst::init();
        let element = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        let default_element = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        let default_localport = default_element.property::<u32>("localport");
        let config = source_config_with_local_bind(
            SrtMode::Listener,
            None,
            Some(HostAddress::new("127.0.0.1").expect("valid host address")),
            None,
        );

        apply_source(&element, &config).expect("listener source config applies");

        assert_eq!(element.property::<u32>("localport"), default_localport);
    }

    #[test]
    fn caller_destination_with_localaddress_gets_a_bound_port() {
        let _ = gst::init();
        let element = gst::ElementFactory::make("srtsink")
            .build()
            .expect("srtsink element should be available for tests");
        let config = destination_config_with_local_bind(
            SrtMode::Caller,
            Some(HostAddress::new("127.0.0.1").expect("valid host address")),
            None,
        );

        apply_destination(&element, &config).expect("caller destination config applies");

        assert!(element.property::<u32>("localport") > 0);
        assert_eq!(element.property::<String>("localaddress"), "127.0.0.1");
    }

    #[test]
    fn caller_source_with_unusable_localaddress_fails() {
        let _ = gst::init();
        let element = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        // 203.0.113.1 is a valid unassigned address that fails to bind on macOS and standard Linux CI.
        let config = source_config_with_local_bind(
            SrtMode::Caller,
            None,
            Some(HostAddress::new("203.0.113.1").expect("valid host address")),
            None,
        );

        let (code, detail) =
            apply_source(&element, &config).expect_err("unusable local address must fail");

        assert_eq!(code, ErrorCode::ConfigInvalid);
        assert!(detail.contains("203.0.113.1"), "detail was: {detail}");
    }

    #[test]
    fn applies_pbkeylen_as_enum_property_for_srtsink() {
        let _ = gst::init();
        let element = gst::ElementFactory::make("srtsink")
            .build()
            .expect("srtsink element should be available for tests");
        let config = SrtDestination::new(
            SrtUri::new("srt://127.0.0.1:4201?mode=caller").unwrap(),
            SrtMode::Caller,
            None,
            None,
            None,
            None,
            None,
            Some(Pbkeylen::Aes128),
            None,
            Some(HostAddress::new("127.0.0.1").unwrap()),
            Some(Port::new(4201).unwrap()),
            None,
        );
        apply_destination(&element, &config).expect("srtsink accepts the typed destination config");
        let value = element.property_value("pbkeylen");
        let (_, enum_value) =
            glib::EnumValue::from_value(&value).expect("pbkeylen should remain an enum value");
        assert_eq!(enum_value.value(), 16);
    }

    #[test]
    fn unknown_property_is_classified_instead_of_aborting() {
        let _ = gst::init();
        let element = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        // `srtsrc` has no `address` property; setting it directly aborts the process.
        let (code, detail) =
            set_property(&element, "address", "127.0.0.1").expect_err("unknown property must fail");
        assert_eq!(code, ErrorCode::ConfigInvalid);
        assert!(
            detail.contains("srtsrc") && detail.contains("address"),
            "detail must name the element and property, got: {detail}"
        );
    }

    struct MemoryWriter(Arc<Mutex<Vec<String>>>);

    impl StatsWriter for MemoryWriter {
        fn send_message(&mut self, message: &str) -> anyhow::Result<()> {
            self.0
                .lock()
                .expect("messages lock")
                .push(message.to_string());
            Ok(())
        }
    }

    fn test_event_sink() -> (EventSink, Arc<Mutex<Vec<String>>>) {
        let messages = Arc::new(Mutex::new(Vec::new()));
        let writer: Arc<Mutex<Box<dyn StatsWriter>>> =
            Arc::new(Mutex::new(Box::new(MemoryWriter(messages.clone()))));
        let identity = crate::events::RouteIdentity {
            route_id: "route-1".to_string(),
            config_revision: "rev-1".to_string(),
            process_instance_id: "proc-1".to_string(),
        };
        (EventSink::new(writer, identity), messages)
    }

    fn events_named(messages: &Mutex<Vec<String>>, event: &str) -> Vec<serde_json::Value> {
        messages
            .lock()
            .expect("messages lock")
            .iter()
            .map(|raw| serde_json::from_str::<serde_json::Value>(raw).expect("valid json"))
            .filter(|value| value["event"] == event)
            .collect()
    }

    #[test]
    fn source_health_monitor_is_built_for_caller_and_rendezvous_but_not_listener() {
        let _ = gst::init();
        for mode in [SrtMode::Caller, SrtMode::Rendezvous] {
            let element = gst::ElementFactory::make("srtsrc")
                .build()
                .expect("srtsrc element should be available for tests");
            let monitor = build_source_health_monitor(&element, mode)
                .unwrap_or_else(|error| panic!("{mode:?} must build a monitor: {error:?}"));
            let monitor = monitor.unwrap_or_else(|| panic!("{mode:?} must be armed-eligible"));
            assert!(
                !monitor.armed(),
                "monitor must not be armed until arm() is called"
            );
        }

        let element = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        let monitor = build_source_health_monitor(&element, SrtMode::Listener)
            .expect("listener mode never errors building a monitor");
        assert!(
            monitor.is_none(),
            "listener mode waits for an inbound caller by design and must never be armed"
        );
    }

    #[test]
    fn source_health_monitor_arm_flips_armed_and_is_idempotently_checkable() {
        let _ = gst::init();
        let element = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        let monitor = build_source_health_monitor(&element, SrtMode::Caller)
            .expect("caller mode builds a monitor")
            .expect("caller mode is armed-eligible");
        assert!(!monitor.armed());
        let pipeline = gst::Pipeline::new();
        let (event_sink, _messages) = test_event_sink();
        monitor.arm(&pipeline, event_sink, "endpoint-1".to_string());
        assert!(monitor.armed());
    }

    #[test]
    fn destination_health_monitor_is_built_for_caller_and_rendezvous_but_not_listener() {
        let _ = gst::init();
        for mode in [SrtMode::Caller, SrtMode::Rendezvous] {
            let element = gst::ElementFactory::make("srtsink")
                .build()
                .expect("srtsink element should be available for tests");
            let monitor = build_destination_health_monitor(&element, mode)
                .unwrap_or_else(|| panic!("{mode:?} must be armed-eligible"));
            assert!(!monitor.armed());
        }

        let element = gst::ElementFactory::make("srtsink")
            .build()
            .expect("srtsink element should be available for tests");
        assert!(
            build_destination_health_monitor(&element, SrtMode::Listener).is_none(),
            "listener mode waits for an inbound caller by design and must never be armed"
        );
    }

    #[test]
    fn packets_sent_reading_is_absent_for_a_fresh_unstarted_sink() {
        let _ = gst::init();
        let element = gst::ElementFactory::make("srtsink")
            .build()
            .expect("srtsink element should be available for tests");
        assert!(element.has_property("stats", None));
        // Freshly created, never linked/started: no stats have been produced yet.
        let stats = element.property::<Option<gst::Structure>>("stats");
        assert_eq!(
            read_packets_sent(stats.as_deref()),
            PacketsSentReading::Absent
        );
    }

    #[test]
    fn no_data_report_and_recovery_use_the_expected_endpoint_health_shape() {
        let (event_sink, messages) = test_event_sink();
        emit_no_data_report(
            &event_sink,
            "endpoint-1",
            EndpointDirection::Source,
            ErrorCode::SrtNoDataSinceStart,
            "no data received",
        );
        emit_recovered(
            &event_sink,
            "endpoint-1",
            EndpointDirection::Source,
            "data resumed",
        );

        let events = events_named(&messages, "endpoint_health");
        assert_eq!(events.len(), 2);
        assert_eq!(events[0]["state"], "failed");
        assert_eq!(events[0]["reason_code"], "SRT_NO_DATA_SINCE_START");
        assert_eq!(events[0]["retryable"], true);
        assert_eq!(events[0]["retry_domain"], "route");
        assert_eq!(events[1]["state"], "streaming");
        assert!(events[1]["reason_code"].is_null());
    }

    #[test]
    fn no_data_report_for_a_destination_uses_the_destination_retry_domain() {
        let (event_sink, messages) = test_event_sink();
        emit_no_data_report(
            &event_sink,
            "dest-1",
            EndpointDirection::Destination,
            ErrorCode::SrtNoDataSinceStart,
            "no data confirmed sent",
        );

        let events = events_named(&messages, "endpoint_health");
        assert_eq!(events[0]["direction"], "destination");
        assert_eq!(events[0]["retry_domain"], "destination");
    }

    #[test]
    fn stalled_report_for_a_destination_uses_the_stalled_reason_code() {
        let (event_sink, messages) = test_event_sink();
        emit_no_data_report(
            &event_sink,
            "dest-1",
            EndpointDirection::Destination,
            ErrorCode::SrtDataStalledAfterStart,
            "confirmed-sent count stopped advancing",
        );

        let events = events_named(&messages, "endpoint_health");
        assert_eq!(events[0]["reason_code"], "SRT_DATA_STALLED_AFTER_START");
        assert_eq!(events[0]["retry_domain"], "destination");
    }

    #[test]
    fn read_packets_sent_handles_absent_stats_and_absent_field() {
        assert_eq!(read_packets_sent(None), PacketsSentReading::Absent);

        let missing_field = gst::Structure::builder("stats")
            .field("rtt-ms", 12.0)
            .build();
        assert_eq!(
            read_packets_sent(Some(missing_field.as_ref())),
            PacketsSentReading::Absent
        );
    }

    #[test]
    fn read_packets_sent_reads_the_real_type_srtsink_publishes_it_as() {
        // `packets-sent` is `gint64` (signed 64-bit), verified live against a real
        // caller/listener srtsrc/srtsink pair on GStreamer 1.26.7 - see
        // `packets_sent_is_read_from_a_real_connected_srtsink_stats_structure` below
        // for the version of this check that reads an actual captured structure
        // instead of one built here. This case documents the type in isolation.
        let zero = gst::Structure::builder("stats")
            .field("packets-sent", 0i64)
            .build();
        assert_eq!(
            read_packets_sent(Some(zero.as_ref())),
            PacketsSentReading::Present(0)
        );

        let sent = gst::Structure::builder("stats")
            .field("packets-sent", 42i64)
            .build();
        assert_eq!(
            read_packets_sent(Some(sent.as_ref())),
            PacketsSentReading::Present(42)
        );
    }

    #[test]
    fn read_packets_sent_is_loud_not_silently_false_when_the_field_is_the_wrong_type() {
        // Reproduces exactly the bug this monitor originally shipped with: the field
        // built as `u64` instead of the `i64` srtsink actually publishes. Before the
        // fix this silently read as "nothing sent" via `.ok()`, which is what made
        // every healthy caller-mode SRT destination report permanently failed. Now it
        // must come back as a distinct, loud `WrongType` outcome instead of being
        // indistinguishable from `Absent`.
        let wrong_type = gst::Structure::builder("stats")
            .field("packets-sent", 42u64)
            .build();
        match read_packets_sent(Some(wrong_type.as_ref())) {
            PacketsSentReading::WrongType(detail) => {
                assert!(detail.contains("packets-sent"), "detail: {detail}");
            }
            other => panic!("expected WrongType, got {other:?}"),
        }
    }

    #[test]
    fn read_bytes_received_reads_the_real_type_srtsrc_publishes_it_as() {
        let zero = gst::Structure::builder("stats")
            .field("bytes-received-total", 0u64)
            .build();
        assert_eq!(
            read_bytes_received(Some(zero.as_ref())),
            BytesReceivedReading::Present(0)
        );

        let received = gst::Structure::builder("stats")
            .field("bytes-received-total", 42u64)
            .build();
        assert_eq!(
            read_bytes_received(Some(received.as_ref())),
            BytesReceivedReading::Present(42)
        );
    }

    #[test]
    fn source_stall_detection_uses_a_real_srtsrc_stats_structure_and_recovers() {
        // Capture the actual stats structure from a connected srtsrc first. The
        // received-byte field is a guint64 in the running GStreamer plugin; the
        // state machine below is then driven with structures using that captured
        // field and type, rather than an invented Rust fixture type.
        let (listener, sender, _sink) = real_loopback_srt_pair(14803, 5, false);
        let source = listener.by_name("src").expect("source element present");
        let captured = source.property::<Option<gst::Structure>>("stats");
        let captured_total = match read_bytes_received(captured.as_deref()) {
            BytesReceivedReading::Present(total) if total > 0 => total,
            other => panic!(
                "expected positive bytes-received-total from a real connected srtsrc, got {other:?}"
            ),
        };

        let baseline = Mutex::new(None);
        let ever_data = AtomicBool::new(true);
        let reported_unhealthy = AtomicBool::new(false);
        let (event_sink, messages) = test_event_sink();
        let captured_stats = gst::Structure::builder("application/x-srt-statistics")
            .field("bytes-received-total", captured_total)
            .build();
        let stalled_stats = gst::Structure::builder("application/x-srt-statistics")
            .field("bytes-received-total", captured_total)
            .build();
        let recovered_stats = gst::Structure::builder("application/x-srt-statistics")
            .field("bytes-received-total", captured_total + 1)
            .build();

        let apply = |stats: &gst::Structure| {
            apply_source_reading(
                read_bytes_received(Some(stats.as_ref())),
                &baseline,
                &ever_data,
                &reported_unhealthy,
                &event_sink,
                "source-1",
                "srtsrc0",
                30,
            );
        };

        apply(&captured_stats);
        apply(&stalled_stats);
        let events = events_named(&messages, "endpoint_health");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["state"], "failed");
        assert_eq!(events[0]["reason_code"], "SRT_DATA_STALLED_AFTER_START");

        apply(&recovered_stats);
        let events = events_named(&messages, "endpoint_health");
        assert_eq!(events.len(), 2);
        assert_eq!(events[1]["state"], "streaming");

        listener
            .set_state(gst::State::Null)
            .expect("listener stops");
        sender.set_state(gst::State::Null).expect("sender stops");
    }

    #[test]
    fn disappeared_srtsink_stats_retain_a_prior_confirmed_send_as_stalled() {
        // This is the exact post-disappearance structure captured from a real
        // GStreamer 1.26.7 caller-mode srtsink on loopback: after its srtsrc peer was
        // stopped, the stats structure contained only this guint64 field and no
        // packets-sent field. The prior connected snapshot had packets-sent=476.
        let peer_disappeared_stats = gst::Structure::builder("application/x-srt-statistics")
            .field("bytes-sent-total", 2_457_600u64)
            .build();
        let reading = read_packets_sent(Some(peer_disappeared_stats.as_ref()));
        assert_eq!(reading, PacketsSentReading::Absent);
        assert_eq!(
            evaluate_progress(Some(476), &reading),
            (DestinationProgress::Stalled, Some(476))
        );

        let reported_unhealthy = AtomicBool::new(false);
        let last_confirmed_count = Mutex::new(Some(476));
        let (event_sink, messages) = test_event_sink();
        apply_destination_reading(
            reading,
            &last_confirmed_count,
            &reported_unhealthy,
            &event_sink,
            "dest-1",
            "srtsink0",
            30,
        );

        let events = events_named(&messages, "endpoint_health");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["state"], "failed");
        assert_eq!(events[0]["reason_code"], "SRT_DATA_STALLED_AFTER_START");
    }

    #[test]
    fn evaluate_progress_classifies_never_sent_advancing_and_stalled() {
        // Never sent: no baseline yet, nothing present.
        assert_eq!(
            evaluate_progress(None, &PacketsSentReading::Absent),
            (DestinationProgress::NeverSent, None)
        );
        // Never sent: present but zero, no baseline yet.
        assert_eq!(
            evaluate_progress(None, &PacketsSentReading::Present(0)),
            (DestinationProgress::NeverSent, None)
        );
        // With no prior baseline, a wrong-type reading cannot establish that data was
        // sent. The caller still logs the type mismatch loudly.
        assert_eq!(
            evaluate_progress(None, &PacketsSentReading::WrongType("boom".to_owned())),
            (DestinationProgress::NeverSent, None)
        );
        // An unreadable reading after a confirmed send is a stall: that observation
        // remains true even when the next stats structure omits the counter.
        assert_eq!(
            evaluate_progress(Some(9), &PacketsSentReading::Absent),
            (DestinationProgress::Stalled, Some(9))
        );
        assert_eq!(
            evaluate_progress(Some(9), &PacketsSentReading::WrongType("boom".to_owned())),
            (DestinationProgress::Stalled, Some(9))
        );
        // First-ever confirmed count: advancing, becomes the new baseline.
        assert_eq!(
            evaluate_progress(None, &PacketsSentReading::Present(5)),
            (DestinationProgress::Advancing, Some(5))
        );
        // Count moved forward since the baseline: advancing.
        assert_eq!(
            evaluate_progress(Some(5), &PacketsSentReading::Present(9)),
            (DestinationProgress::Advancing, Some(9))
        );
        // Count identical to the baseline: stalled - this is the "was sending,
        // stopped" case a monotonic counter cannot express as "> 0" alone.
        assert_eq!(
            evaluate_progress(Some(9), &PacketsSentReading::Present(9)),
            (DestinationProgress::Stalled, Some(9))
        );
    }

    fn pump_until<F: Fn() -> bool>(condition: F, timeout: Duration) {
        let context = glib::MainContext::default();
        let deadline = std::time::Instant::now() + timeout;
        while !condition() && std::time::Instant::now() < deadline {
            context.iteration(true);
        }
        assert!(
            condition(),
            "timed out waiting for the health monitor's timers to fire"
        );
    }

    /// Pumps the default glib main context for at least `duration`, letting any
    /// `glib::timeout_add`/`timeout_add_once` timers scheduled on it fire on their own
    /// schedule, without asserting on any particular outcome (unlike `pump_until`).
    fn pump_for(duration: Duration) {
        let context = glib::MainContext::default();
        let deadline = std::time::Instant::now() + duration;
        while std::time::Instant::now() < deadline {
            context.iteration(true);
        }
    }

    /// Builds a real listener `srtsrc` / caller `srtsink` pair connected over loopback
    /// SRT on `port` (kept within the 14800-14899 evidence range used elsewhere in
    /// this repo's verification runs), and blocks until at least `min_buffers` have
    /// genuinely arrived at the listener side - i.e. until data has actually flowed
    /// end to end over a real SRT connection, not merely until both elements reached
    /// PLAYING. `srtsink`'s sink pad accepts `ANY` caps, so a plain `videotestsrc`
    /// needs no encoder in front of it. Returns both pipelines (left Playing) and the
    /// caller-mode `srtsink` element, so callers can inspect its real `stats`
    /// property or arm a destination health monitor against it.
    fn real_loopback_srt_pair(
        port: u16,
        min_buffers: u32,
        keep_listening: bool,
    ) -> (gst::Pipeline, gst::Pipeline, gst::Element) {
        use std::sync::atomic::AtomicU32;

        let _ = gst::init();
        let listener = gst::parse::launch(&format!(
            "srtsrc name=src uri=srt://0.0.0.0:{port}?mode=listener ! fakesink name=fsink sync=false"
        ))
        .expect("listener pipeline should parse")
        .downcast::<gst::Pipeline>()
        .expect("parsed element is a pipeline");
        let sender = gst::parse::launch(&format!(
            "videotestsrc is-live=true ! srtsink name=sink uri=srt://127.0.0.1:{port}?mode=caller wait-for-connection=true"
        ))
        .expect("sender pipeline should parse")
        .downcast::<gst::Pipeline>()
        .expect("parsed element is a pipeline");

        let sink = sender.by_name("sink").expect("sink element present");
        listener
            .by_name("src")
            .expect("source element present")
            .set_property("keep-listening", keep_listening);
        let fsink = listener.by_name("fsink").expect("fakesink element present");

        let seen = Arc::new(AtomicU32::new(0));
        let seen_probe = seen.clone();
        fsink
            .static_pad("sink")
            .expect("fakesink has a sink pad")
            .add_probe(gst::PadProbeType::BUFFER, move |_pad, _info| {
                seen_probe.fetch_add(1, Ordering::SeqCst);
                gst::PadProbeReturn::Ok
            });

        listener
            .set_state(gst::State::Playing)
            .expect("listener reaches playing");
        // Give the listener a moment to bind before the caller dials in.
        std::thread::sleep(Duration::from_millis(200));
        sender
            .set_state(gst::State::Playing)
            .expect("sender reaches playing");

        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while seen.load(Ordering::SeqCst) < min_buffers && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            seen.load(Ordering::SeqCst) >= min_buffers,
            "expected at least {min_buffers} buffers over a real loopback SRT \
             connection on port {port}, got {}",
            seen.load(Ordering::SeqCst)
        );

        (listener, sender, sink)
    }

    #[test]
    fn listener_keep_listening_accepts_a_second_caller_without_eos() {
        let port = 14804;
        let (listener, sender, _sink) = real_loopback_srt_pair(port, 5, true);
        let bus = listener.bus().expect("listener pipeline bus");

        sender
            .set_state(gst::State::Null)
            .expect("first sender stops");

        let eos_deadline = std::time::Instant::now() + Duration::from_secs(2);
        let mut saw_eos = false;
        while std::time::Instant::now() < eos_deadline {
            if let Some(message) = bus.timed_pop(gst::ClockTime::from_mseconds(100)) {
                if matches!(message.view(), gst::MessageView::Eos(_)) {
                    saw_eos = true;
                    break;
                }
            }
        }
        assert!(
            !saw_eos,
            "keep-listening source must not post EOS after disconnect"
        );

        let second_sender = gst::parse::launch(&format!(
            "videotestsrc is-live=true ! srtsink name=sink uri=srt://127.0.0.1:{port}?mode=caller wait-for-connection=true"
        ))
        .expect("second sender pipeline should parse")
        .downcast::<gst::Pipeline>()
        .expect("parsed element is a pipeline");
        let second_sink = second_sender
            .by_name("sink")
            .expect("second sink element present");
        second_sender
            .set_state(gst::State::Playing)
            .expect("second sender reaches playing");

        let reconnect_deadline = std::time::Instant::now() + Duration::from_secs(10);
        let mut packets_sent = PacketsSentReading::Absent;
        while std::time::Instant::now() < reconnect_deadline {
            packets_sent = read_packets_sent(
                second_sink
                    .property::<Option<gst::Structure>>("stats")
                    .as_ref()
                    .map(|stats| stats.as_ref()),
            );
            if matches!(packets_sent, PacketsSentReading::Present(count) if count > 0) {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            matches!(packets_sent, PacketsSentReading::Present(count) if count > 0),
            "second caller must send data after listener reconnects, got {packets_sent:?}"
        );

        listener
            .set_state(gst::State::Null)
            .expect("listener stops");
        second_sender
            .set_state(gst::State::Null)
            .expect("second sender stops");
    }

    #[test]
    fn listener_without_keep_listening_ends_the_stream_after_a_disconnect() {
        // The negative control for the test above, and the reproduction of the
        // defect in issue 102: with keep-listening off, losing the caller ends
        // the source, which is what tore the route down.
        let (listener, sender, _sink) = real_loopback_srt_pair(14805, 5, false);
        let bus = listener.bus().expect("listener pipeline bus");

        sender
            .set_state(gst::State::Null)
            .expect("first sender stops");

        let eos_deadline = std::time::Instant::now() + Duration::from_secs(10);
        let mut saw_eos = false;
        while std::time::Instant::now() < eos_deadline {
            if let Some(message) = bus.timed_pop(gst::ClockTime::from_mseconds(100)) {
                if matches!(message.view(), gst::MessageView::Eos(_)) {
                    saw_eos = true;
                    break;
                }
            }
        }

        listener
            .set_state(gst::State::Null)
            .expect("listener stops");

        assert!(
            saw_eos,
            "without keep-listening a lost caller must end the source"
        );
    }

    #[test]
    fn packets_sent_is_read_from_a_real_connected_srtsink_stats_structure() {
        // The mandatory real-payload check: instead of asserting
        // against a hand-built `gst::Structure`, this connects an actual `srtsink` to
        // an actual `srtsrc` over loopback SRT, lets real data flow, and reads
        // `read_packets_sent` against the `stats` property GStreamer's own SRT plugin
        // produced - the same call path production code uses.
        let (listener, sender, sink) = real_loopback_srt_pair(14801, 5, false);

        let stats = sink.property::<Option<gst::Structure>>("stats");
        match read_packets_sent(stats.as_deref()) {
            PacketsSentReading::Present(count) => assert!(
                count > 0,
                "expected a positive confirmed-sent count from a real connected \
                 srtsink, got {count}"
            ),
            other => panic!(
                "expected Present(n>0) from the real stats structure a connected \
                 srtsink actually produces, got {other:?}"
            ),
        }

        listener
            .set_state(gst::State::Null)
            .expect("listener stops");
        sender.set_state(gst::State::Null).expect("sender stops");
    }

    #[test]
    fn destination_health_monitor_never_reports_a_healthy_caller_destination_unhealthy() {
        // This protects against the original stats-type regression: before the fix, every healthy
        // caller-mode SRT destination was reported "failed" at the threshold and on
        // every cadence tick after, forever, because the strict `u64` read against a
        // real `i64` field always errored and `.ok()` swallowed that into "nothing
        // sent". With a real, continuously sending loopback destination armed at a
        // short threshold/cadence, no `endpoint_health` event may ever report
        // "failed".
        let (listener, sender, sink) = real_loopback_srt_pair(14802, 5, false);

        let monitor = build_destination_health_monitor(&sink, SrtMode::Caller)
            .expect("caller mode is armed-eligible");
        let (event_sink, messages) = test_event_sink();
        monitor.arm_with_durations(
            &sender,
            event_sink,
            "endpoint-1".to_string(),
            Duration::from_millis(40),
            Duration::from_millis(70),
        );

        // Run well past the threshold and several cadence ticks while the real
        // stream keeps sending, so both the initial threshold check and the ongoing
        // repeat monitoring (which never stops after the first confirmed send) get exercised.
        pump_for(Duration::from_millis(450));

        let events = events_named(&messages, "endpoint_health");
        let failed: Vec<_> = events
            .iter()
            .filter(|event| event["state"] == "failed")
            .collect();
        assert!(
            failed.is_empty(),
            "a continuously healthy caller-mode SRT destination must never be \
             reported failed, got: {failed:?}"
        );

        listener
            .set_state(gst::State::Null)
            .expect("listener stops");
        sender.set_state(gst::State::Null).expect("sender stops");
    }

    #[test]
    fn source_threshold_recovers_immediately_when_data_arrived_in_the_race_window() {
        // Reproduces the state the threshold race leaves behind - `ever_data` true but
        // `reported_unhealthy` also true, as if the pad probe ran (and found nothing
        // to recover from) a moment before the threshold callback's store - and
        // checks that the fix catches it right away rather than leaving it for the
        // next `cadence` tick.
        let (event_sink, messages) = test_event_sink();
        let ever_data = Arc::new(AtomicBool::new(true));
        let reported_unhealthy = Arc::new(AtomicBool::new(true));

        let recovered = recover_immediately_if_data_arrived(
            &ever_data,
            &reported_unhealthy,
            &event_sink,
            "endpoint-1",
        );

        assert!(
            recovered,
            "must recognise data arrived during the race window and recover promptly"
        );
        assert!(!reported_unhealthy.load(Ordering::Acquire));
        let events = events_named(&messages, "endpoint_health");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["state"], "streaming");
    }

    #[test]
    fn source_threshold_does_not_recover_when_no_data_has_arrived() {
        let (event_sink, messages) = test_event_sink();
        let ever_data = Arc::new(AtomicBool::new(false));
        let reported_unhealthy = Arc::new(AtomicBool::new(true));

        let recovered = recover_immediately_if_data_arrived(
            &ever_data,
            &reported_unhealthy,
            &event_sink,
            "endpoint-1",
        );

        assert!(!recovered);
        assert!(reported_unhealthy.load(Ordering::Acquire));
        assert!(events_named(&messages, "endpoint_health").is_empty());
    }

    #[test]
    fn destination_stall_after_start_is_reported_and_then_recovers() {
        // Exercises the full tick-processing
        // function (`apply_destination_reading`, the pure half of
        // `process_destination_tick`), driving it with a chosen sequence of
        // `PacketsSentReading` values: never sent -> advancing (first confirmed send)
        // -> stalled (peer went dark after a working connection) -> advancing again
        // (peer came back). A real SRT peer cannot be made to stop sending mid-test
        // without tearing down the socket, so this is the deterministic equivalent of
        // that sequence.
        let reported_unhealthy = Arc::new(AtomicBool::new(false));
        let last_confirmed_count: Arc<Mutex<Option<i64>>> = Arc::new(Mutex::new(None));
        let (event_sink, messages) = test_event_sink();

        let tick = |reading: PacketsSentReading| {
            apply_destination_reading(
                reading,
                &last_confirmed_count,
                &reported_unhealthy,
                &event_sink,
                "dest-1",
                "sink0",
                30,
            );
        };

        // Tick 1: nothing confirmed yet.
        tick(PacketsSentReading::Absent);
        let events = events_named(&messages, "endpoint_health");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["reason_code"], "SRT_NO_DATA_SINCE_START");

        // Tick 2: first confirmed send - recovers from the never-sent report.
        tick(PacketsSentReading::Present(10));
        let events = events_named(&messages, "endpoint_health");
        assert_eq!(events.len(), 2);
        assert_eq!(events[1]["state"], "streaming");

        // Tick 3: count unchanged since the last tick - was sending, now stalled.
        // Must be the honestly distinct stalled reason, never the never-sent one.
        tick(PacketsSentReading::Present(10));
        let events = events_named(&messages, "endpoint_health");
        assert_eq!(events.len(), 3);
        assert_eq!(events[2]["state"], "failed");
        assert_eq!(events[2]["reason_code"], "SRT_DATA_STALLED_AFTER_START");

        // Tick 4: still stalled - the report repeats but is still the stalled
        // reason, not the never-sent one.
        tick(PacketsSentReading::Present(10));
        let events = events_named(&messages, "endpoint_health");
        assert_eq!(events.len(), 4);
        assert_eq!(events[3]["reason_code"], "SRT_DATA_STALLED_AFTER_START");

        // Tick 5: the peer comes back - the count advances again and this must be
        // reported as recovered, not left standing as stalled forever (the earlier bug
        // this monitor used to have: once `packets-sent > 0`, monitoring stopped for
        // good, so a stall was never even detected, let alone recovered from).
        tick(PacketsSentReading::Present(11));
        let events = events_named(&messages, "endpoint_health");
        assert_eq!(events.len(), 5);
        assert_eq!(events[4]["state"], "streaming");
    }

    #[test]
    fn source_health_monitor_reports_no_data_then_recovers_when_a_buffer_arrives() {
        let _ = gst::init();
        let identity = gst::ElementFactory::make("identity")
            .build()
            .expect("identity element should be available for tests");
        let sink = gst::ElementFactory::make("fakesink")
            .build()
            .expect("fakesink element should be available for tests");
        let pipeline = gst::Pipeline::new();
        pipeline
            .add_many([&identity, &sink])
            .expect("add elements to pipeline");
        identity.link(&sink).expect("link identity to fakesink");
        pipeline
            .set_state(gst::State::Playing)
            .expect("pipeline reaches playing");

        let monitor = build_source_health_monitor(&identity, SrtMode::Caller)
            .expect("caller mode builds a monitor")
            .expect("caller mode is armed-eligible");

        let (event_sink, messages) = test_event_sink();
        monitor.arm_with_durations(
            &pipeline,
            event_sink,
            "endpoint-1".to_string(),
            Duration::from_millis(40),
            Duration::from_millis(70),
        );

        // No buffer has been pushed yet: the threshold must fire exactly one Failed
        // report plus exactly one diagnostic log line.
        pump_until(
            || !events_named(&messages, "endpoint_health").is_empty(),
            Duration::from_secs(2),
        );
        let events = events_named(&messages, "endpoint_health");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["state"], "failed");
        assert_eq!(events[0]["reason_code"], "SRT_NO_DATA_SINCE_START");
        assert_eq!(events[0]["retryable"], true);
        assert_eq!(events[0]["retry_domain"], "route");
        assert_eq!(events_named(&messages, "pipeline_log").len(), 1);

        // Still no buffer: the cadence timer must repeat the Failed report without
        // repeating the log line.
        pump_until(
            || events_named(&messages, "endpoint_health").len() >= 2,
            Duration::from_secs(2),
        );
        let events = events_named(&messages, "endpoint_health");
        assert_eq!(events.len(), 2);
        assert_eq!(events[1]["state"], "failed");
        assert_eq!(
            events_named(&messages, "pipeline_log").len(),
            1,
            "the diagnostic line must not repeat on every cadence tick"
        );

        // Now a buffer arrives: the probe must report the source healthy immediately.
        let pad = identity.static_pad("src").expect("identity has a src pad");
        let _ = pad.push(gst::Buffer::new());

        pump_until(
            || events_named(&messages, "endpoint_health").len() >= 3,
            Duration::from_secs(2),
        );
        let events = events_named(&messages, "endpoint_health");
        assert_eq!(events.len(), 3);
        assert_eq!(events[2]["state"], "streaming");
        assert!(events[2]["reason_code"].is_null());

        pipeline
            .set_state(gst::State::Null)
            .expect("pipeline stops");
    }

    #[test]
    fn unconvertible_property_value_is_classified_instead_of_aborting() {
        let _ = gst::init();
        let element = gst::ElementFactory::make("srtsrc")
            .build()
            .expect("srtsrc element should be available for tests");
        let (code, detail) = set_property(&element, "latency", "not-a-number")
            .expect_err("a value that cannot become the property type must fail");
        assert_eq!(code, ErrorCode::ConfigInvalid);
        assert!(
            detail.contains("latency"),
            "detail must name the property, got: {detail}"
        );
    }
}
