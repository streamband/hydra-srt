use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Result};
use hydra_plan::ErrorCode;
use serde::Serialize;

use crate::output::{send_json_line, SharedStdout};

const DETAIL_MAX_BYTES: usize = 500;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RouteIdentity {
    pub route_id: String,
    pub config_revision: String,
    pub process_instance_id: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Transport {
    Ndi,
    Srt,
    Udp,
    Rtp,
    Rtmp,
    Hls,
}

impl Transport {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Ndi => "ndi",
            Self::Srt => "srt",
            Self::Udp => "udp",
            Self::Rtp => "rtp",
            Self::Rtmp => "rtmp",
            Self::Hls => "hls",
        }
    }
}

impl Serialize for Transport {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EndpointDirection {
    Source,
    Destination,
}

impl EndpointDirection {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Source => "source",
            Self::Destination => "destination",
        }
    }
}

impl Serialize for EndpointDirection {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EndpointState {
    Validating,
    Connecting,
    Negotiating,
    Streaming,
    Advertising,
    Degraded,
    Reconnecting,
    Failed,
    Stopped,
}

impl EndpointState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Validating => "validating",
            Self::Connecting => "connecting",
            Self::Negotiating => "negotiating",
            Self::Streaming => "streaming",
            Self::Advertising => "advertising",
            Self::Degraded => "degraded",
            Self::Reconnecting => "reconnecting",
            Self::Failed => "failed",
            Self::Stopped => "stopped",
        }
    }
}

impl Serialize for EndpointState {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RetryDomain {
    Route,
    Destination,
    None,
}

impl RetryDomain {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Route => "route",
            Self::Destination => "destination",
            Self::None => "none",
        }
    }
}

impl Serialize for RetryDomain {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

#[derive(Clone)]
pub struct EventSink {
    writer: SharedStdout,
    identity: RouteIdentity,
    sequence: Arc<AtomicU64>,
    route_terminal_emitted: Arc<AtomicBool>,
    // Only meaningful once `route_terminal_emitted` is true; set in the same
    // write as the emitted flag so the two never disagree.
    route_terminal_retryable: Arc<AtomicBool>,
}

impl std::fmt::Debug for EventSink {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EventSink")
            .field("identity", &self.identity)
            .finish_non_exhaustive()
    }
}

impl EventSink {
    pub fn new(writer: SharedStdout, identity: RouteIdentity) -> Self {
        Self {
            writer,
            identity,
            sequence: Arc::new(AtomicU64::new(1)),
            route_terminal_emitted: Arc::new(AtomicBool::new(false)),
            route_terminal_retryable: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn with_identity(self, identity: RouteIdentity) -> Self {
        Self {
            writer: self.writer,
            identity,
            sequence: self.sequence,
            route_terminal_emitted: self.route_terminal_emitted,
            route_terminal_retryable: self.route_terminal_retryable,
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn emit_endpoint_health(
        &self,
        endpoint_id: &str,
        direction: EndpointDirection,
        transport: Transport,
        state: EndpointState,
        reason_code: Option<ErrorCode>,
        retryable: Option<bool>,
        retry_domain: Option<RetryDomain>,
        detail: Option<&str>,
    ) -> Result<()> {
        let event = EndpointHealthEvent {
            event: "endpoint_health",
            route_id: &self.identity.route_id,
            config_revision: &self.identity.config_revision,
            process_instance_id: &self.identity.process_instance_id,
            sequence: self.next_sequence(),
            endpoint_id,
            direction,
            transport,
            state,
            reason_code,
            retryable,
            retry_domain,
            observed_at_ms: observed_at_ms(),
            detail: detail.map(sanitize_detail),
        };

        self.write_event(&event)
    }

    pub fn emit_route_terminal(
        &self,
        reason_code: ErrorCode,
        retryable: bool,
        retry_domain: RetryDomain,
        detail: Option<&str>,
    ) -> Result<()> {
        if self
            .route_terminal_emitted
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Ok(());
        }
        self.route_terminal_retryable
            .store(retryable, Ordering::Release);
        let event = RouteTerminalEvent {
            event: "route_terminal",
            route_id: &self.identity.route_id,
            config_revision: &self.identity.config_revision,
            process_instance_id: &self.identity.process_instance_id,
            sequence: self.next_sequence(),
            reason_code,
            retryable,
            retry_domain,
            observed_at_ms: observed_at_ms(),
            detail: detail.map(sanitize_detail),
        };

        if let Err(error) = self.write_event(&event) {
            self.route_terminal_emitted.store(false, Ordering::Release);
            return Err(error);
        }
        Ok(())
    }

    /// Emits a `pipeline_log` event for a diagnostic line originating directly from a
    /// GStreamer bus message (bus `Error`/`Warning`), as opposed to the periodic
    /// GST_DEBUG text stream. `element` is the name of the GStreamer object the message
    /// came from; it is omitted from the wire event entirely when the bus message carried
    /// no source object, rather than being filled in with a placeholder.
    pub fn emit_pipeline_log(
        &self,
        level: &str,
        category: &str,
        element: Option<&str>,
        message: &str,
    ) -> Result<()> {
        let message = sanitize_detail(message);
        let event = PipelineLogEvent {
            event: "pipeline_log",
            route_id: &self.identity.route_id,
            config_revision: &self.identity.config_revision,
            process_instance_id: &self.identity.process_instance_id,
            sequence: self.next_sequence(),
            level,
            category,
            element,
            message: &message,
            observed_at_ms: observed_at_ms(),
        };

        self.write_event(&event)
    }

    pub fn emit_gst_error(&self, input: &crate::crash::GstCrashInput) -> Result<()> {
        crate::crash::emit_gst_error(input, &self.writer);
        Ok(())
    }

    pub fn emit_media_info(
        &self,
        endpoint_id: &str,
        live: bool,
        format_id: Option<&str>,
        media_info: serde_json::Value,
    ) -> Result<()> {
        let event = MediaInfoEvent {
            event: "media_info",
            route_id: &self.identity.route_id,
            config_revision: &self.identity.config_revision,
            process_instance_id: &self.identity.process_instance_id,
            sequence: self.next_sequence(),
            endpoint_id,
            transport: Transport::Hls,
            live,
            format_id,
            media_info,
            observed_at_ms: observed_at_ms(),
        };

        self.write_event(&event)
    }

    pub fn route_terminal_emitted(&self) -> bool {
        self.route_terminal_emitted.load(Ordering::Acquire)
    }

    /// Whether the (at most one) emitted `route_terminal` was retryable. Meaningless
    /// unless `route_terminal_emitted()` is true; callers must check that first.
    pub fn route_terminal_retryable(&self) -> bool {
        self.route_terminal_retryable.load(Ordering::Acquire)
    }

    fn next_sequence(&self) -> u64 {
        self.sequence.fetch_add(1, Ordering::SeqCst)
    }

    fn write_event<T: Serialize>(&self, event: &T) -> Result<()> {
        let mut writer = self
            .writer
            .lock()
            .map_err(|_| anyhow!("writer mutex poisoned"))?;
        send_json_line(writer.as_mut(), event)
    }
}

#[derive(Serialize)]
struct EndpointHealthEvent<'a> {
    event: &'static str,
    route_id: &'a str,
    config_revision: &'a str,
    process_instance_id: &'a str,
    sequence: u64,
    endpoint_id: &'a str,
    direction: EndpointDirection,
    transport: Transport,
    state: EndpointState,
    reason_code: Option<ErrorCode>,
    retryable: Option<bool>,
    retry_domain: Option<RetryDomain>,
    observed_at_ms: u64,
    detail: Option<String>,
}

#[derive(Serialize)]
struct PipelineLogEvent<'a> {
    event: &'static str,
    route_id: &'a str,
    config_revision: &'a str,
    process_instance_id: &'a str,
    sequence: u64,
    level: &'a str,
    category: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    element: Option<&'a str>,
    message: &'a str,
    observed_at_ms: u64,
}

#[derive(Serialize)]
struct RouteTerminalEvent<'a> {
    event: &'static str,
    route_id: &'a str,
    config_revision: &'a str,
    process_instance_id: &'a str,
    sequence: u64,
    reason_code: ErrorCode,
    retryable: bool,
    retry_domain: RetryDomain,
    observed_at_ms: u64,
    detail: Option<String>,
}

#[derive(Serialize)]
struct MediaInfoEvent<'a> {
    event: &'static str,
    route_id: &'a str,
    config_revision: &'a str,
    process_instance_id: &'a str,
    sequence: u64,
    endpoint_id: &'a str,
    transport: Transport,
    live: bool,
    format_id: Option<&'a str>,
    media_info: serde_json::Value,
    observed_at_ms: u64,
}

pub(crate) fn sanitize_detail(detail: &str) -> String {
    let cleaned: String = detail.chars().filter(|ch| !ch.is_control()).collect();
    let cleaned = redact_uri_queries(&cleaned);
    truncate_to_byte_limit(&cleaned, DETAIL_MAX_BYTES)
}

fn redact_uri_queries(value: &str) -> String {
    let mut redacted = String::with_capacity(value.len());
    let mut cursor = 0;
    while let Some(relative_start) = value[cursor..].find("http") {
        let start = cursor + relative_start;
        redacted.push_str(&value[cursor..start]);
        let remainder = &value[start..];
        let end = remainder
            .find(|character: char| {
                character.is_whitespace() || character == '"' || character == '\''
            })
            .unwrap_or(remainder.len());
        let uri = &remainder[..end];
        if let Some(query_start) = uri.find('?') {
            redacted.push_str(&uri[..query_start]);
            redacted.push_str("?[redacted]");
        } else {
            redacted.push_str(uri);
        }
        cursor = start + end;
    }
    redacted.push_str(&value[cursor..]);
    redacted
}

fn truncate_to_byte_limit(value: &str, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value.to_string();
    }

    let mut end = max_bytes;
    while end > 0 && !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_string()
}

fn observed_at_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::output::StatsWriter;
    use std::sync::{Arc, Mutex};

    #[derive(Debug, Default)]
    struct MemoryWriter {
        messages: Arc<Mutex<Vec<String>>>,
    }

    impl StatsWriter for MemoryWriter {
        fn send_message(&mut self, message: &str) -> Result<()> {
            self.messages
                .lock()
                .expect("messages lock")
                .push(message.to_string());
            Ok(())
        }
    }

    fn build_sink(identity: RouteIdentity) -> (EventSink, Arc<Mutex<Vec<String>>>) {
        let messages = Arc::new(Mutex::new(Vec::new()));
        let writer: Arc<Mutex<Box<dyn StatsWriter>>> =
            Arc::new(Mutex::new(Box::new(MemoryWriter {
                messages: messages.clone(),
            })));
        (EventSink::new(writer, identity), messages)
    }

    fn sample_identity() -> RouteIdentity {
        RouteIdentity {
            route_id: "route-1".to_string(),
            config_revision: "rev-1".to_string(),
            process_instance_id: "proc-1".to_string(),
        }
    }

    #[test]
    fn route_terminal_is_emitted_for_every_route() {
        let (sink, messages) = build_sink(sample_identity());

        sink.emit_route_terminal(ErrorCode::NdiReceiveTimeout, true, RetryDomain::Route, None)
            .expect("route terminal");
        assert_eq!(messages.lock().expect("messages lock").len(), 1);
    }

    #[test]
    fn route_terminal_is_emitted_at_most_once() {
        let (sink, messages) = build_sink(sample_identity());

        sink.emit_route_terminal(ErrorCode::RuntimeError, true, RetryDomain::Route, None)
            .expect("first route terminal");
        sink.emit_route_terminal(ErrorCode::Shutdown, false, RetryDomain::None, None)
            .expect("duplicate is suppressed");

        assert!(sink.route_terminal_emitted());
        let messages = messages.lock().expect("messages lock");
        assert_eq!(messages.len(), 1);
        assert!(messages[0].contains("RUNTIME_ERROR"));
    }

    #[test]
    fn sequence_increases_across_event_types() {
        let (sink, messages) = build_sink(sample_identity());

        sink.emit_endpoint_health(
            "endpoint-1",
            EndpointDirection::Source,
            Transport::Ndi,
            EndpointState::Connecting,
            None,
            None,
            None,
            None,
        )
        .expect("endpoint health");
        sink.emit_route_terminal(
            ErrorCode::NdiReceiveTimeout,
            true,
            RetryDomain::Route,
            Some("timed out"),
        )
        .expect("route terminal");
        sink.emit_endpoint_health(
            "endpoint-2",
            EndpointDirection::Destination,
            Transport::Ndi,
            EndpointState::Failed,
            Some(ErrorCode::NdiSourceEos),
            Some(true),
            Some(RetryDomain::Route),
            Some("eos"),
        )
        .expect("endpoint health");

        let messages = messages.lock().expect("messages lock");
        assert_eq!(messages.len(), 3);

        let first: serde_json::Value =
            serde_json::from_str(&messages[0]).expect("first event json");
        let second: serde_json::Value =
            serde_json::from_str(&messages[1]).expect("second event json");
        let third: serde_json::Value =
            serde_json::from_str(&messages[2]).expect("third event json");

        assert_eq!(first["sequence"], 1);
        assert_eq!(second["sequence"], 2);
        assert_eq!(third["sequence"], 3);
        assert_eq!(first["event"], "endpoint_health");
        assert_eq!(second["event"], "route_terminal");
        assert_eq!(third["event"], "endpoint_health");
    }

    #[test]
    fn sequence_increases_across_identity_upgrade() {
        let (sink, messages) = build_sink(sample_identity());

        sink.emit_endpoint_health(
            "endpoint-1",
            EndpointDirection::Source,
            Transport::Ndi,
            EndpointState::Connecting,
            None,
            None,
            None,
            None,
        )
        .expect("endpoint health");
        let sink = sink.with_identity(RouteIdentity {
            route_id: "route-1".to_string(),
            config_revision: "rev-2".to_string(),
            process_instance_id: "proc-1".to_string(),
        });
        sink.emit_route_terminal(ErrorCode::Shutdown, false, RetryDomain::None, None)
            .expect("route terminal");

        let messages = messages.lock().expect("messages lock");
        let first: serde_json::Value = serde_json::from_str(&messages[0]).expect("first event");
        let second: serde_json::Value = serde_json::from_str(&messages[1]).expect("second event");
        assert!(
            first["sequence"].as_u64().expect("first sequence")
                < second["sequence"].as_u64().expect("second sequence")
        );
        assert_eq!(second["config_revision"], "rev-2");
    }

    #[test]
    fn detail_sanitization_strips_control_chars_and_caps_bytes() {
        assert_eq!(sanitize_detail("hello\x07world"), "helloworld");
        assert_eq!(sanitize_detail("plain text"), "plain text");

        let long = "a".repeat(600);
        let sanitized = sanitize_detail(&long);
        assert_eq!(sanitized.len(), DETAIL_MAX_BYTES);
        assert!(sanitized.chars().all(|ch| ch == 'a'));
    }

    #[test]
    fn detail_sanitization_preserves_valid_utf8_at_boundary() {
        let value = "é".repeat(300);
        let sanitized = sanitize_detail(&value);
        assert!(sanitized.is_char_boundary(sanitized.len()));
        assert!(sanitized.len() <= DETAIL_MAX_BYTES);
    }

    #[test]
    fn detail_sanitization_redacts_hls_bearer_query_strings() {
        let detail = "GET https://r3---sn.googlevideo.com/videoplayback?expire=123&sig=secret&lsig=also-secret failed with 403";
        let sanitized = sanitize_detail(detail);
        assert_eq!(
            sanitized,
            "GET https://r3---sn.googlevideo.com/videoplayback?[redacted] failed with 403"
        );
        assert!(!sanitized.contains("secret"));
    }

    #[test]
    fn endpoint_health_payload_uses_fc3_field_names() {
        let (sink, messages) = build_sink(sample_identity());

        sink.emit_endpoint_health(
            "endpoint-1",
            EndpointDirection::Source,
            Transport::Ndi,
            EndpointState::Connecting,
            None,
            None,
            None,
            None,
        )
        .expect("endpoint health");

        let payload: serde_json::Value =
            serde_json::from_str(&messages.lock().expect("messages lock")[0])
                .expect("endpoint health json");

        assert_eq!(payload["event"], "endpoint_health");
        assert_eq!(payload["route_id"], "route-1");
        assert_eq!(payload["config_revision"], "rev-1");
        assert_eq!(payload["process_instance_id"], "proc-1");
        assert_eq!(payload["endpoint_id"], "endpoint-1");
        assert_eq!(payload["direction"], "source");
        assert_eq!(payload["transport"], "ndi");
        assert_eq!(payload["state"], "connecting");
        assert!(payload["reason_code"].is_null());
        assert!(payload["retryable"].is_null());
        assert!(payload["retry_domain"].is_null());
        assert!(payload["detail"].is_null());
        assert!(payload["observed_at_ms"].is_number());
    }

    #[test]
    fn pipeline_log_payload_carries_level_category_element_and_message() {
        let (sink, messages) = build_sink(sample_identity());

        sink.emit_pipeline_log(
            "ERROR",
            "gst_bus",
            Some("srtsrc0"),
            "Failed to authenticate: Incorrect passphrase (10)",
        )
        .expect("pipeline log");

        let payload: serde_json::Value =
            serde_json::from_str(&messages.lock().expect("messages lock")[0])
                .expect("pipeline log json");

        assert_eq!(payload["event"], "pipeline_log");
        assert_eq!(payload["route_id"], "route-1");
        assert_eq!(payload["config_revision"], "rev-1");
        assert_eq!(payload["process_instance_id"], "proc-1");
        assert_eq!(payload["level"], "ERROR");
        assert_eq!(payload["category"], "gst_bus");
        assert_eq!(payload["element"], "srtsrc0");
        assert_eq!(
            payload["message"],
            "Failed to authenticate: Incorrect passphrase (10)"
        );
        assert!(payload["observed_at_ms"].is_number());
    }

    #[test]
    fn pipeline_log_omits_element_field_entirely_when_genuinely_absent() {
        let (sink, messages) = build_sink(sample_identity());

        sink.emit_pipeline_log(
            "WARN",
            "gst_bus",
            None,
            "streaming stopped, reason error (-5)",
        )
        .expect("pipeline log");

        let raw = messages.lock().expect("messages lock")[0].clone();
        let payload: serde_json::Value = serde_json::from_str(&raw).expect("pipeline log json");

        // Hard rule: no placeholder/"unknown" filler for a missing element - the key
        // must not appear at all, not appear with a null/empty value.
        assert!(
            !payload.as_object().expect("object").contains_key("element"),
            "element key must be omitted, not null, when absent: {raw}"
        );
        assert_eq!(payload["level"], "WARN");
    }

    #[test]
    fn pipeline_log_sequence_advances_independently_of_other_event_types() {
        let (sink, messages) = build_sink(sample_identity());

        sink.emit_endpoint_health(
            "endpoint-1",
            EndpointDirection::Source,
            Transport::Srt,
            EndpointState::Failed,
            Some(ErrorCode::RuntimeError),
            Some(true),
            Some(RetryDomain::Route),
            None,
        )
        .expect("endpoint health");
        sink.emit_pipeline_log("ERROR", "gst_bus", Some("srtsrc0"), "boom")
            .expect("pipeline log");

        let messages = messages.lock().expect("messages lock");
        let first: serde_json::Value = serde_json::from_str(&messages[0]).expect("first json");
        let second: serde_json::Value = serde_json::from_str(&messages[1]).expect("second json");

        assert!(second["sequence"].as_u64().unwrap() > first["sequence"].as_u64().unwrap());
    }
}
