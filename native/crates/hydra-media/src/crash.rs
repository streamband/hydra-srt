use std::backtrace::Backtrace;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::panic::{self, AssertUnwindSafe};
use std::str::FromStr;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Error;
use serde::Serialize;

use crate::events::Transport;
use crate::output::{send_json_line, SharedStdout};

const ERROR_CLASS_MAX_BYTES: usize = 96;
const MESSAGE_MAX_BYTES: usize = 512;
const FRAME_MAX_COUNT: usize = 30;
const FRAME_FIELD_MAX_BYTES: usize = 160;

static CURRENT_CONTEXT: OnceLock<Mutex<Option<CrashContext>>> = OnceLock::new();

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CrashContext {
    pub route_id: String,
    pub config_revision: String,
    pub process_instance_id: String,
    pub source_transport: Transport,
    pub destination_transports: Vec<Transport>,
    pub pipeline_state: PipelineState,
    pub gst_element: Option<String>,
}

impl CrashContext {
    pub fn from_route_config(config: &hydra_plan::RouteConfig) -> Self {
        Self {
            route_id: config.route_id.clone(),
            config_revision: config.config_revision.clone(),
            process_instance_id: config.process_instance_id.clone(),
            source_transport: source_transport(&config.source),
            destination_transports: config
                .destinations
                .iter()
                .map(destination_transport)
                .collect(),
            pipeline_state: PipelineState::Starting,
            gst_element: None,
        }
    }

    pub fn for_process(route_id: &str, process_instance_id: &str) -> Self {
        Self {
            route_id: route_id.to_owned(),
            config_revision: String::new(),
            process_instance_id: process_instance_id.to_owned(),
            source_transport: Transport::Hls,
            destination_transports: Vec::new(),
            pipeline_state: PipelineState::Starting,
            gst_element: None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PipelineState {
    Starting,
    Playing,
    Paused,
    Stopping,
    Stopped,
    Failed,
    Unknown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CrashKind {
    Panic,
    Fatal,
    GstError,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct CrashFrame {
    pub module: String,
    pub function: String,
    pub file: Option<String>,
    pub line: Option<u32>,
}

#[derive(Clone, Debug, Serialize)]
pub struct CrashEnvelope {
    pub event: &'static str,
    pub route_id: String,
    pub config_revision: String,
    pub process_instance_id: String,
    pub kind: CrashKind,
    pub error_class: String,
    pub message: String,
    pub frames: Vec<CrashFrame>,
    pub thread: String,
    pub gst_element: Option<String>,
    pub pipeline_state: PipelineState,
    pub route_source_transport: Transport,
    pub route_destination_transports: Vec<Transport>,
    pub version: &'static str,
    pub ts: i64,
}

#[derive(Clone, Debug)]
pub struct GstCrashInput {
    pub error_class: String,
    pub message: String,
    pub gst_element: Option<String>,
    pub retryable: bool,
}

pub fn set_current_context(context: CrashContext) {
    let state = CURRENT_CONTEXT.get_or_init(|| Mutex::new(None));
    if let Ok(mut current) = state.lock() {
        *current = Some(context);
    }
}

pub fn install_panic_hook(shared_stdout: SharedStdout) {
    panic::set_hook(Box::new(move |panic_info| {
        let _ = panic::catch_unwind(AssertUnwindSafe(|| {
            let payload = panic_payload(panic_info.payload());
            let backtrace = Backtrace::force_capture();
            let context = current_context().unwrap_or_else(default_context);
            let envelope = CrashEnvelope {
                event: "crash",
                route_id: context.route_id,
                config_revision: context.config_revision,
                process_instance_id: context.process_instance_id,
                kind: CrashKind::Panic,
                error_class: scrub_text("panic", ERROR_CLASS_MAX_BYTES),
                message: scrub_text(&payload, MESSAGE_MAX_BYTES),
                frames: parse_backtrace(&backtrace.to_string()),
                thread: scrub_text(
                    std::thread::current().name().unwrap_or("unnamed"),
                    FRAME_FIELD_MAX_BYTES,
                ),
                gst_element: context
                    .gst_element
                    .as_deref()
                    .map(|value| scrub_text(value, FRAME_FIELD_MAX_BYTES)),
                pipeline_state: context.pipeline_state,
                route_source_transport: context.source_transport,
                route_destination_transports: context.destination_transports,
                version: hydra_version(),
                ts: epoch_millis(),
            };
            let _ = try_emit_json(&shared_stdout, &envelope);
        }));
    }));
}

pub fn emit_fatal(error: &Error, shared_stdout: &SharedStdout) {
    let context = current_context().unwrap_or_else(default_context);
    let envelope = CrashEnvelope {
        event: "crash",
        route_id: context.route_id,
        config_revision: context.config_revision,
        process_instance_id: context.process_instance_id,
        kind: CrashKind::Fatal,
        error_class: scrub_text("anyhow_root_cause", ERROR_CLASS_MAX_BYTES),
        message: scrub_text(&error.to_string(), MESSAGE_MAX_BYTES),
        frames: Vec::new(),
        thread: scrub_text(
            std::thread::current().name().unwrap_or("unnamed"),
            FRAME_FIELD_MAX_BYTES,
        ),
        gst_element: context
            .gst_element
            .as_deref()
            .map(|value| scrub_text(value, FRAME_FIELD_MAX_BYTES)),
        pipeline_state: context.pipeline_state,
        route_source_transport: context.source_transport,
        route_destination_transports: context.destination_transports,
        version: hydra_version(),
        ts: epoch_millis(),
    };
    let _ = emit_json(shared_stdout, &envelope);
}

pub fn emit_gst_error(error: &GstCrashInput, shared_stdout: &SharedStdout) {
    if error.retryable {
        return;
    }

    let context = current_context().unwrap_or_else(default_context);
    let envelope = CrashEnvelope {
        event: "crash",
        route_id: context.route_id,
        config_revision: context.config_revision,
        process_instance_id: context.process_instance_id,
        kind: CrashKind::GstError,
        error_class: scrub_text(&error.error_class, ERROR_CLASS_MAX_BYTES),
        message: scrub_text(&error.message, MESSAGE_MAX_BYTES),
        frames: Vec::new(),
        thread: scrub_text(
            std::thread::current().name().unwrap_or("unnamed"),
            FRAME_FIELD_MAX_BYTES,
        ),
        gst_element: error
            .gst_element
            .as_deref()
            .or(context.gst_element.as_deref())
            .map(|value| scrub_text(value, FRAME_FIELD_MAX_BYTES)),
        pipeline_state: PipelineState::Failed,
        route_source_transport: context.source_transport,
        route_destination_transports: context.destination_transports,
        version: hydra_version(),
        ts: epoch_millis(),
    };
    let _ = emit_json(shared_stdout, &envelope);
}

pub fn parse_backtrace(backtrace: &str) -> Vec<CrashFrame> {
    let mut frames = Vec::with_capacity(FRAME_MAX_COUNT);
    for line in backtrace.lines().take(FRAME_MAX_COUNT * 4) {
        let trimmed = line.trim();
        if let Some(symbol) = backtrace_symbol(trimmed) {
            if frames.len() == FRAME_MAX_COUNT {
                break;
            }
            let foreign_module = module_name(symbol);
            let hydra = is_hydra_module(&foreign_module);
            frames.push(CrashFrame {
                module: scrub_text(
                    if hydra {
                        &foreign_module
                    } else {
                        foreign_module.as_str()
                    },
                    FRAME_FIELD_MAX_BYTES,
                ),
                function: if hydra {
                    scrub_text(symbol, FRAME_FIELD_MAX_BYTES)
                } else {
                    String::new()
                },
                file: None,
                line: None,
            });
        } else if let Some((file, line_number)) = backtrace_location(trimmed) {
            if let Some(frame) = frames.last_mut() {
                if is_hydra_module(&frame.module) {
                    frame.file = Some(cap_bytes(
                        &relative_native_file(file),
                        FRAME_FIELD_MAX_BYTES,
                    ));
                    frame.line = Some(line_number);
                }
            }
        }
    }
    frames
}

pub fn scrub_text(input: &str, max_bytes: usize) -> String {
    let input = String::from_utf8_lossy(input.as_bytes());
    let mut output = String::with_capacity(input.len().min(max_bytes));
    let chars: Vec<char> = input.chars().collect();
    let mut index = 0;

    while index < chars.len() {
        if let Some(end) = url_end(&chars, index) {
            output.push_str("[URL]");
            index = end;
        } else if let Some((key_end, value_end)) = sensitive_parameter(&chars, index) {
            output.extend(chars[index..key_end].iter());
            output.push_str("[REDACTED]");
            index = value_end;
        } else if absolute_path_at(&chars, index) {
            output.push_str("[PATH]");
            index = token_end(&chars, index);
        } else {
            output.push(chars[index]);
            index += 1;
        }
    }

    redact_network_tokens(&output, max_bytes)
}

pub fn scrub_bytes(input: &[u8], max_bytes: usize) -> String {
    scrub_text(&String::from_utf8_lossy(input), max_bytes)
}

pub fn hydra_version() -> &'static str {
    env!("HYDRA_SRT_VERSION")
}

pub fn epoch_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(i64::MAX as u128) as i64)
        .unwrap_or(0)
}

pub fn source_transport(source: &hydra_plan::SourceEndpoint) -> Transport {
    match source {
        hydra_plan::SourceEndpoint::Ndi { .. } => Transport::Ndi,
        hydra_plan::SourceEndpoint::Srt { .. } => Transport::Srt,
        hydra_plan::SourceEndpoint::Udp { .. } => Transport::Udp,
        hydra_plan::SourceEndpoint::Rtp { .. } => Transport::Rtp,
        hydra_plan::SourceEndpoint::Rtmp { .. } => Transport::Rtmp,
        hydra_plan::SourceEndpoint::Hls { .. } => Transport::Hls,
    }
}

pub fn destination_transport(destination: &hydra_plan::DestinationEndpoint) -> Transport {
    match destination {
        hydra_plan::DestinationEndpoint::Ndi { .. } => Transport::Ndi,
        hydra_plan::DestinationEndpoint::Srt { .. } => Transport::Srt,
        hydra_plan::DestinationEndpoint::Udp { .. } => Transport::Udp,
        hydra_plan::DestinationEndpoint::Rtp { .. } => Transport::Rtp,
        hydra_plan::DestinationEndpoint::Rtmp { .. } => Transport::Rtmp,
    }
}

pub fn try_emit_json<T: Serialize>(shared_stdout: &SharedStdout, value: &T) -> bool {
    match shared_stdout.try_lock() {
        Ok(mut writer) => send_json_line(writer.as_mut(), value).is_ok(),
        Err(_) => false,
    }
}

pub fn emit_json<T: Serialize>(shared_stdout: &SharedStdout, value: &T) -> bool {
    match shared_stdout.lock() {
        Ok(mut writer) => send_json_line(writer.as_mut(), value).is_ok(),
        Err(_) => false,
    }
}

pub fn panic_payload(payload: &(dyn std::any::Any + Send)) -> String {
    payload
        .downcast_ref::<&str>()
        .map(|value| (*value).to_owned())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "unknown_panic_payload".to_owned())
}

pub fn current_context() -> Option<CrashContext> {
    CURRENT_CONTEXT
        .get()
        .and_then(|state| state.lock().ok().and_then(|current| current.clone()))
}

pub fn default_context() -> CrashContext {
    CrashContext {
        route_id: String::new(),
        config_revision: String::new(),
        process_instance_id: String::new(),
        source_transport: Transport::Udp,
        destination_transports: Vec::new(),
        pipeline_state: PipelineState::Unknown,
        gst_element: None,
    }
}

pub fn backtrace_symbol(line: &str) -> Option<&str> {
    let (index, symbol) = line.split_once(':')?;
    if index.trim().parse::<usize>().is_ok() && !symbol.trim().is_empty() {
        Some(symbol.trim())
    } else {
        None
    }
}

pub fn backtrace_location(line: &str) -> Option<(&str, u32)> {
    let line = line.strip_prefix("at ")?;
    let (prefix, last) = line.rsplit_once(':')?;
    if let Ok(column) = last.trim().parse::<u32>() {
        if let Some((file, line_number)) = prefix.rsplit_once(':') {
            if let Ok(line_number) = line_number.trim().parse::<u32>() {
                let _ = column;
                return Some((file.trim(), line_number));
            }
        }
        return Some((prefix.trim(), column));
    }
    None
}

pub fn module_name(symbol: &str) -> String {
    symbol.split("::").next().unwrap_or("unknown").to_owned()
}

pub fn is_hydra_module(module: &str) -> bool {
    module.starts_with("hydra_") || module == "hydra"
}

pub fn relative_native_file(file: &str) -> String {
    if let Some((_, relative)) = file.split_once("native/") {
        format!("native/{relative}")
    } else {
        scrub_text(file, FRAME_FIELD_MAX_BYTES)
    }
}

pub fn hydra_test_crash_if_requested() {
    #[cfg(debug_assertions)]
    if std::env::var("HYDRA_EMIT_TEST_CRASH").as_deref() == Ok("panic") {
        panic!("hydra test crash");
    }
}

pub fn url_end(chars: &[char], start: usize) -> Option<usize> {
    let schemes = [
        "http://", "https://", "srt://", "rtmp://", "udp://", "rtp://",
    ];
    let remaining: String = chars[start..].iter().collect();
    schemes
        .iter()
        .find(|scheme| remaining.starts_with(**scheme))
        .map(|_| {
            start
                + chars[start..]
                    .iter()
                    .position(|character| {
                        character.is_whitespace()
                            || matches!(*character, '"' | '\'' | ')' | ']' | '>')
                    })
                    .unwrap_or(chars.len() - start)
        })
}

pub fn sensitive_parameter(chars: &[char], start: usize) -> Option<(usize, usize)> {
    let keys = [
        "passphrase=",
        "streamid=",
        "stream-key=",
        "token=",
        "access_token=",
        "authorization=",
        "bearer=",
    ];
    let remaining: String = chars[start..].iter().collect();
    let key = keys.iter().find(|key| {
        remaining
            .get(..key.len())
            .is_some_and(|value| value.eq_ignore_ascii_case(key))
            && (start == 0 || !chars[start - 1].is_ascii_alphanumeric())
    })?;
    let key_end = start + key.len();
    Some((key_end, token_end(chars, key_end)))
}

pub fn absolute_path_at(chars: &[char], start: usize) -> bool {
    if chars[start] == '/' {
        return (start == 0 || !chars[start - 1].is_ascii_alphanumeric())
            && start + 1 < chars.len()
            && chars[start + 1] != '/';
    }
    (start == 0 || !chars[start - 1].is_ascii_alphanumeric())
        && chars.get(start + 1).is_some_and(|value| *value == ':')
        && chars
            .get(start + 2)
            .is_some_and(|value| *value == '\\' || *value == '/')
}

pub fn token_end(chars: &[char], start: usize) -> usize {
    chars[start..]
        .iter()
        .position(|character| {
            character.is_whitespace() || matches!(*character, '"' | '\'' | ',' | ';' | ')' | ']')
        })
        .map(|offset| start + offset)
        .unwrap_or(chars.len())
}

pub fn redact_network_tokens(input: &str, max_bytes: usize) -> String {
    let mut output = String::new();
    let mut token = String::new();
    let flush = |output: &mut String, token: &mut String| {
        if token.is_empty() {
            return;
        }
        let trimmed = token.trim_matches(|character: char| "([{<".contains(character));
        let replacement = if is_ip_token(trimmed) {
            "[IP]"
        } else {
            trimmed
        };
        output.push_str(replacement);
        token.clear();
    };

    for character in input.chars() {
        if character.is_whitespace() || matches!(character, '"' | '\'' | ',' | ';' | ')' | ']') {
            flush(&mut output, &mut token);
            output.push(character);
        } else {
            token.push(character);
        }
    }
    flush(&mut output, &mut token);
    cap_bytes(&output, max_bytes)
}

pub fn is_ip_token(token: &str) -> bool {
    let token = token.trim_matches(|character| "][}>".contains(character));
    if Ipv4Addr::from_str(token).is_ok() || Ipv6Addr::from_str(token).is_ok() {
        return true;
    }
    token
        .split_once(':')
        .is_some_and(|(host, _port)| Ipv4Addr::from_str(host).is_ok())
}

pub fn cap_bytes(input: &str, max_bytes: usize) -> String {
    if input.len() <= max_bytes {
        return input.to_owned();
    }
    let mut end = max_bytes;
    while !input.is_char_boundary(end) {
        end -= 1;
    }
    input[..end].to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scrubs_credentials_urls_ips_and_paths() {
        let value = scrub_text(
            "srt://example.com:9000?passphrase=secret&streamid=private 192.0.2.9 [2001:db8::1] /home/alice/private/config.json C:\\Users\\alice\\secret.json",
            MESSAGE_MAX_BYTES,
        );
        for forbidden in [
            "example.com",
            "secret",
            "private",
            "192.0.2.9",
            "2001:db8",
            "/home/alice",
            "C:\\Users\\alice",
        ] {
            assert!(!value.contains(forbidden), "found {forbidden} in {value}");
        }
    }

    #[test]
    fn scrubs_nested_error_and_caps_bytes() {
        let value = scrub_text("outer: passphrase=secret inner: /tmp/private", 16);
        assert!(value.len() <= 16);
        assert!(!value.contains("secret"));
        assert!(!value.contains("/tmp"));
    }

    #[test]
    fn parses_hydra_frames_and_collapses_foreign_frames() {
        let frames = parse_backtrace(
            "   0: hydra_pipeline::run_route\n             at /Users/alice/src/native/crates/hydra-pipeline/src/main.rs:146\n   1: std::panicking::begin_panic_handler\n             at /rustc/library/std/src/panicking.rs:590",
        );
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0].module, "hydra_pipeline");
        assert_eq!(
            frames[0].file.as_deref(),
            Some("native/crates/hydra-pipeline/src/main.rs")
        );
        assert_eq!(frames[0].line, Some(146));
        assert_eq!(frames[1].module, "std");
        assert!(frames[1].function.is_empty());
        assert!(frames[1].file.is_none());
    }

    #[test]
    fn caps_unicode_without_splitting_utf8() {
        let value = cap_bytes("ééé", 3);
        assert_eq!(value, "é");
    }

    #[test]
    fn replaces_malformed_utf8_before_scrubbing() {
        assert_eq!(scrub_bytes(&[0xff, b'a'], 16), "�a");
    }

    #[test]
    fn retryable_gstreamer_errors_are_not_emitted() {
        let writer = std::sync::Arc::new(std::sync::Mutex::new(Box::new(
            crate::output::DiscardWriter,
        )
            as Box<dyn crate::output::StatsWriter>));
        emit_gst_error(
            &GstCrashInput {
                error_class: "network".to_owned(),
                message: "peer disconnected".to_owned(),
                gst_element: None,
                retryable: true,
            },
            &writer,
        );
    }
}
