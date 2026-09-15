mod cli;

use std::io::{self, BufRead};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Context, Result};
use gstreamer as gst;
use hydra_plan::plan;
use serde_json::json;
use std::fmt;

use crate::cli::{parse_args, ProcessKind};
use hydra_media::build::{build, RunningGraph};
use hydra_media::crash::{emit_fatal, hydra_test_crash_if_requested, install_panic_hook};
use hydra_media::events::{EventSink, RetryDomain, RouteIdentity};
use hydra_media::health::attach_bus_watch;
use hydra_media::lifecycle::{PipelineStatus, StopReason};
use hydra_media::output::{DiscardWriter, SharedStdout, StatsWriter, StdoutWriter};
use hydra_media::stats::start_stats_loop;

fn main() {
    let writer = writer();
    install_panic_hook(writer.clone());

    let result = catch_unwind(AssertUnwindSafe(|| run(writer.clone())));
    match result {
        Ok(Ok(())) => {}
        Ok(Err(err)) if err.downcast_ref::<RouteFailureReported>().is_some() => {
            eprintln!("native route failure")
        }
        Ok(Err(err)) => {
            emit_fatal(&err, &writer);
            eprintln!("{}", hydra_media::crash::scrub_text(&err.to_string(), 512));
            std::process::exit(1);
        }
        Err(_) => std::process::exit(101),
    }
}

fn run(writer: SharedStdout) -> Result<()> {
    std::env::set_var("GST_REGISTRY_FORK", "no");
    let process_kind = match parse_args(std::env::args().skip(1)) {
        Ok(kind) => kind,
        Err(err) => {
            println!("{}", err.json_line());
            std::process::exit(2);
        }
    };
    match &process_kind {
        ProcessKind::NdiDiscovery { helper_instance_id } => {
            gst::init().context("failed to initialize gstreamer")?;
            hydra_media::ndi_discovery::run(writer, helper_instance_id)
        }
        ProcessKind::NdiProbe { probe_instance_id } => {
            gst::init().context("failed to initialize gstreamer")?;
            let mut line = String::new();
            io::stdin()
                .lock()
                .read_line(&mut line)
                .context("failed to read NDI probe json from stdin")?;
            let output = writer;
            let mut output = output
                .lock()
                .map_err(|_| anyhow!("writer mutex poisoned"))?;
            hydra_media::ndi_probe::run(&line, output.as_mut(), probe_instance_id)
        }
        ProcessKind::ValidateConfig => {
            gst::init().context("failed to initialize gstreamer")?;
            let mut line = String::new();
            io::stdin()
                .lock()
                .read_line(&mut line)
                .context("failed to read route json from stdin")?;
            validate_config(&line)
        }
        ProcessKind::Route { route_id, .. } => run_route_process(route_id, &process_kind, writer),
    }
}

/// Parses, plans and builds a route config without starting it, so the config
/// contract can be exercised without media, sockets or a live peer.
fn validate_config(line: &str) -> Result<()> {
    let outcome = build_for_validation(line);
    match outcome {
        Ok(()) => {
            println!("{}", json!({"event": "config_valid"}));
            Ok(())
        }
        Err((code, detail)) => {
            println!(
                "{}",
                json!({"event": "config_rejected", "reason_code": code, "detail": detail})
            );
            Err(anyhow!("{code}: {detail}"))
        }
    }
}

fn build_for_validation(line: &str) -> Result<(), (hydra_plan::ErrorCode, String)> {
    let config =
        hydra_plan::parse(line).map_err(|error| (error.code(), error.context().to_owned()))?;
    let graph_plan = plan(&config).map_err(|error| (error.code(), error.context().to_owned()))?;
    let writer: Arc<Mutex<Box<dyn StatsWriter>>> =
        Arc::new(Mutex::new(Box::new(DiscardWriter) as Box<dyn StatsWriter>));
    let built = build(graph_plan, writer).map_err(build_failure)?;
    let linked = built.link().map_err(build_failure)?;
    linked.shutdown().map_err(build_failure)
}

fn build_failure(error: hydra_media::build::BuildError) -> (hydra_plan::ErrorCode, String) {
    (error.code(), error.detail().to_owned())
}

fn run_route_process(
    route_id: &str,
    process_kind: &ProcessKind,
    writer: SharedStdout,
) -> Result<()> {
    if let ProcessKind::Route {
        process_instance_id,
        ..
    } = process_kind
    {
        hydra_media::crash::set_current_context(hydra_media::crash::CrashContext::for_process(
            route_id,
            process_instance_id,
        ));
        hydra_test_crash_if_requested();
    }
    let event_sink = EventSink::new(writer.clone(), route_identity(route_id, process_kind));
    emit_route_id(&writer, route_id)?;
    let result = if let Err(error) = gst::init().context("failed to initialize gstreamer") {
        let _ = event_sink.emit_route_terminal(
            hydra_plan::ErrorCode::RuntimeError,
            false,
            RetryDomain::None,
            Some(&error.to_string()),
        );
        Err(error)
    } else {
        let stdin = io::stdin();
        let mut line = String::new();
        if let Err(error) = stdin
            .lock()
            .read_line(&mut line)
            .context("failed to read pipeline json from stdin")
        {
            let _ = event_sink.emit_route_terminal(
                hydra_plan::ErrorCode::ConfigInvalid,
                false,
                RetryDomain::None,
                Some(&error.to_string()),
            );
            Err(error)
        } else {
            run_route(&line, writer, event_sink.clone())
        }
    };

    match result {
        Err(_error) if event_sink.route_terminal_emitted() => Err(RouteFailureReported.into()),
        result => result,
    }
}

#[derive(Debug)]
struct RouteFailureReported;

impl fmt::Display for RouteFailureReported {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("native route failure already reported")
    }
}

impl std::error::Error for RouteFailureReported {}

fn writer() -> SharedStdout {
    Arc::new(Mutex::new(Box::new(StdoutWriter::new())))
}

fn emit_route_id(writer: &Arc<Mutex<Box<dyn StatsWriter>>>, route_id: &str) -> Result<()> {
    writer
        .lock()
        .map_err(|_| anyhow!("writer mutex poisoned"))?
        .send_message(&format!("route_id:{route_id}"))
}

fn run_route(
    line: &str,
    writer: Arc<Mutex<Box<dyn StatsWriter>>>,
    event_sink: EventSink,
) -> Result<()> {
    let config = match hydra_plan::parse(line) {
        Ok(config) => config,
        Err(error) => return plan_failure(&event_sink, error),
    };
    hydra_media::crash::set_current_context(hydra_media::crash::CrashContext::from_route_config(
        &config,
    ));
    let event_sink = event_sink.with_identity(RouteIdentity {
        route_id: config.route_id.clone(),
        config_revision: config.config_revision.clone(),
        process_instance_id: config.process_instance_id.clone(),
    });
    let graph_plan = match plan(&config) {
        Ok(plan) => plan,
        Err(error) => return plan_failure(&event_sink, error),
    };

    let built = match build(graph_plan, writer.clone()) {
        Ok(graph) => graph,
        Err(error) => {
            let _ = event_sink.emit_route_terminal(
                error.code(),
                false,
                RetryDomain::None,
                Some(error.detail()),
            );
            return Err(error.into());
        }
    };
    let linked = match built.link() {
        Ok(graph) => graph,
        Err(error) => {
            let _ = event_sink.emit_route_terminal(
                error.code(),
                false,
                RetryDomain::None,
                Some(error.detail()),
            );
            return Err(error.into());
        }
    };
    let eos_seen = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let bus_watch = match attach_bus_watch(
        linked.runtime(),
        event_sink.clone(),
        linked.endpoints(),
        eos_seen.clone(),
    ) {
        Ok(watch) => watch,
        Err(error) => {
            let _ = event_sink.emit_route_terminal(
                hydra_plan::ErrorCode::RuntimeError,
                true,
                RetryDomain::Route,
                Some(&error.to_string()),
            );
            let _ = linked.shutdown();
            return Err(error);
        }
    };
    let running = match linked.start(event_sink.clone()) {
        Ok(graph) => graph,
        Err(error) => {
            drain_main_context();
            let _ = event_sink.emit_route_terminal(
                error.code(),
                false,
                RetryDomain::None,
                Some(error.detail()),
            );
            return Err(error.into());
        }
    };
    run_runtime(running, writer, event_sink, bus_watch, eos_seen)
}

fn plan_failure<T>(event_sink: &EventSink, error: hydra_plan::PlanError) -> Result<T> {
    let _ = event_sink.emit_route_terminal(
        error.code(),
        false,
        RetryDomain::None,
        Some(error.context()),
    );
    Err(error.into())
}

fn route_identity(route_id: &str, process_kind: &ProcessKind) -> RouteIdentity {
    let process_instance_id = match process_kind {
        ProcessKind::Route {
            process_instance_id,
            ..
        } => process_instance_id.clone(),
        ProcessKind::ValidateConfig
        | ProcessKind::NdiDiscovery { .. }
        | ProcessKind::NdiProbe { .. } => String::new(),
    };
    RouteIdentity {
        route_id: route_id.to_string(),
        config_revision: String::new(),
        process_instance_id,
    }
}

fn run_runtime(
    running: RunningGraph,
    writer: Arc<Mutex<Box<dyn StatsWriter>>>,
    event_sink: EventSink,
    _bus_watch: gst::bus::BusWatchGuard,
    eos_seen: Arc<std::sync::atomic::AtomicBool>,
) -> Result<()> {
    start_stats_loop(running.runtime(), writer);
    let lifecycle = running.runtime().lifecycle.clone();
    let main_loop = running.runtime().loop_.clone();
    main_loop.run();

    let status = match lifecycle.current_status() {
        Ok(status) => status,
        Err(error) => {
            let _ = event_sink.emit_route_terminal(
                hydra_plan::ErrorCode::RuntimeError,
                true,
                RetryDomain::Route,
                Some(&error.to_string()),
            );
            let _ = running.shutdown();
            return Err(error);
        }
    };
    let stop_reason = match status {
        Some(PipelineStatus::Failed) => StopReason::Failure,
        _ if eos_seen.load(std::sync::atomic::Ordering::Relaxed) => StopReason::Eos,
        _ => StopReason::Shutdown,
    };
    if let Err(error) = running.shutdown() {
        let _ = event_sink.emit_route_terminal(
            error.code(),
            false,
            RetryDomain::None,
            Some(error.detail()),
        );
        return Err(error.into());
    }
    if event_sink.route_terminal_emitted() {
        if event_sink.route_terminal_retryable() {
            // A retryable route_terminal means the process is meant to be restarted,
            // not treated as a clean stop. Exiting 0 here would be indistinguishable
            // from an operator-requested stop to anything watching this process's exit
            // status, which would drop the retry on the floor. Exit non-zero instead so
            // the retryable outcome survives past this process's exit code.
            return Err(anyhow!(
                "route terminated for a retryable reason; see the route_terminal event for the cause"
            ));
        }
        return Ok(());
    }
    lifecycle.emit_stopped(stop_reason)?;
    Ok(())
}

fn drain_main_context() {
    let context = glib::MainContext::default();
    while context.pending() {
        context.iteration(false);
    }
}

#[cfg(test)]
mod tests {
    use hydra_plan::ErrorCode;

    #[test]
    fn rejects_unknown_config_shape() {
        let error =
            hydra_plan::parse(r#"{"source":{"type":"fakesrc"},"sinks":[{"type":"fakesink"}]}"#)
                .expect_err("unknown configuration shape must not parse");
        assert_eq!(error.code(), ErrorCode::ConfigInvalid);
    }
}
