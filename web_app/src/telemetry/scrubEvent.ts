import type { Event } from '@sentry/core';

const MAX_MESSAGE_LENGTH = 512;
const MAX_EXCEPTION_VALUES = 10;
const MAX_STACK_FRAMES = 30;
const MAX_EVENT_BYTES = 200_000;

const SECRET_PATTERN = /(?:passphrase|streamid|stream-key|token|bearer)=([^&\s,;]+)/gi;
const URL_PATTERN = /(?:https?|srt|udp|rtp|rtmp|ndi|hls):\/\/[^\s"'<>]+/gi;
const IPV4_PATTERN = /\b(?:\d{1,3}\.){3}\d{1,3}\b/g;
const IPV6_PATTERN = /(?<![a-z0-9])[0-9a-f]{0,4}(?::[0-9a-f]{0,4}){2,}(?![a-z0-9:])/gi;
const ABSOLUTE_PATH_PATTERN = /(?:[A-Z]:\\[^\s]+|\/(?:Users|home|tmp|app|var)\/[^\s]+)/gi;

export const scrubText = (value: unknown): string => {
  const text = typeof value === 'string' ? value : String(value ?? '');

  return text
    .replace(SECRET_PATTERN, '=REDACTED')
    .replace(URL_PATTERN, '[REDACTED_URL]')
    .replace(IPV4_PATTERN, '[REDACTED_IP]')
    .replace(IPV6_PATTERN, '[REDACTED_IP]')
    .replace(ABSOLUTE_PATH_PATTERN, '[REDACTED_PATH]')
    .slice(0, MAX_MESSAGE_LENGTH);
};

const scrubFilename = (value: unknown): string | undefined => {
  if (typeof value !== 'string') {
    return undefined;
  }

  const withoutQuery = value.split(/[?#]/, 1)[0];

  try {
    const parsed = new URL(withoutQuery);
    return parsed.pathname.split('/').filter(Boolean).slice(-2).join('/') || undefined;
  } catch {
    return withoutQuery.split(/[\\/]/).filter(Boolean).slice(-2).join('/') || undefined;
  }
};

const scrubStacktrace = (stacktrace: unknown): unknown => {
  if (!stacktrace || typeof stacktrace !== 'object') {
    return stacktrace;
  }

  const candidate = stacktrace as { frames?: unknown };
  if (!Array.isArray(candidate.frames)) {
    return stacktrace;
  }

  return {
    ...candidate,
    frames: candidate.frames.slice(0, MAX_STACK_FRAMES).map((frame) => {
      if (!frame || typeof frame !== 'object') {
        return null;
      }

      const current = frame as Record<string, unknown>;
      return {
        ...current,
        filename: scrubFilename(current.filename),
        function: scrubText(current.function),
      };
    }).filter(Boolean),
  };
};

const scrubException = (exception: unknown): unknown => {
  if (!exception || typeof exception !== 'object') {
    return null;
  }

  const current = exception as Record<string, unknown>;
  return {
    ...current,
    value: scrubText(current.value),
    stacktrace: scrubStacktrace(current.stacktrace),
  };
};

const scrubLogentry = (logentry: unknown): unknown => {
  if (typeof logentry === 'string') {
    return scrubText(logentry);
  }

  if (!logentry || typeof logentry !== 'object') {
    return undefined;
  }

  const current = logentry as Record<string, unknown>;
  return {
    ...current,
    message: scrubText(current.message),
    params: [],
  };
};

export const scrubEvent = (event: Event): Event | null => {
  if (!event || typeof event !== 'object') {
    return null;
  }

  try {
    if (new TextEncoder().encode(JSON.stringify(event)).byteLength > MAX_EVENT_BYTES) {
      return null;
    }
  } catch {
    return null;
  }

  let sanitized: Record<string, unknown>;
  try {
    sanitized = JSON.parse(JSON.stringify(event)) as Record<string, unknown>;
  } catch {
    return null;
  }

  if (!sanitized || typeof sanitized !== 'object') {
    return null;
  }

  const exception = sanitized.exception;
  if (exception && typeof exception === 'object') {
    const values = (exception as { values?: unknown }).values;
    sanitized.exception = {
      ...(exception as Record<string, unknown>),
      values: Array.isArray(values) ? values.slice(0, MAX_EXCEPTION_VALUES).map(scrubException).filter(Boolean) : [],
    };
  }

  if (sanitized.message && typeof sanitized.message === 'object') {
    const message = sanitized.message as Record<string, unknown>;
    sanitized.message = {
      ...message,
      message: scrubText(message.message),
      formatted: scrubText(message.formatted),
      params: [],
    };
  } else if (sanitized.message !== undefined) {
    sanitized.message = scrubText(sanitized.message);
  }

  if (sanitized.logentry !== undefined) {
    sanitized.logentry = scrubLogentry(sanitized.logentry);
  }

  delete sanitized.request;
  delete sanitized.user;
  delete sanitized.contexts;
  delete sanitized.extra;
  delete sanitized.breadcrumbs;
  delete sanitized.sdkProcessingMetadata;

  if (sanitized.tags && typeof sanitized.tags === 'object') {
    const tags = sanitized.tags as Record<string, unknown>;
    sanitized.tags = {
      ...(typeof tags.version === 'string' ? { version: scrubText(tags.version) } : {}),
      ...(typeof tags.component === 'string' ? { component: scrubText(tags.component) } : {}),
    };
  }

  try {
    if (new TextEncoder().encode(JSON.stringify(sanitized)).byteLength > MAX_EVENT_BYTES) {
      return null;
    }
  } catch {
    return null;
  }

  return sanitized as unknown as Event;
};
