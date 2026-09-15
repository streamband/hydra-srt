use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::{Context, Result};
use gstreamer as gst;
use gstreamer::prelude::*;
use hydra_plan::ErrorCode;

use crate::adapters::hls;
use crate::adapters::ndi_source::classify_readiness_details;
use crate::events::{EndpointDirection, EndpointState, EventSink, RetryDomain, Transport};
use crate::lifecycle::{FailureReason, StopReason};
use crate::runtime::{EndpointDescriptor, PipelineRuntime};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ErrorClassification {
    pub code: ErrorCode,
    pub retryable: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TypedGstError {
    Resource(gst::ResourceError),
    Core(gst::CoreError),
    Stream(gst::StreamError),
    Library(gst::LibraryError),
    Other,
}

pub fn classify_typed_error(error: TypedGstError) -> ErrorClassification {
    match error {
        TypedGstError::Core(
            gst::CoreError::Negotiation | gst::CoreError::Caps | gst::CoreError::Pad,
        )
        | TypedGstError::Stream(
            gst::StreamError::TypeNotFound
            | gst::StreamError::WrongType
            | gst::StreamError::CodecNotFound
            | gst::StreamError::Decode
            | gst::StreamError::Encode
            | gst::StreamError::Demux
            | gst::StreamError::Mux
            | gst::StreamError::Format,
        ) => ErrorClassification {
            code: ErrorCode::NegotiationFailed,
            retryable: false,
        },
        TypedGstError::Core(gst::CoreError::MissingPlugin) => ErrorClassification {
            code: ErrorCode::ElementMissing,
            retryable: false,
        },
        // GStreamer's SRT plugin never actually posts GST_RESOURCE_ERROR_NOT_AUTHORIZED
        // for a wrong passphrase; a real capture shows the bus error is
        // GST_RESOURCE_ERROR_READ ("Could not read from resource.") with the real cause
        // buried in the debug string. NotAuthorized is left in the generic bucket below
        // so a genuine future NotAuthorized (from some other, non-SRT element) is not
        // mislabeled with an SRT-specific code; see `classify_srt_auth_failure` for the
        // real detection path, which is scoped to SRT endpoints and keyed on that debug
        // text instead.
        TypedGstError::Resource(_) => ErrorClassification {
            code: ErrorCode::RuntimeError,
            retryable: true,
        },
        TypedGstError::Core(_)
        | TypedGstError::Stream(_)
        | TypedGstError::Library(_)
        | TypedGstError::Other => ErrorClassification {
            code: ErrorCode::RuntimeError,
            retryable: true,
        },
    }
}

pub fn classify_gst_error(error: &glib::Error) -> ErrorClassification {
    let typed = if let Some(kind) = error.kind::<gst::ResourceError>() {
        TypedGstError::Resource(kind)
    } else if let Some(kind) = error.kind::<gst::CoreError>() {
        TypedGstError::Core(kind)
    } else if let Some(kind) = error.kind::<gst::StreamError>() {
        TypedGstError::Stream(kind)
    } else if let Some(kind) = error.kind::<gst::LibraryError>() {
        TypedGstError::Library(kind)
    } else {
        TypedGstError::Other
    };
    classify_typed_error(typed)
}

pub fn attach_bus_watch(
    runtime: &PipelineRuntime,
    event_sink: EventSink,
    endpoints: &[EndpointDescriptor],
    eos_seen: Arc<AtomicBool>,
) -> Result<gst::bus::BusWatchGuard> {
    let bus = runtime
        .pipeline
        .bus()
        .ok_or_else(|| anyhow::anyhow!("pipeline has no bus"))?;
    let endpoint_by_bin: HashMap<_, _> = endpoints
        .iter()
        .cloned()
        .map(|endpoint| (endpoint.bin_name.clone(), endpoint))
        .collect();
    let main_loop = runtime.loop_.clone();
    let pipeline_obj = runtime.pipeline.clone().upcast::<gst::Object>();
    let source_obj = runtime.source.clone().upcast::<gst::Object>();
    let source_element = runtime.source.clone();
    let lifecycle = runtime.lifecycle.clone();
    let processing_pending = runtime.processing_pending.clone();
    let route_playing = Arc::new(AtomicBool::new(false));

    if let Some(endpoint) = endpoints
        .iter()
        .find(|endpoint| endpoint.direction == EndpointDirection::Source)
        .filter(|endpoint| endpoint.transport == Transport::Hls)
    {
        if let Some(policy) = hls::eos_policy(&source_element) {
            hls::attach_media_info_monitor(
                &source_element,
                event_sink.clone(),
                endpoint.clone(),
                policy.live,
            );
        }
    }

    bus.add_watch(move |_bus, msg| {
        use gst::MessageView;

        match msg.view() {
            MessageView::Error(error_message) => {
                let error = error_message.error();
                let endpoint = nearest_endpoint(msg.src(), &endpoint_by_bin);
                let classification = classify_error_message(
                    error_message,
                    endpoint.as_ref(),
                    route_playing.load(Ordering::Acquire),
                );
                let retry_domain = retry_domain(classification.retryable, endpoint.as_ref());
                let gst_detail = format_gst_bus_message(&error, error_message.debug().as_deref());
                let access_denied = endpoint.as_ref().is_some_and(|endpoint| {
                    endpoint.transport == Transport::Hls && hls_access_denied(&gst_detail)
                });
                let detail = if access_denied {
                    format!("HLS_ACCESS_DENIED: {gst_detail}")
                } else {
                    error.to_string()
                };

                if let Some(endpoint) = endpoint.as_ref() {
                    let _ = event_sink.emit_endpoint_health(
                        &endpoint.endpoint_id,
                        endpoint.direction,
                        endpoint.transport,
                        EndpointState::Failed,
                        Some(classification.code),
                        Some(classification.retryable),
                        Some(retry_domain),
                        Some(&detail),
                    );
                }
                let _ = event_sink.emit_route_terminal(
                    classification.code,
                    classification.retryable,
                    retry_domain,
                    Some(&detail),
                );
                let _ = event_sink.emit_gst_error(&crate::crash::GstCrashInput {
                    error_class: classification.code.as_str().to_owned(),
                    message: detail.clone(),
                    gst_element: msg.src().map(|src| src.name().to_string()),
                    retryable: classification.retryable,
                });
                let element_name = msg.src().map(|src| src.name());
                let category = if access_denied {
                    HLS_ACCESS_CATEGORY
                } else {
                    PIPELINE_LOG_CATEGORY
                };
                let _ = event_sink.emit_pipeline_log(
                    "ERROR",
                    category,
                    element_name.as_deref(),
                    &gst_detail,
                );
                let _ = lifecycle.emit_failed(FailureReason::RuntimeError);
                main_loop.quit();
            }
            MessageView::Warning(warning_message) => {
                // Warnings never change route/endpoint lifecycle state - they are
                // diagnostics only, surfaced so the real cause of a later error (or of
                // a degraded-but-still-running pipeline) is not stranded in the raw
                // GST_DEBUG stream.
                let warning = warning_message.error();
                let element_name = msg.src().map(|src| src.name());
                let _ = event_sink.emit_pipeline_log(
                    "WARN",
                    PIPELINE_LOG_CATEGORY,
                    element_name.as_deref(),
                    &format_gst_bus_message(&warning, warning_message.debug().as_deref()),
                );
            }
            MessageView::Eos(..) => {
                if let Some((endpoint, code, detail, retryable, clean)) =
                    classify_source_eos(&endpoint_by_bin, &source_element)
                {
                    let _ = event_sink.emit_endpoint_health(
                        &endpoint.endpoint_id,
                        endpoint.direction,
                        endpoint.transport,
                        if clean {
                            EndpointState::Stopped
                        } else {
                            EndpointState::Failed
                        },
                        Some(code),
                        Some(retryable),
                        Some(retry_domain(retryable, Some(&endpoint))),
                        Some(detail),
                    );
                    let _ = event_sink.emit_route_terminal(
                        code,
                        retryable,
                        retry_domain(retryable, Some(&endpoint)),
                        Some(detail),
                    );
                    if clean {
                        let _ = lifecycle.emit_stopped(StopReason::Eos);
                    } else {
                        let _ = lifecycle.emit_failed(FailureReason::RuntimeError);
                    }
                } else {
                    eos_seen.store(true, Ordering::Relaxed);
                }
                main_loop.quit();
            }
            MessageView::StateChanged(state_changed) => {
                if msg.src().is_some_and(|source| *source == pipeline_obj)
                    && state_changed.current() == gst::State::Playing
                {
                    route_playing.store(true, Ordering::Release);
                }
                if state_changed.current() == gst::State::Playing
                    && message_source_is_factory(msg, "ndisink")
                {
                    if let Some(endpoint) = nearest_endpoint(msg.src(), &endpoint_by_bin) {
                        let _ = event_sink.emit_endpoint_health(
                            &endpoint.endpoint_id,
                            endpoint.direction,
                            endpoint.transport,
                            EndpointState::Advertising,
                            None,
                            None,
                            None,
                            None,
                        );
                    }
                }
            }
            MessageView::Element(element) => {
                if let Some(structure) = element.structure() {
                    let is_source_msg = msg.src().map(|src| *src == source_obj).unwrap_or(false);
                    if is_source_msg
                        && structure.name() == "connection-removed"
                        && lifecycle.emit_reconnecting().unwrap_or(false)
                    {
                        processing_pending.store(true, Ordering::Release);
                    }
                }
            }
            _ => {}
        }

        glib::ControlFlow::Continue
    })
    .context("failed to attach current bus watch")
}

/// Category used for `pipeline_log` events emitted directly from a GStreamer bus
/// `Error`/`Warning` message, as opposed to the RTMP remux adapter's own emitter
/// (category `"rtmp_remux"`) or the raw GST_DEBUG text stream.
const PIPELINE_LOG_CATEGORY: &str = "gst_bus";
const HLS_ACCESS_CATEGORY: &str = "hls_access";

fn hls_access_denied(detail: &str) -> bool {
    let detail = detail.to_ascii_lowercase();
    detail.contains("403")
        || detail.contains("forbidden")
        || detail.contains("not authorized")
        || detail.contains("unauthorized")
}

/// Combines a GError's message with its (optional) extra debug string into a single
/// human-readable line, such as the SRT plugin's wrong-passphrase diagnostic:
/// `"Failed to authenticate: Incorrect passphrase (10)"`. When GStreamer supplies no
/// debug string the combination is just the error text - there is nothing to append.
fn format_gst_bus_message(error: &glib::Error, debug: Option<&str>) -> String {
    match debug {
        Some(debug) if !debug.is_empty() => format!("{error} | debug: {debug}"),
        _ => error.to_string(),
    }
}

fn classify_error_message(
    error_message: &gst::message::Error,
    endpoint: Option<&EndpointDescriptor>,
    route_playing: bool,
) -> ErrorClassification {
    if let Some(code) = classify_readiness_details(error_message.details()) {
        return ErrorClassification {
            code,
            retryable: true,
        };
    }
    if let Some(classification) = classify_srt_auth_failure(
        &error_message.error(),
        error_message.debug().as_deref(),
        endpoint,
    ) {
        return classification;
    }
    if let Some(classification) = classify_ndi_sender_start_failure(endpoint, route_playing) {
        return classification;
    }
    let classification = classify_gst_error(&error_message.error());
    if endpoint.is_some_and(|endpoint| {
        endpoint.transport == Transport::Hls && classification.code == ErrorCode::NegotiationFailed
    }) {
        ErrorClassification {
            code: classification.code,
            retryable: true,
        }
    } else {
        classification
    }
}

/// The exact text GStreamer's SRT plugin (gst-plugins-bad's `srtobject.c`) writes into
/// a bus error's debug string when the SRT library rejects a connection for a wrong
/// passphrase. Captured verbatim, byte for byte, from five independent real
/// gst-launch/pipeline runs against a listener configured with a different passphrase;
/// every one of them produced this exact line - never any other wording - as the last
/// line of the debug string, following a `GST_RESOURCE_ERROR_READ` ("Could not read
/// from resource.") primary error. It is SRT's own fixed rejection message, not
/// anything this codebase controls or could post itself, so matching it verbatim (not
/// a loose keyword) is as reliable a discriminator as the wire protocol allows.
const SRT_AUTH_FAILURE_DEBUG_TEXT: &str = "Failed to authenticate: Incorrect passphrase";

/// Detects the real wrong-passphrase failure shape and maps it to
/// `ErrorCode::SrtAuthFailed`. Gated on two things at once, so it can never mislabel
/// anything else:
/// - the endpoint's transport must be SRT (an HTTP/RTMP element that happens to post a
///   `RESOURCE_ERROR_READ` with unrelated debug text must never come out as
///   SRT_AUTH_FAILED);
/// - the GError's domain/code must be `GST_RESOURCE_ERROR_READ` specifically (the same
///   captures show a *second*, unrelated bus error - "Internal data stream error.",
///   `GST_STREAM_ERROR_FAILED` from basesrc - immediately afterward; that one must keep
///   falling through to the generic classification, not be caught here).
///
/// Retryable, unlike a typical auth failure: a wrong passphrase can be fixed on the far
/// side without anyone touching this route, so failing this route permanently would
/// make an unattended recovery impossible.
fn classify_srt_auth_failure(
    error: &glib::Error,
    debug: Option<&str>,
    endpoint: Option<&EndpointDescriptor>,
) -> Option<ErrorClassification> {
    let is_srt = endpoint.is_some_and(|endpoint| endpoint.transport == Transport::Srt);
    let is_resource_read = error.kind::<gst::ResourceError>() == Some(gst::ResourceError::Read);
    if !is_srt || !is_resource_read {
        return None;
    }
    let carries_auth_text = debug.is_some_and(|debug| debug.contains(SRT_AUTH_FAILURE_DEBUG_TEXT));
    carries_auth_text.then_some(ErrorClassification {
        code: ErrorCode::SrtAuthFailed,
        retryable: true,
    })
}

fn classify_ndi_sender_start_failure(
    endpoint: Option<&EndpointDescriptor>,
    route_playing: bool,
) -> Option<ErrorClassification> {
    (!route_playing
        && endpoint.is_some_and(|endpoint| {
            endpoint.direction == EndpointDirection::Destination
                && endpoint.transport == Transport::Ndi
        }))
    .then_some(ErrorClassification {
        code: ErrorCode::NdiSenderStartFailed,
        retryable: true,
    })
}

fn message_source_is_factory(message: &gst::MessageRef, expected: &str) -> bool {
    message
        .src()
        .and_then(|source| source.downcast_ref::<gst::Element>())
        .and_then(gst::Element::factory)
        .is_some_and(|factory| factory.name() == expected)
}

fn nearest_endpoint(
    source: Option<&gst::Object>,
    endpoint_by_bin: &HashMap<String, EndpointDescriptor>,
) -> Option<EndpointDescriptor> {
    let mut current = source.cloned();
    while let Some(object) = current {
        let name = object.name();
        if (name.starts_with("dest_") || name.starts_with("source_"))
            && endpoint_by_bin.contains_key(name.as_str())
        {
            return endpoint_by_bin.get(name.as_str()).cloned();
        }
        current = object.parent();
    }
    None
}

fn retry_domain(retryable: bool, endpoint: Option<&EndpointDescriptor>) -> RetryDomain {
    if !retryable {
        RetryDomain::None
    } else if endpoint.is_some_and(|value| value.direction == EndpointDirection::Destination) {
        RetryDomain::Destination
    } else {
        RetryDomain::Route
    }
}

fn classify_source_eos(
    endpoint_by_bin: &HashMap<String, EndpointDescriptor>,
    source: &gst::Element,
) -> Option<(EndpointDescriptor, ErrorCode, &'static str, bool, bool)> {
    // A route process builds exactly one source bin, so find is unambiguous.
    // Fail loudly in debug builds if a future multi source graph breaks that,
    // because map iteration order would then pick an arbitrary endpoint.
    debug_assert!(
        endpoint_by_bin
            .values()
            .filter(|endpoint| endpoint.direction == EndpointDirection::Source)
            .count()
            <= 1,
        "EOS attribution needs exactly one source endpoint"
    );

    endpoint_by_bin
        .values()
        .find(|endpoint| endpoint.direction == EndpointDirection::Source)
        .map(|endpoint| {
            let (code, detail, retryable, clean) = if endpoint.transport == Transport::Ndi {
                (
                    ErrorCode::NdiSourceEos,
                    "NDI source reached end of stream",
                    true,
                    false,
                )
            } else if endpoint.transport == Transport::Hls {
                match hls::eos_policy(source) {
                    Some(policy)
                        if !policy.live && policy.end_action == hydra_plan::HlsEndAction::Stop =>
                    {
                        (
                            ErrorCode::SourceEos,
                            "HLS VOD reached end of stream",
                            false,
                            true,
                        )
                    }
                    Some(_) => (
                        ErrorCode::SourceEos,
                        "Live HLS source reached end of stream",
                        true,
                        false,
                    ),
                    None => (
                        ErrorCode::SourceEos,
                        "HLS source reached end of stream",
                        true,
                        false,
                    ),
                }
            } else {
                (
                    ErrorCode::SourceEos,
                    "Live source reached end of stream",
                    true,
                    false,
                )
            };
            (endpoint.clone(), code, detail, retryable, clean)
        })
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Mutex;

    use super::*;
    use crate::adapters::ndi_source::{
        NDI_ERROR_DETAILS_NAME, NDI_ERROR_REASON_FIELD, NDI_RECEIVE_TIMEOUT_REASON,
        NDI_REQUIRED_VIDEO_REASON,
    };

    fn classify_message(
        message: &gst::Message,
        endpoint: Option<&EndpointDescriptor>,
        route_playing: bool,
    ) -> ErrorClassification {
        match message.view() {
            gst::MessageView::Error(error_message) => {
                classify_error_message(error_message, endpoint, route_playing)
            }
            _ => panic!("expected error message"),
        }
    }

    #[test]
    fn typed_error_mapping_never_depends_on_message_text() {
        let cases = [
            (
                TypedGstError::Resource(gst::ResourceError::Read),
                ErrorCode::RuntimeError,
                true,
            ),
            (
                // NotAuthorized never actually occurs for SRT (see
                // `classify_srt_auth_failure`'s doc comment); it stays in the generic
                // bucket so it cannot mislabel some other, non-SRT element that does
                // post it.
                TypedGstError::Resource(gst::ResourceError::NotAuthorized),
                ErrorCode::RuntimeError,
                true,
            ),
            (
                TypedGstError::Core(gst::CoreError::Negotiation),
                ErrorCode::NegotiationFailed,
                false,
            ),
            (
                TypedGstError::Core(gst::CoreError::MissingPlugin),
                ErrorCode::ElementMissing,
                false,
            ),
            (
                TypedGstError::Stream(gst::StreamError::Format),
                ErrorCode::NegotiationFailed,
                false,
            ),
            (TypedGstError::Other, ErrorCode::RuntimeError, true),
        ];

        for (input, code, retryable) in cases {
            assert_eq!(
                classify_typed_error(input),
                ErrorClassification { code, retryable }
            );
        }
    }

    #[test]
    fn ndi_source_resource_error_without_adapter_details_is_runtime_error() {
        assert_eq!(classify_readiness_details(None), None);
        assert_eq!(
            classify_typed_error(TypedGstError::Resource(gst::ResourceError::Read)),
            ErrorClassification {
                code: ErrorCode::RuntimeError,
                retryable: true,
            }
        );
    }

    #[test]
    fn ndi_source_receive_timeout_requires_adapter_details_discriminator() {
        let details = gst::Structure::builder(NDI_ERROR_DETAILS_NAME)
            .field(NDI_ERROR_REASON_FIELD, NDI_RECEIVE_TIMEOUT_REASON)
            .build();
        assert_eq!(
            classify_readiness_details(Some(details.as_ref())),
            Some(ErrorCode::NdiReceiveTimeout)
        );

        let required_video = gst::Structure::builder(NDI_ERROR_DETAILS_NAME)
            .field(NDI_ERROR_REASON_FIELD, NDI_REQUIRED_VIDEO_REASON)
            .build();
        assert_eq!(
            classify_readiness_details(Some(required_video.as_ref())),
            Some(ErrorCode::NdiRequiredVideoMissing)
        );

        let unrelated = gst::Structure::builder("other-error").build();
        assert_eq!(classify_readiness_details(Some(unrelated.as_ref())), None);
    }

    fn srt_endpoint() -> EndpointDescriptor {
        EndpointDescriptor {
            bin_name: "source_a".to_string(),
            endpoint_id: "a".to_string(),
            direction: EndpointDirection::Source,
            transport: Transport::Srt,
        }
    }

    fn non_srt_endpoint() -> EndpointDescriptor {
        EndpointDescriptor {
            bin_name: "dest_0_a".to_string(),
            endpoint_id: "a".to_string(),
            direction: EndpointDirection::Destination,
            transport: Transport::Rtmp,
        }
    }

    #[test]
    fn srt_auth_failure_is_detected_from_the_real_gstreamer_error_shape() {
        // This is the exact shape captured from a real wrong-passphrase SRT session:
        // GST_RESOURCE_ERROR_READ with the SRT library's own rejection text folded
        // into the debug string, not a `NotAuthorized` GError.
        let error = glib::Error::new(gst::ResourceError::Read, "Could not read from resource.");
        let debug = "../subprojects/gst-plugins-bad/ext/srt/gstsrtsrc.c(206): gst_srt_src_fill (): /GstPipeline:pipeline0/GstSRTSrc:srtsrc0:\nFailed to authenticate: Incorrect passphrase (10)";

        let classification = classify_srt_auth_failure(&error, Some(debug), Some(&srt_endpoint()))
            .expect("must classify as an SRT auth failure");
        assert_eq!(classification.code, ErrorCode::SrtAuthFailed);
        assert!(
            classification.retryable,
            "a wrong passphrase can be fixed on the far side without touching this route"
        );
    }

    #[test]
    fn srt_auth_failure_never_fires_for_a_non_srt_endpoint() {
        // The exact same text on a non-SRT endpoint (e.g. some other element that
        // happens to raise RESOURCE_ERROR_READ) must never be relabeled SRT_AUTH_FAILED.
        let error = glib::Error::new(gst::ResourceError::Read, "Could not read from resource.");
        let debug = "Failed to authenticate: Incorrect passphrase (10)";
        assert_eq!(
            classify_srt_auth_failure(&error, Some(debug), Some(&non_srt_endpoint())),
            None
        );
        assert_eq!(classify_srt_auth_failure(&error, Some(debug), None), None);
    }

    #[test]
    fn srt_auth_failure_never_fires_without_the_auth_text() {
        // A generic dead-port RESOURCE_ERROR_READ on an SRT endpoint (no auth text in
        // the debug string) must keep falling through to the generic classification.
        let error = glib::Error::new(gst::ResourceError::Read, "Could not read from resource.");
        assert_eq!(
            classify_srt_auth_failure(&error, None, Some(&srt_endpoint())),
            None
        );
        assert_eq!(
            classify_srt_auth_failure(&error, Some("Connection timed out"), Some(&srt_endpoint())),
            None
        );
    }

    #[test]
    fn srt_auth_failure_never_fires_for_the_second_basesrc_error_message() {
        // The same wrong-passphrase session posts a *second* bus error right after the
        // first: basesrc's generic "Internal data stream error." (GST_STREAM_ERROR,
        // not GST_RESOURCE_ERROR). Even if its debug string happened to still mention
        // the auth text (it does not, in practice - shown here as the stricter case),
        // the domain gate must keep it out of SRT_AUTH_FAILED.
        let error = glib::Error::new(gst::StreamError::Failed, "Internal data stream error.");
        let debug = "Failed to authenticate: Incorrect passphrase (10)";
        assert_eq!(
            classify_srt_auth_failure(&error, Some(debug), Some(&srt_endpoint())),
            None
        );
    }

    #[test]
    fn retry_domain_tracks_attributed_endpoint_direction() {
        let source = EndpointDescriptor {
            bin_name: "source_a".to_string(),
            endpoint_id: "a".to_string(),
            direction: EndpointDirection::Source,
            transport: Transport::Srt,
        };
        let destination = EndpointDescriptor {
            bin_name: "dest_b".to_string(),
            endpoint_id: "b".to_string(),
            direction: EndpointDirection::Destination,
            transport: Transport::Udp,
        };
        assert_eq!(retry_domain(true, Some(&source)), RetryDomain::Route);
        assert_eq!(
            retry_domain(true, Some(&destination)),
            RetryDomain::Destination
        );
        assert_eq!(retry_domain(false, Some(&destination)), RetryDomain::None);
    }

    #[test]
    fn source_eos_classification_makes_srt_retryable_on_the_route_domain() {
        let _ = gst::init();
        let endpoint = srt_endpoint();
        let endpoints = HashMap::from([(endpoint.bin_name.clone(), endpoint.clone())]);
        let source = gst::ElementFactory::make("identity")
            .build()
            .expect("source");

        let (_, code, detail, retryable, clean) =
            classify_source_eos(&endpoints, &source).expect("source endpoint");

        assert_eq!(code, ErrorCode::SourceEos);
        assert_eq!(detail, "Live source reached end of stream");
        assert!(retryable);
        assert!(!clean);
        assert_eq!(retry_domain(retryable, Some(&endpoint)), RetryDomain::Route);
    }

    #[test]
    fn source_eos_without_a_source_endpoint_stays_unattributed() {
        let destination = non_srt_endpoint();
        let endpoints = HashMap::from([(destination.bin_name.clone(), destination)]);

        let _ = gst::init();
        let source = gst::ElementFactory::make("identity")
            .build()
            .expect("source");
        assert_eq!(classify_source_eos(&endpoints, &source), None);
    }

    #[test]
    fn ndi_source_eos_keeps_its_existing_code_and_detail() {
        let _ = gst::init();
        let endpoint = EndpointDescriptor {
            bin_name: "source_ndi".to_string(),
            endpoint_id: "ndi-source".to_string(),
            direction: EndpointDirection::Source,
            transport: Transport::Ndi,
        };
        let endpoints = HashMap::from([(endpoint.bin_name.clone(), endpoint)]);

        let source = gst::ElementFactory::make("identity")
            .build()
            .expect("source");
        let (_, code, detail, retryable, clean) =
            classify_source_eos(&endpoints, &source).expect("source endpoint");

        assert_eq!(code, ErrorCode::NdiSourceEos);
        assert_eq!(detail, "NDI source reached end of stream");
        assert!(retryable);
        assert!(!clean);
    }

    #[test]
    fn hls_vod_eos_is_a_clean_terminal_success() {
        let _ = gst::init();
        let endpoint = EndpointDescriptor {
            bin_name: "source_hls".to_string(),
            endpoint_id: "hls-source".to_string(),
            direction: EndpointDirection::Source,
            transport: Transport::Hls,
        };
        let endpoints = HashMap::from([(endpoint.bin_name.clone(), endpoint)]);
        let source = gst::ElementFactory::make("identity")
            .build()
            .expect("source");
        let config = hydra_plan::HlsSource::new(
            hydra_plan::HlsUri::new("http://127.0.0.1:4567/playlist.m3u8").expect("uri"),
            false,
            None,
            hydra_plan::HlsEndAction::Stop,
        );
        hls::set_eos_policy(&source, &config);

        let (_, code, detail, retryable, clean) =
            classify_source_eos(&endpoints, &source).expect("source endpoint");
        assert_eq!(code, ErrorCode::SourceEos);
        assert_eq!(detail, "HLS VOD reached end of stream");
        assert!(!retryable);
        assert!(clean);
    }

    #[test]
    fn hls_live_eos_remains_retryable() {
        let _ = gst::init();
        let endpoint = EndpointDescriptor {
            bin_name: "source_hls".to_string(),
            endpoint_id: "hls-source".to_string(),
            direction: EndpointDirection::Source,
            transport: Transport::Hls,
        };
        let endpoints = HashMap::from([(endpoint.bin_name.clone(), endpoint)]);
        let source = gst::ElementFactory::make("identity")
            .build()
            .expect("source");
        let config = hydra_plan::HlsSource::new(
            hydra_plan::HlsUri::new("http://127.0.0.1:4567/playlist.m3u8").expect("uri"),
            true,
            None,
            hydra_plan::HlsEndAction::Stop,
        );
        hls::set_eos_policy(&source, &config);

        let (_, _, _, retryable, clean) =
            classify_source_eos(&endpoints, &source).expect("source endpoint");
        assert!(retryable);
        assert!(!clean);
    }

    #[test]
    fn hls_vod_hold_and_loop_eos_remain_retryable_until_supported() {
        let _ = gst::init();
        for end_action in [
            hydra_plan::HlsEndAction::Hold,
            hydra_plan::HlsEndAction::Loop,
        ] {
            let endpoint = EndpointDescriptor {
                bin_name: "source_hls".to_string(),
                endpoint_id: "hls-source".to_string(),
                direction: EndpointDirection::Source,
                transport: Transport::Hls,
            };
            let endpoints = HashMap::from([(endpoint.bin_name.clone(), endpoint)]);
            let source = gst::ElementFactory::make("identity")
                .build()
                .expect("source");
            let config = hydra_plan::HlsSource::new(
                hydra_plan::HlsUri::new("http://127.0.0.1:4567/playlist.m3u8").expect("uri"),
                false,
                None,
                end_action,
            );
            hls::set_eos_policy(&source, &config);

            let (_, code, detail, retryable, clean) =
                classify_source_eos(&endpoints, &source).expect("source endpoint");
            assert_eq!(code, ErrorCode::SourceEos);
            assert_eq!(detail, "Live HLS source reached end of stream");
            assert!(retryable);
            assert!(!clean);
        }
    }

    #[test]
    fn hls_access_failures_have_a_distinct_diagnostic_classification() {
        assert!(hls_access_denied(
            "HTTP 403 Forbidden while fetching segment"
        ));
        assert!(hls_access_denied("resource was not authorized"));
        assert!(hls_access_denied(
            "HTTP 401 UNAUTHORIZED while fetching playlist"
        ));
        assert!(!hls_access_denied(
            "HTTP 404 Not Found while fetching segment"
        ));
        assert!(!hls_access_denied("connection timed out"));
    }

    #[test]
    fn error_message_classification_prefers_adapter_details_over_gstreamer_fallback() {
        let details = gst::Structure::builder(NDI_ERROR_DETAILS_NAME)
            .field(NDI_ERROR_REASON_FIELD, NDI_RECEIVE_TIMEOUT_REASON)
            .build();
        let error = glib::Error::new(gst::CoreError::Negotiation, "negotiation failed");
        let message = gst::message::Error::builder_from_error(error)
            .details(details)
            .build();

        assert_eq!(
            classify_message(&message, None, false),
            ErrorClassification {
                code: ErrorCode::NdiReceiveTimeout,
                retryable: true,
            }
        );
    }

    #[test]
    fn hls_negotiation_failures_are_retryable_but_generic_negotiation_is_not() {
        let error = glib::Error::new(gst::CoreError::Negotiation, "negotiation failed");
        let message = gst::message::Error::builder_from_error(error).build();
        let hls_endpoint = EndpointDescriptor {
            bin_name: "source_hls".to_string(),
            endpoint_id: "hls-source".to_string(),
            direction: EndpointDirection::Source,
            transport: Transport::Hls,
        };
        let rtmp_endpoint = EndpointDescriptor {
            bin_name: "source_rtmp".to_string(),
            endpoint_id: "rtmp-source".to_string(),
            direction: EndpointDirection::Source,
            transport: Transport::Rtmp,
        };

        assert_eq!(
            classify_message(&message, Some(&hls_endpoint), false),
            ErrorClassification {
                code: ErrorCode::NegotiationFailed,
                retryable: true,
            }
        );
        assert_eq!(
            classify_message(&message, Some(&rtmp_endpoint), false),
            ErrorClassification {
                code: ErrorCode::NegotiationFailed,
                retryable: false,
            }
        );
        assert_eq!(
            classify_message(&message, None, false),
            ErrorClassification {
                code: ErrorCode::NegotiationFailed,
                retryable: false,
            }
        );
    }

    #[test]
    fn ndi_destination_failure_before_route_playing_is_sender_start_failure() {
        let endpoint = EndpointDescriptor {
            bin_name: "dest_0_ndi".to_string(),
            endpoint_id: "ndi-output".to_string(),
            direction: EndpointDirection::Destination,
            transport: Transport::Ndi,
        };
        assert_eq!(
            classify_ndi_sender_start_failure(Some(&endpoint), false),
            Some(ErrorClassification {
                code: ErrorCode::NdiSenderStartFailed,
                retryable: true,
            })
        );
        assert_eq!(
            retry_domain(true, Some(&endpoint)),
            RetryDomain::Destination
        );
        assert_eq!(
            classify_ndi_sender_start_failure(Some(&endpoint), true),
            None
        );
    }

    #[test]
    fn attribution_walks_from_message_source_to_nearest_endpoint_bin() {
        let _ = gst::init();
        let bin = gst::Bin::with_name("dest_sanitized_id");
        let child = gst::ElementFactory::make("identity")
            .build()
            .expect("identity element");
        bin.add(&child).expect("child in bin");
        let descriptor = EndpointDescriptor {
            bin_name: bin.name().to_string(),
            endpoint_id: "original-id".to_string(),
            direction: EndpointDirection::Destination,
            transport: Transport::Srt,
        };
        let endpoints = HashMap::from([(descriptor.bin_name.clone(), descriptor.clone())]);

        assert_eq!(
            nearest_endpoint(Some(child.upcast_ref()), &endpoints),
            Some(descriptor)
        );
    }

    #[test]
    fn attribution_distinguishes_ids_with_the_same_sanitized_suffix() {
        let _ = gst::init();
        let first_bin = gst::Bin::with_name("dest_0_a_b");
        let second_bin = gst::Bin::with_name("dest_1_a_b");
        let first_child = gst::ElementFactory::make("identity")
            .build()
            .expect("first child");
        let second_child = gst::ElementFactory::make("identity")
            .build()
            .expect("second child");
        first_bin.add(&first_child).expect("first bin child");
        second_bin.add(&second_child).expect("second bin child");
        let first = EndpointDescriptor {
            bin_name: first_bin.name().to_string(),
            endpoint_id: "a-b".to_string(),
            direction: EndpointDirection::Destination,
            transport: Transport::Srt,
        };
        let second = EndpointDescriptor {
            bin_name: second_bin.name().to_string(),
            endpoint_id: "a_b".to_string(),
            direction: EndpointDirection::Destination,
            transport: Transport::Srt,
        };
        let endpoints = HashMap::from([
            (first.bin_name.clone(), first.clone()),
            (second.bin_name.clone(), second.clone()),
        ]);

        assert_eq!(
            nearest_endpoint(Some(first_child.upcast_ref()), &endpoints),
            Some(first)
        );
        assert_eq!(
            nearest_endpoint(Some(second_child.upcast_ref()), &endpoints),
            Some(second)
        );
    }

    #[test]
    fn srt_wrong_passphrase_typed_error_alone_is_not_enough_to_classify() {
        // TypedGstError::Resource(NotAuthorized) carries no endpoint/debug-text context
        // any more, so on its own it is indistinguishable from any other resource
        // error - which is correct, since GStreamer's SRT plugin never actually raises
        // NotAuthorized for a wrong passphrase in practice (see
        // `classify_srt_auth_failure`, which is where the real detection lives).
        assert_eq!(
            classify_typed_error(TypedGstError::Resource(gst::ResourceError::NotAuthorized)),
            ErrorClassification {
                code: ErrorCode::RuntimeError,
                retryable: true,
            }
        );
    }

    #[test]
    fn other_resource_errors_keep_the_generic_retryable_runtime_error_behaviour() {
        for variant in [
            gst::ResourceError::Read,
            gst::ResourceError::OpenRead,
            gst::ResourceError::NotFound,
            gst::ResourceError::Busy,
            gst::ResourceError::NotAuthorized,
        ] {
            assert_eq!(
                classify_typed_error(TypedGstError::Resource(variant)),
                ErrorClassification {
                    code: ErrorCode::RuntimeError,
                    retryable: true,
                },
                "resource error variant {variant:?} should stay a generic runtime error"
            );
        }
    }

    #[test]
    fn format_gst_bus_message_appends_debug_string_when_present() {
        let error = glib::Error::new(gst::ResourceError::NotAuthorized, "Incorrect passphrase");
        assert_eq!(
            format_gst_bus_message(&error, Some("gstsrtsrc.c:206:gst_srt_src_fill")),
            "Incorrect passphrase | debug: gstsrtsrc.c:206:gst_srt_src_fill"
        );
    }

    #[test]
    fn format_gst_bus_message_omits_debug_suffix_when_absent() {
        let error = glib::Error::new(gst::ResourceError::NotAuthorized, "Incorrect passphrase");
        assert_eq!(format_gst_bus_message(&error, None), "Incorrect passphrase");
        assert_eq!(
            format_gst_bus_message(&error, Some("")),
            "Incorrect passphrase"
        );
    }

    struct MemoryWriter(Arc<Mutex<Vec<String>>>);

    impl crate::output::StatsWriter for MemoryWriter {
        fn send_message(&mut self, message: &str) -> anyhow::Result<()> {
            self.0
                .lock()
                .expect("messages lock")
                .push(message.to_string());
            Ok(())
        }
    }

    fn pump_until<F: Fn() -> bool>(condition: F) {
        let context = glib::MainContext::default();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !condition() && std::time::Instant::now() < deadline {
            context.iteration(true);
        }
        assert!(condition(), "timed out waiting for the bus watch to run");
    }

    fn pipeline_log_events(messages: &Mutex<Vec<String>>) -> Vec<serde_json::Value> {
        messages
            .lock()
            .expect("messages lock")
            .iter()
            .map(|raw| serde_json::from_str::<serde_json::Value>(raw).expect("valid json"))
            .filter(|value| value["event"] == "pipeline_log")
            .collect()
    }

    #[test]
    fn bus_error_and_warning_each_produce_a_well_formed_pipeline_log_event() {
        use crate::events::RouteIdentity;
        use crate::lifecycle::PipelineLifecycleEmitter;
        use std::sync::atomic::AtomicU64;

        let _ = gst::init();

        let pipeline = gst::Pipeline::new();
        let source = gst::ElementFactory::make("identity")
            .name("source_test")
            .build()
            .expect("identity element");
        pipeline.add(&source).expect("add source to pipeline");

        let messages: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let writer: Arc<Mutex<Box<dyn crate::output::StatsWriter>>> =
            Arc::new(Mutex::new(Box::new(MemoryWriter(messages.clone()))));
        let identity = RouteIdentity {
            route_id: "route-1".to_string(),
            config_revision: "rev-1".to_string(),
            process_instance_id: "proc-1".to_string(),
        };
        let event_sink = EventSink::new(writer.clone(), identity);

        let runtime = PipelineRuntime {
            pipeline: pipeline.clone(),
            loop_: glib::MainLoop::new(None, false),
            source: source.clone(),
            lifecycle: PipelineLifecycleEmitter::new(writer.clone()),
            source_bytes_total: Arc::new(AtomicU64::new(0)),
            source_bytes_last_interval: Arc::new(AtomicU64::new(0)),
            source_bytes_per_sec: Arc::new(AtomicU64::new(0)),
            processing_pending: Arc::new(AtomicBool::new(false)),
            dest_metrics: Arc::new(Mutex::new(Vec::new())),
            running: Arc::new(AtomicBool::new(false)),
        };
        let eos_seen = Arc::new(AtomicBool::new(false));
        let _guard =
            attach_bus_watch(&runtime, event_sink, &[], eos_seen).expect("attach bus watch");
        let bus = pipeline.bus().expect("pipeline bus");

        // Warning: must produce a WARN pipeline_log carrying the element name and the
        // combined error+debug text, and must NOT be the only side effect - no
        // endpoint/route lifecycle events should accompany it.
        let warning_error = glib::Error::new(gst::ResourceError::Read, "warning happened");
        let warning_msg = gst::message::Warning::builder_from_error(warning_error)
            .src(&source)
            .debug("warn debug detail")
            .build();
        bus.post(warning_msg).expect("post warning message");
        pump_until(|| !pipeline_log_events(&messages).is_empty());

        let warning_events = pipeline_log_events(&messages);
        assert_eq!(warning_events.len(), 1);
        let warning_event = &warning_events[0];
        assert_eq!(warning_event["level"], "WARN");
        assert_eq!(warning_event["category"], "gst_bus");
        assert_eq!(warning_event["element"], "source_test");
        assert_eq!(
            warning_event["message"],
            "warning happened | debug: warn debug detail"
        );
        assert!(
            messages
                .lock()
                .expect("messages lock")
                .iter()
                .all(|raw| !raw.contains("\"event\":\"route_terminal\"")),
            "a Warning must not trigger route_terminal"
        );

        // Error: must produce an ERROR pipeline_log alongside the existing
        // endpoint_health/route_terminal events, carrying the auth-failure text.
        let auth_error = glib::Error::new(
            gst::ResourceError::NotAuthorized,
            "Failed to authenticate: Incorrect passphrase (10)",
        );
        let error_msg = gst::message::Error::builder_from_error(auth_error)
            .src(&source)
            .debug("gstsrtsrc.c:206:gst_srt_src_fill")
            .build();
        bus.post(error_msg).expect("post error message");
        pump_until(|| pipeline_log_events(&messages).len() >= 2);

        let all_events = pipeline_log_events(&messages);
        let error_event = &all_events[1];
        assert_eq!(error_event["level"], "ERROR");
        assert_eq!(error_event["category"], "gst_bus");
        assert_eq!(error_event["element"], "source_test");
        assert_eq!(
            error_event["message"],
            "Failed to authenticate: Incorrect passphrase (10) | debug: gstsrtsrc.c:206:gst_srt_src_fill"
        );
        assert!(
            messages
                .lock()
                .expect("messages lock")
                .iter()
                .any(|raw| raw.contains("\"event\":\"route_terminal\"")),
            "an Error must still trigger route_terminal"
        );
    }

    #[test]
    fn real_wrong_passphrase_bus_error_shape_classifies_as_srt_auth_failed_end_to_end() {
        use crate::events::RouteIdentity;
        use crate::lifecycle::PipelineLifecycleEmitter;
        use std::sync::atomic::AtomicU64;

        let _ = gst::init();

        // Named "source_srtsrc0" up front (rather than the default auto-generated
        // name) so it matches the endpoint's bin_name below the way a real pipeline's
        // "source_<sanitized endpoint id>" bin would.
        let pipeline = gst::Pipeline::builder().name("source_srtsrc0").build();
        let source = gst::ElementFactory::make("identity")
            .name("srtsrc0")
            .build()
            .expect("identity element");
        pipeline.add(&source).expect("add source to pipeline");

        let messages: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let writer: Arc<Mutex<Box<dyn crate::output::StatsWriter>>> =
            Arc::new(Mutex::new(Box::new(MemoryWriter(messages.clone()))));
        let identity = RouteIdentity {
            route_id: "route-1".to_string(),
            config_revision: "rev-1".to_string(),
            process_instance_id: "proc-1".to_string(),
        };
        let event_sink = EventSink::new(writer.clone(), identity);

        let runtime = PipelineRuntime {
            pipeline: pipeline.clone(),
            loop_: glib::MainLoop::new(None, false),
            source: source.clone(),
            lifecycle: PipelineLifecycleEmitter::new(writer.clone()),
            source_bytes_total: Arc::new(AtomicU64::new(0)),
            source_bytes_last_interval: Arc::new(AtomicU64::new(0)),
            source_bytes_per_sec: Arc::new(AtomicU64::new(0)),
            processing_pending: Arc::new(AtomicBool::new(false)),
            dest_metrics: Arc::new(Mutex::new(Vec::new())),
            running: Arc::new(AtomicBool::new(false)),
        };
        let eos_seen = Arc::new(AtomicBool::new(false));
        let endpoints = [EndpointDescriptor {
            bin_name: "source_srtsrc0".to_string(),
            endpoint_id: "srt-source-1".to_string(),
            direction: EndpointDirection::Source,
            transport: Transport::Srt,
        }];
        // `nearest_endpoint` attributes a bus message by walking from its source object
        // up through parents looking for a "source_"/"dest_"-named bin; the pipeline
        // object (renamed above) stands in for that bin here and is used directly as
        // the message source, so it matches on the first step of that walk.
        let _guard =
            attach_bus_watch(&runtime, event_sink, &endpoints, eos_seen).expect("attach bus watch");
        let bus = pipeline.bus().expect("pipeline bus");

        // Byte-for-byte the shape captured from a real wrong-passphrase SRT session
        // (GST_RESOURCE_ERROR_READ, auth text folded into the debug string).
        let auth_error =
            glib::Error::new(gst::ResourceError::Read, "Could not read from resource.");
        let error_msg = gst::message::Error::builder_from_error(auth_error)
            .src(&pipeline)
            .debug(
                "../subprojects/gst-plugins-bad/ext/srt/gstsrtsrc.c(206): gst_srt_src_fill (): \
                 /GstPipeline:pipeline0/GstSRTSrc:srtsrc0:\nFailed to authenticate: Incorrect \
                 passphrase (10)",
            )
            .build();
        bus.post(error_msg).expect("post error message");
        pump_until(|| {
            messages
                .lock()
                .expect("messages lock")
                .iter()
                .any(|raw| raw.contains("\"event\":\"route_terminal\""))
        });

        let terminal = messages
            .lock()
            .expect("messages lock")
            .iter()
            .map(|raw| serde_json::from_str::<serde_json::Value>(raw).expect("valid json"))
            .find(|value| value["event"] == "route_terminal")
            .expect("route_terminal must have been emitted");
        assert_eq!(terminal["reason_code"], "SRT_AUTH_FAILED");
        assert_eq!(terminal["retryable"], true);

        let endpoint_health = messages
            .lock()
            .expect("messages lock")
            .iter()
            .map(|raw| serde_json::from_str::<serde_json::Value>(raw).expect("valid json"))
            .find(|value| value["event"] == "endpoint_health")
            .expect("endpoint_health must have been emitted");
        assert_eq!(endpoint_health["reason_code"], "SRT_AUTH_FAILED");
        assert_eq!(endpoint_health["retryable"], true);
    }
}
