use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::Result;
use gstreamer::prelude::*;
use hydra_plan::{
    Cidr, DestinationEndpoint, HlsEndAction, HlsSource, HlsUri, HostAddress, InterfaceName,
    LegacyKind, Port, ProgramNumber, RouteConfig, RtmpEndpoint, RtmpUri, SourceEndpoint, SrtAccess,
    SrtDestination, SrtMode, SrtSource, SrtUri, UdpEndpoint,
};

use super::*;
use crate::events::EndpointDirection;
use crate::lifecycle::{PipelineLifecycleEmitter, PipelineStatus};
use crate::output::{StatsWriter, StdoutWriter};
use gstreamer as gst;
use hydra_plan::ErrorCode;

fn writer() -> Arc<Mutex<Box<dyn StatsWriter>>> {
    Arc::new(Mutex::new(Box::new(StdoutWriter::new())))
}

fn event_sink() -> crate::events::EventSink {
    crate::events::EventSink::new(
        writer(),
        crate::events::RouteIdentity {
            route_id: "route-1".to_string(),
            config_revision: "rev-1".to_string(),
            process_instance_id: "proc-1".to_string(),
        },
    )
}

fn srt_source(id: &str, name: &str, srt: SrtSource) -> SourceEndpoint {
    SourceEndpoint::Srt {
        id: id.to_string(),
        name: name.to_string(),
        srt,
    }
}
fn udp_source(id: &str, name: &str, udp: UdpEndpoint) -> SourceEndpoint {
    SourceEndpoint::Udp {
        id: id.to_string(),
        name: name.to_string(),
        udp,
    }
}
fn rtp_source(id: &str, name: &str, udp: UdpEndpoint) -> SourceEndpoint {
    SourceEndpoint::Rtp {
        id: id.to_string(),
        name: name.to_string(),
        rtp: udp,
    }
}
fn rtmp_source(id: &str, name: &str, rtmp: RtmpEndpoint) -> SourceEndpoint {
    SourceEndpoint::Rtmp {
        id: id.to_string(),
        name: name.to_string(),
        rtmp,
    }
}
fn hls_source(id: &str, name: &str, live: bool) -> SourceEndpoint {
    SourceEndpoint::Hls {
        id: id.to_string(),
        name: name.to_string(),
        hls: HlsSource::new(
            HlsUri::new("http://127.0.0.1:4567/playlist.m3u8").unwrap(),
            live,
            Some(hydra_plan::HlsTargetDurationMs::new(5_000).unwrap()),
            HlsEndAction::Stop,
        ),
    }
}
fn srt_dest(id: &str, name: &str, srt: SrtDestination) -> DestinationEndpoint {
    DestinationEndpoint::Srt {
        id: id.to_string(),
        name: name.to_string(),
        srt,
    }
}
fn udp_dest(id: &str, name: &str, udp: UdpEndpoint) -> DestinationEndpoint {
    DestinationEndpoint::Udp {
        id: id.to_string(),
        name: name.to_string(),
        udp,
    }
}
fn rtmp_dest(id: &str, name: &str, rtmp: RtmpEndpoint) -> DestinationEndpoint {
    DestinationEndpoint::Rtmp {
        id: id.to_string(),
        name: name.to_string(),
        rtmp,
    }
}

fn plan_route(
    source: SourceEndpoint,
    destinations: Vec<DestinationEndpoint>,
) -> hydra_plan::GraphPlan {
    hydra_plan::plan(&RouteConfig {
        route_id: "route-test".to_string(),
        config_revision: "revision-test".to_string(),
        process_instance_id: "process-test".to_string(),
        source,
        destinations,
    })
    .expect("valid typed config must plan")
}

fn minimal_srt_source(uri: &str, mode: SrtMode) -> SrtSource {
    SrtSource::new(
        SrtUri::new(uri).unwrap(),
        mode,
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
        None,
        None,
    )
}
fn minimal_srt_dest(uri: &str, mode: SrtMode) -> SrtDestination {
    SrtDestination::new(
        SrtUri::new(uri).unwrap(),
        mode,
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
    )
}
fn udp_ep(address: &str, port: u64) -> UdpEndpoint {
    UdpEndpoint::new(
        HostAddress::new(address).unwrap(),
        Port::new(port).unwrap(),
        None,
        None,
        None,
        None,
    )
}

fn selected_udp_ep(address: &str, port: u64) -> UdpEndpoint {
    UdpEndpoint::new(
        HostAddress::new(address).unwrap(),
        Port::new(port).unwrap(),
        None,
        None,
        None,
        Some(ProgramNumber::new(12).unwrap()),
    )
}

fn selected_srt_source() -> SrtSource {
    SrtSource::new(
        SrtUri::new("srt://127.0.0.1:4201?mode=listener").unwrap(),
        SrtMode::Listener,
        None,
        None,
        None,
        None,
        None,
        None,
        None,
        Some(HostAddress::new("127.0.0.1").unwrap()),
        Some(Port::new(4201).unwrap()),
        None,
        None,
        Some(ProgramNumber::new(12).unwrap()),
    )
}
fn rtmp_ep(location: &str) -> RtmpEndpoint {
    RtmpEndpoint::new(RtmpUri::new(location).unwrap())
}

fn hls_plan(live: bool) -> hydra_plan::GraphPlan {
    plan_route(
        hls_source("source-hls", "HLS source", live),
        vec![udp_dest("dest", "Dest", udp_ep("127.0.0.1", 4402))],
    )
}

fn multi_udp_plan() -> hydra_plan::GraphPlan {
    plan_route(
        udp_source("source-a", "Source", udp_ep("127.0.0.1", 4401)),
        vec![
            udp_dest("dest-a", "A", udp_ep("127.0.0.1", 4402)),
            udp_dest("dest-b", "B", udp_ep("127.0.0.1", 4403)),
        ],
    )
}

fn factory_counts(pipeline: &gst::Pipeline) -> HashMap<String, usize> {
    let mut counts = HashMap::new();
    for element in pipeline
        .iterate_recurse()
        .into_iter()
        .filter_map(Result::ok)
    {
        if let Some(factory) = element.factory() {
            if factory.name() != "bin" {
                *counts.entry(factory.name().to_string()).or_insert(0) += 1;
            }
        }
    }
    counts
}

fn tee_request_pad_count(tee: &gst::Element) -> usize {
    tee.src_pads().len()
}

fn listener_srt_source() -> SrtSource {
    SrtSource::new(
        SrtUri::new("srt://127.0.0.1:4201?mode=listener").unwrap(),
        SrtMode::Listener,
        None,
        None,
        None,
        None,
        None,
        None,
        None,
        Some(HostAddress::new("127.0.0.1").unwrap()),
        Some(Port::new(4201).unwrap()),
        None,
        None,
        None,
    )
}

fn srtsrc_plan(source: SrtSource) -> hydra_plan::GraphPlan {
    plan_route(
        srt_source("source-a", "Source", source),
        vec![srt_dest(
            "dest",
            "Dest",
            minimal_srt_dest("srt://127.0.0.1:4202?mode=caller", SrtMode::Caller),
        )],
    )
}

#[test]
fn legacy_route_builds_multi_branch_tee_and_reaches_playing() {
    let _ = gst::init();
    let running = build(multi_udp_plan(), writer())
        .expect("current built")
        .link()
        .expect("current linked")
        .start(event_sink())
        .expect("current playing");
    let (_, state, _) = running
        .runtime()
        .pipeline
        .state(gst::ClockTime::from_seconds(2));
    assert_eq!(state, gst::State::Playing);
    assert_eq!(
        factory_counts(&running.runtime().pipeline),
        HashMap::from([
            ("udpsrc".to_string(), 1),
            ("tee".to_string(), 1),
            ("queue".to_string(), 2),
            ("udpsink".to_string(), 2),
        ])
    );
    running.shutdown().expect("current shutdown");
}

#[test]
fn legacy_multi_branch_route_retains_one_metric_per_destination() {
    let _ = gst::init();
    let built = build(multi_udp_plan(), writer()).expect("current multi-branch route builds");
    assert_eq!(
        built
            .core
            .runtime
            .dest_metrics
            .lock()
            .expect("metrics lock")
            .len(),
        2
    );
}

#[test]
fn colliding_sanitized_endpoint_ids_get_distinct_indexed_bins() {
    let _ = gst::init();
    let mut plan = multi_udp_plan();
    plan.branches[0].endpoint_id = "a-b".to_string();
    plan.branches[1].endpoint_id = "a_b".to_string();

    let built = build(plan, writer()).expect("colliding endpoint ids build");
    assert_eq!(built.branches[0].bin.name(), "dest_0_a_b");
    assert_eq!(built.branches[1].bin.name(), "dest_1_a_b");
    assert_eq!(
        built
            .core
            .endpoints
            .iter()
            .filter(|endpoint| endpoint.direction == EndpointDirection::Destination)
            .map(|endpoint| (endpoint.bin_name.as_str(), endpoint.endpoint_id.as_str()))
            .collect::<Vec<_>>(),
        [("dest_0_a_b", "a-b"), ("dest_1_a_b", "a_b")]
    );
}

#[test]
fn legacy_route_tracks_mixed_sink_metrics() {
    let _ = gst::init();
    let plan = plan_route(
        udp_source("source-a", "Source", udp_ep("127.0.0.1", 4401)),
        vec![
            udp_dest("udp-dest", "UDP Dest", udp_ep("127.0.0.1", 4100)),
            srt_dest(
                "srt-dest",
                "SRT Dest",
                SrtDestination::new(
                    SrtUri::new("srt://127.0.0.1:4200?mode=caller").unwrap(),
                    SrtMode::Caller,
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                    Some(HostAddress::new("127.0.0.1").unwrap()),
                    Some(Port::new(4200).unwrap()),
                    None,
                ),
            ),
        ],
    );
    let built = build(plan, writer()).expect("current mixed sinks build");
    let metrics = built
        .core
        .runtime
        .dest_metrics
        .lock()
        .expect("metrics lock");
    assert_eq!(metrics.len(), 2);
    assert_eq!(metrics[0].kind, "udpsink");
    assert_eq!(metrics[1].kind, "srtsink");
}

#[test]
fn legacy_rtmp_source_builds_mpegts_remux_path() {
    let _ = gst::init();
    let built = build(
        plan_route(
            rtmp_source("source-a", "Source", rtmp_ep("rtmp://127.0.0.1/live")),
            vec![srt_dest(
                "dest",
                "Dest",
                minimal_srt_dest("srt://127.0.0.1:4202?mode=caller", SrtMode::Caller),
            )],
        ),
        writer(),
    )
    .expect("current RTMP source builds");
    let counts = factory_counts(&built.core.runtime.pipeline);
    assert_eq!(counts.get("parsebin"), Some(&1));
    assert_eq!(counts.get("mpegtsmux"), Some(&1));
}

#[test]
fn hls_source_builds_static_ghost_and_time_bounded_pacer_inputs() {
    let _ = gst::init();
    for factory in ["urisourcebin", "parsebin", "mpegtsmux", "identity", "queue"] {
        if gst::ElementFactory::find(factory).is_none() {
            eprintln!("skipped: HLS factory absent: {factory}");
            return;
        }
    }
    let built = build(hls_plan(true), writer()).expect("HLS source builds");
    let source_bin = built
        .core
        .runtime
        .pipeline
        .by_name("source_source_hls")
        .expect("HLS source bin")
        .downcast::<gst::Bin>()
        .expect("HLS source bin type");
    assert!(source_bin.static_pad("src").is_some());
    assert_eq!(
        source_bin
            .by_name("hls_mpegtsmux")
            .expect("HLS mux")
            .static_pad("src")
            .expect("HLS mux src")
            .name(),
        "src"
    );
    assert_eq!(
        built.core.endpoints[0].transport,
        crate::events::Transport::Hls
    );
    assert_eq!(
        built.core.runtime.source.property::<String>("uri"),
        "http://127.0.0.1:4567/playlist.m3u8"
    );
}

#[test]
fn hls_dynamic_parsed_pad_links_through_the_pacer() {
    let _ = gst::init();
    for factory in ["appsrc", "mpegtsmux", "identity", "queue", "h264parse"] {
        if gst::ElementFactory::find(factory).is_none() {
            eprintln!("skipped: HLS dynamic-link factory absent: {factory}");
            return;
        }
    }
    let bin = gst::Bin::with_name("hls_dynamic_test");
    let mux = gst::ElementFactory::make("mpegtsmux")
        .name("hls_test_mux")
        .build()
        .expect("HLS mux");
    let appsrc = gst::ElementFactory::make("appsrc")
        .name("hls_test_input")
        .build()
        .expect("HLS input");
    let caps = gst::Caps::builder("video/x-h264")
        .field("stream-format", "byte-stream")
        .field("alignment", "au")
        .build();
    appsrc.set_property("caps", caps);
    bin.add_many([&appsrc, &mux]).expect("HLS test elements");
    let source_pad = appsrc.static_pad("src").expect("HLS input src");

    crate::adapters::hls::link_parsed_pad(&bin, &mux, &source_pad, 2_000, "hls_parsebin")
        .expect("HLS dynamic link");

    assert!(source_pad.is_linked());
    let pacer = bin.by_name("hls_pacer_hls_parsebin_src");
    assert!(pacer.expect("HLS pacer").property::<bool>("sync"));
    assert_eq!(
        bin.by_name("hls_queue_hls_parsebin_src")
            .expect("HLS pacing queue")
            .property::<u64>("max-size-time"),
        2_000_000_000
    );
}

#[test]
fn legacy_route_builds_multiple_rtmp_sink_remux_paths() {
    let _ = gst::init();
    let built = build(
        plan_route(
            udp_source("source-a", "Source", udp_ep("127.0.0.1", 4401)),
            vec![
                rtmp_dest("one", "One", rtmp_ep("rtmp://127.0.0.1/one")),
                rtmp_dest("two", "Two", rtmp_ep("rtmp://127.0.0.1/two")),
            ],
        ),
        writer(),
    )
    .expect("current RTMP destinations build");
    let counts = factory_counts(&built.core.runtime.pipeline);
    assert_eq!(counts.get("parsebin"), Some(&2));
    assert_eq!(counts.get("flvmux"), Some(&2));
}

#[test]
fn legacy_rtp_source_without_program_keeps_depay_path() {
    let _ = gst::init();
    let built = build(
        plan_route(
            rtp_source("source-a", "Source", udp_ep("127.0.0.1", 4401)),
            vec![udp_dest("dest", "Dest", udp_ep("127.0.0.1", 4402))],
        ),
        writer(),
    )
    .expect("current RTP source builds");
    let counts = factory_counts(&built.core.runtime.pipeline);
    assert_eq!(counts.get("udpsrc"), Some(&1));
    assert_eq!(counts.get("rtpmp2tdepay"), Some(&1));
    assert_eq!(counts.get("tsparse"), None);
}

#[test]
fn legacy_route_applies_udp_multicast_source_properties() {
    let _ = gst::init();
    let built = build(
        plan_route(
            udp_source(
                "source-a",
                "Source",
                UdpEndpoint::new(
                    HostAddress::new("239.1.1.1").unwrap(),
                    Port::new(4500).unwrap(),
                    Some(true),
                    Some(InterfaceName::new("lo").unwrap()),
                    None,
                    None,
                ),
            ),
            vec![srt_dest(
                "dest",
                "Dest",
                minimal_srt_dest("srt://127.0.0.1:4202?mode=caller", SrtMode::Caller),
            )],
        ),
        writer(),
    )
    .expect("current multicast route builds");
    assert_eq!(
        built.core.runtime.source.property::<String>("address"),
        "239.1.1.1"
    );
    assert!(built.core.runtime.source.property::<bool>("auto-multicast"));
    assert_eq!(
        built
            .core
            .runtime
            .source
            .property::<String>("multicast-iface"),
        "lo"
    );
}

#[test]
fn selected_program_source_builds_tsparse_for_udp_rtp_and_srt() {
    let _ = gst::init();
    let plans = [
        plan_route(
            udp_source("udp-source", "UDP", selected_udp_ep("127.0.0.1", 4501)),
            vec![udp_dest("dest", "Dest", udp_ep("127.0.0.1", 4502))],
        ),
        plan_route(
            rtp_source("rtp-source", "RTP", selected_udp_ep("127.0.0.1", 4503)),
            vec![udp_dest("dest", "Dest", udp_ep("127.0.0.1", 4504))],
        ),
        plan_route(
            srt_source("srt-source", "SRT", selected_srt_source()),
            vec![udp_dest("dest", "Dest", udp_ep("127.0.0.1", 4505))],
        ),
    ];

    for plan in plans {
        let built = build(plan, writer()).expect("selected-program source builds");
        let parser = built
            .core
            .runtime
            .pipeline
            .iterate_recurse()
            .into_iter()
            .filter_map(Result::ok)
            .find(|element| {
                element
                    .factory()
                    .is_some_and(|factory| factory.name() == "tsparse")
            })
            .expect("selected-program source contains tsparse");
        assert!(parser
            .src_pads()
            .iter()
            .any(|pad| pad.name() == "program_12"));
        assert_eq!(built.core.source_requested_pads.len(), 1);
        built
            .link()
            .expect("selected-program source links")
            .shutdown()
            .expect("selected-program source shuts down");
        assert!(!parser
            .src_pads()
            .iter()
            .any(|pad| pad.name() == "program_12"));
    }
}

#[test]
fn legacy_srtsrc_keeps_authentication_false_by_default() {
    let _ = gst::init();
    let built =
        build(srtsrc_plan(listener_srt_source()), writer()).expect("current SRT route builds");
    assert!(!built.core.runtime.source.property::<bool>("authentication"));
    assert_eq!(
        factory_counts(&built.core.runtime.pipeline).get("tsparse"),
        None
    );
}

#[test]
fn legacy_srtsrc_preserves_explicit_authentication() {
    let _ = gst::init();
    let source = SrtSource::new(
        SrtUri::new("srt://127.0.0.1:4201?mode=listener").unwrap(),
        SrtMode::Listener,
        None,
        None,
        None,
        None,
        None,
        None,
        None,
        Some(HostAddress::new("127.0.0.1").unwrap()),
        Some(Port::new(4201).unwrap()),
        Some(true),
        None,
        None,
    );
    let built = build(srtsrc_plan(source), writer()).expect("current SRT route builds");
    assert!(built.core.runtime.source.property::<bool>("authentication"));
}

fn caller_srt_source_plan(source: SrtSource) -> hydra_plan::GraphPlan {
    plan_route(
        srt_source("source-a", "Source", source),
        vec![udp_dest("dest", "Dest", udp_ep("127.0.0.1", 4401))],
    )
}

#[test]
fn srt_source_health_monitor_present_only_for_caller_and_rendezvous_modes() {
    let _ = gst::init();
    for (mode, uri) in [
        (SrtMode::Caller, "srt://127.0.0.1:4207?mode=caller"),
        (SrtMode::Rendezvous, "srt://127.0.0.1:4207?mode=rendezvous"),
    ] {
        let built = build(
            caller_srt_source_plan(minimal_srt_source(uri, mode)),
            writer(),
        )
        .unwrap_or_else(|error| panic!("{mode:?} SRT source builds: {error}"));
        let monitor = built
            .core
            .srt_source_health
            .clone()
            .unwrap_or_else(|| panic!("{mode:?} SRT source must carry a health monitor"));
        assert!(
            !monitor.armed(),
            "monitor must not be armed until the pipeline reaches Playing"
        );
    }

    let built = build(caller_srt_source_plan(listener_srt_source()), writer())
        .expect("listener SRT source builds");
    assert!(
        built.core.srt_source_health.is_none(),
        "listener mode waits for an inbound caller by design and must never carry a health monitor"
    );
}

#[test]
fn srt_source_health_monitor_arms_when_the_route_reaches_playing() {
    let _ = gst::init();
    let built = build(
        caller_srt_source_plan(minimal_srt_source(
            "srt://127.0.0.1:4209?mode=caller",
            SrtMode::Caller,
        )),
        writer(),
    )
    .expect("caller SRT source builds");
    let monitor = built
        .core
        .srt_source_health
        .clone()
        .expect("caller SRT source carries a health monitor");
    assert!(!monitor.armed());

    let running = built
        .link()
        .expect("SRT graph links")
        .start(event_sink())
        .expect(
            "SRT graph reaches Playing (caller connect happens async, off the state-change path)",
        );
    assert!(monitor.armed());
    running.shutdown().expect("SRT graph stops");
}

#[test]
fn legacy_srtsrc_enables_authentication_for_access_hooks() {
    let _ = gst::init();
    let source = SrtSource::new(
        SrtUri::new("srt://127.0.0.1:4201?mode=listener").unwrap(),
        SrtMode::Listener,
        None,
        None,
        None,
        None,
        None,
        None,
        None,
        Some(HostAddress::new("127.0.0.1").unwrap()),
        Some(Port::new(4201).unwrap()),
        None,
        Some(SrtAccess::new(
            true,
            vec![],
            vec![Cidr::new("127.0.0.1").unwrap()],
        )),
        None,
    );
    let built = build(srtsrc_plan(source), writer()).expect("current SRT access route builds");
    assert!(built.core.runtime.source.property::<bool>("authentication"));
}

#[derive(Debug)]
struct MemoryWriter(Arc<Mutex<Vec<String>>>);

impl StatsWriter for MemoryWriter {
    fn send_message(&mut self, message: &str) -> Result<()> {
        self.0
            .lock()
            .expect("messages lock")
            .push(message.to_string());
        Ok(())
    }
}

type LifecycleProbeState = (
    PipelineLifecycleEmitter,
    Arc<AtomicU64>,
    Arc<AtomicBool>,
    Arc<Mutex<Vec<String>>>,
);

fn lifecycle_probe_state() -> LifecycleProbeState {
    let messages = Arc::new(Mutex::new(Vec::new()));
    let writer: Arc<Mutex<Box<dyn StatsWriter>>> =
        Arc::new(Mutex::new(Box::new(MemoryWriter(messages.clone()))));
    (
        PipelineLifecycleEmitter::new(writer),
        Arc::new(AtomicU64::new(0)),
        Arc::new(AtomicBool::new(true)),
        messages,
    )
}

#[test]
fn legacy_source_buffer_hook_emits_processing_once_after_starting() {
    let (lifecycle, bytes, pending, messages) = lifecycle_probe_state();
    lifecycle.emit_starting().expect("starting");
    record_source_buffer(&bytes, &pending, &lifecycle, 188);
    record_source_buffer(&bytes, &pending, &lifecycle, 188);
    assert_eq!(bytes.load(Ordering::Relaxed), 376);
    assert_eq!(
        lifecycle.current_status().expect("status"),
        Some(PipelineStatus::Processing)
    );
    assert_eq!(
        messages.lock().expect("messages").as_slice(),
        [
            r#"{"event":"pipeline_status","status":"starting"}"#,
            r#"{"event":"pipeline_status","status":"processing"}"#
        ]
    );
}

#[test]
fn legacy_source_buffer_hook_can_promote_before_starting() {
    let (lifecycle, bytes, pending, messages) = lifecycle_probe_state();
    record_source_buffer(&bytes, &pending, &lifecycle, 188);
    record_source_buffer(&bytes, &pending, &lifecycle, 188);
    assert_eq!(bytes.load(Ordering::Relaxed), 376);
    assert_eq!(
        lifecycle.current_status().expect("status"),
        Some(PipelineStatus::Processing)
    );
    assert_eq!(
        messages.lock().expect("messages").as_slice(),
        [r#"{"event":"pipeline_status","status":"processing"}"#]
    );
}

#[test]
fn legacy_source_buffer_hook_rearms_after_reconnecting() {
    let (lifecycle, bytes, pending, messages) = lifecycle_probe_state();
    lifecycle.emit_starting().expect("starting");
    record_source_buffer(&bytes, &pending, &lifecycle, 188);
    lifecycle.emit_reconnecting().expect("reconnecting");
    pending.store(true, Ordering::Release);
    record_source_buffer(&bytes, &pending, &lifecycle, 188);
    assert_eq!(bytes.load(Ordering::Relaxed), 376);
    assert_eq!(
        messages.lock().expect("messages").as_slice(),
        [
            r#"{"event":"pipeline_status","status":"starting"}"#,
            r#"{"event":"pipeline_status","status":"processing"}"#,
            r#"{"event":"pipeline_status","status":"reconnecting"}"#,
            r#"{"event":"pipeline_status","status":"processing"}"#
        ]
    );
}

#[test]
fn shutdown_releases_all_tee_request_pads_on_clean_stop_and_link_error() {
    let _ = gst::init();
    let running = build(multi_udp_plan(), writer())
        .expect("built")
        .link()
        .expect("linked")
        .start(event_sink())
        .expect("running");
    let tee = running
        .runtime()
        .pipeline
        .by_name("tee")
        .expect("program tee");
    assert_eq!(tee_request_pad_count(&tee), 2);
    running.shutdown().expect("shutdown");
    assert_eq!(tee_request_pad_count(&tee), 0);

    let built = build(multi_udp_plan(), writer()).expect("built for failure");
    let tee = built
        .core
        .runtime
        .pipeline
        .by_name("tee")
        .expect("program tee");
    let error = built
        .link_impl(Some(1))
        .err()
        .expect("injected failure expected");
    assert_eq!(error.code(), ErrorCode::LinkFailed);
    assert_eq!(tee_request_pad_count(&tee), 0);
}

#[test]
fn aggregate_error_lists_every_failing_destination_endpoint() {
    let error = BuildError::aggregate(vec![
        (
            "dest-a".to_string(),
            BuildError::new(ErrorCode::ElementMissing, "dest-a failed"),
        ),
        (
            "dest-b".to_string(),
            BuildError::new(ErrorCode::ElementMissing, "dest-b failed"),
        ),
    ]);
    assert_eq!(error.endpoint_ids(), &["dest-a", "dest-b"]);
    assert!(error.detail().contains("dest-a"));
    assert!(error.detail().contains("dest-b"));
    assert!(error.detail().contains("dest-a failed"));
    assert!(error.detail().contains("dest-b failed"));
}

#[test]
fn rtmp_destination_records_both_mux_request_pads() {
    let _ = gst::init();
    let plan = plan_route(
        udp_source("source-a", "Source", udp_ep("127.0.0.1", 4401)),
        vec![rtmp_dest("dest-a", "A", rtmp_ep("rtmp://127.0.0.1/live"))],
    );

    let built = build(plan, writer()).expect("RTMP destination builds");
    assert_eq!(built.branches[0].requested_pads.len(), 2);
    let linked = built.link().expect("RTMP destination links");
    assert_eq!(linked.branch_handles[0].1.requested_pads.len(), 2);
    let tee = linked
        .core
        .runtime
        .pipeline
        .by_name("tee")
        .expect("program tee");
    release_handles(&linked.branch_handles);
    assert!(tee.src_pads().is_empty());
}

#[test]
fn ndi_av_teardown_releases_both_tees_and_combiner_audio_pad() {
    let _ = gst::init();
    if gst::ElementFactory::find("ndisrc").is_none() {
        eprintln!("skipped: ndi plugin absent");
        return;
    }
    let config = hydra_plan::parse(include_str!(
        "../../hydra-plan/tests/fixtures/valid_ndi_av.json"
    ))
    .expect("NDI config");
    let graph_plan = hydra_plan::plan(&config).expect("NDI graph plan");
    let built = build(graph_plan, writer()).expect("NDI graph builds");
    let video_tee = built
        .core
        .runtime
        .pipeline
        .by_name("video_tee")
        .expect("video tee");
    let audio_tee = built
        .core
        .runtime
        .pipeline
        .by_name("audio_tee")
        .expect("audio tee");
    let combiner = built
        .core
        .runtime
        .pipeline
        .iterate_recurse()
        .into_iter()
        .filter_map(Result::ok)
        .find(|element| {
            element
                .factory()
                .is_some_and(|factory| factory.name() == "ndisinkcombiner")
        })
        .expect("NDI sink combiner");
    assert_eq!(combiner.sink_pads().len(), 2);

    let linked = built.link().expect("NDI graph links");
    assert_eq!(video_tee.src_pads().len(), 1);
    assert_eq!(audio_tee.src_pads().len(), 1);
    release_handles(&linked.branch_handles);

    assert!(video_tee.src_pads().is_empty());
    assert!(audio_tee.src_pads().is_empty());
    assert_eq!(combiner.sink_pads().len(), 1);
}

#[test]
fn ndi_start_reports_runtime_missing_before_the_discovery_watchdog_can_arm() {
    let _ = gst::init();
    if gst::ElementFactory::find("ndisrc").is_none() {
        eprintln!("skipped: ndi plugin absent");
        return;
    }
    let config = hydra_plan::parse(include_str!(
        "../../hydra-plan/tests/fixtures/valid_ndi_av.json"
    ))
    .expect("NDI config");
    let graph_plan = hydra_plan::plan(&config).expect("NDI graph plan");
    let built = build(graph_plan, writer()).expect("NDI graph builds");
    let readiness = built
        .core
        .ndi_readiness
        .clone()
        .expect("NDI graph carries a readiness monitor");
    let linked = built.link().expect("NDI graph links");

    match linked.start(event_sink()) {
        // No NDI runtime on this host: ndisrc and ndisink both fail NULL→READY,
        // which fails the whole state change synchronously. The root cause is
        // reported and the derived "required track missing" deadline never runs,
        // so it cannot mask it.
        Err(error) => {
            assert_eq!(error.code(), ErrorCode::NdiRuntimeMissing);
            assert!(!readiness.armed());
        }
        // Runtime present: the graph runs, and the deadline is the backstop that
        // fails the route closed when the source never delivers its tracks.
        Ok(running) => {
            assert!(readiness.armed());
            running.shutdown().expect("NDI graph stops");
        }
    }
}

#[test]
fn derivation_table_maps_kind_direction_to_element_factory() {
    let _ = gst::init();

    let source_cases = [
        (
            srt_source(
                "source",
                "Source",
                minimal_srt_source("srt://127.0.0.1:4201?mode=listener", SrtMode::Listener),
            ),
            "srtsrc",
        ),
        (
            udp_source("source", "Source", udp_ep("127.0.0.1", 4401)),
            "udpsrc",
        ),
        (
            rtp_source("source", "Source", udp_ep("127.0.0.1", 4401)),
            "udpsrc",
        ),
        (
            rtmp_source("source", "Source", rtmp_ep("rtmp://127.0.0.1/live")),
            "rtmpsrc",
        ),
    ];
    for (source, expected_factory) in source_cases {
        let built = build(
            plan_route(
                source,
                vec![udp_dest("dest", "Dest", udp_ep("127.0.0.1", 4402))],
            ),
            writer(),
        )
        .unwrap_or_else(|error| panic!("{expected_factory} source builds: {error}"));
        assert_eq!(
            factory_counts(&built.core.runtime.pipeline).get(expected_factory),
            Some(&1),
            "expected source factory {expected_factory}"
        );
    }

    let destination_cases = [
        (
            srt_dest(
                "dest",
                "Dest",
                minimal_srt_dest("srt://127.0.0.1:4202?mode=caller", SrtMode::Caller),
            ),
            "srtsink",
        ),
        (
            udp_dest("dest", "Dest", udp_ep("127.0.0.1", 4402)),
            "udpsink",
        ),
        (
            rtmp_dest("dest", "Dest", rtmp_ep("rtmp://127.0.0.1/live")),
            "rtmpsink",
        ),
    ];
    for (destination, expected_factory) in destination_cases {
        let built = build(
            plan_route(
                udp_source("source", "Source", udp_ep("127.0.0.1", 4401)),
                vec![destination],
            ),
            writer(),
        )
        .unwrap_or_else(|error| panic!("{expected_factory} destination builds: {error}"));
        assert_eq!(
            factory_counts(&built.core.runtime.pipeline).get(expected_factory),
            Some(&1),
            "expected destination factory {expected_factory}"
        );
    }

    assert_eq!(source_element_factory(LegacyKind::Rtp), "udpsrc");
    assert_eq!(destination_element_factory(LegacyKind::Rtp), "udpsink");
}
