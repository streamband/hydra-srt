import { Button, Result, Space, Typography } from 'antd';
import { Component, useEffect, useState } from 'react';
import type { ErrorInfo, ReactNode } from 'react';
import { useInit } from '../context/InitContext';
import { getToken } from '../utils/auth';
import { scrubEvent, scrubText } from '../telemetry/scrubEvent';
import { authenticatedTransport } from '../telemetry/transport';

type SentryReact = typeof import('@sentry/react');

export type DiagnosticError = {
  name?: string;
  message?: string;
  stack?: string;
};

export type TelemetryFallbackProps = {
  error?: unknown;
  componentStack?: string;
};

const errorDetails = (error: unknown): DiagnosticError => {
  if (error instanceof Error) {
    return { name: error.name, message: error.message, stack: error.stack };
  }

  if (error && typeof error === 'object') {
    const value = error as Record<string, unknown>;
    return {
      name: typeof value.name === 'string' ? value.name : undefined,
      message: typeof value.message === 'string' ? value.message : undefined,
      stack: typeof value.stack === 'string' ? value.stack : undefined,
    };
  }

  return { message: typeof error === 'string' ? error : 'Unknown application error' };
};

export const buildDiagnosticReport = (
  version: string,
  error: unknown,
  componentStack?: string,
): string => {
  const details = errorDetails(error);
  const lines = [
    'HydraSRT diagnostic report',
    `version: ${scrubText(version)}`,
    `time: ${new Date().toISOString()}`,
    `pathname: ${window.location.pathname}`,
    `error: ${scrubText(details.name || 'Error')}`,
    `message: ${scrubText(details.message || 'Unknown application error')}`,
  ];

  if (details.stack) {
    lines.push(`stack: ${scrubText(details.stack)}`);
  }

  if (componentStack) {
    lines.push(`component: ${scrubText(componentStack)}`);
  }

  return lines.join('\n');
};

export const TelemetryFallback = ({ error, componentStack }: TelemetryFallbackProps) => {
  const { version } = useInit();
  const [copied, setCopied] = useState(false);
  const report = buildDiagnosticReport(version, error, componentStack);

  const copyReport = async () => {
    try {
      await navigator.clipboard.writeText(report);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  };

  return (
    <Result
      status="error"
      title="Application error"
      subTitle="HydraSRT could not render this page."
      extra={(
        <Space>
          <Button onClick={copyReport}>{copied ? 'Copied' : 'Copy diagnostic report'}</Button>
          <Button type="primary" onClick={() => window.location.reload()}>Reload</Button>
        </Space>
      )}
    >
      <Typography.Text type="secondary">
        The diagnostic report contains only the app version, time, pathname, and error details.
      </Typography.Text>
    </Result>
  );
};

type LocalBoundaryState = { error: unknown; componentStack?: string };

export class LocalErrorBoundary extends Component<{ children: ReactNode }, LocalBoundaryState> {
  state: LocalBoundaryState = { error: null };

  static getDerivedStateFromError(error: unknown): LocalBoundaryState {
    return { error };
  }

  componentDidCatch(_error: unknown, info: ErrorInfo) {
    this.setState({ error: this.state.error, componentStack: info.componentStack || undefined });
  }

  render() {
    if (this.state.error) {
      return <TelemetryFallback error={this.state.error} componentStack={this.state.componentStack} />;
    }

    return this.props.children;
  }
}

let initializedDsn: string | null = null;
let initializedSentry: SentryReact | null = null;
let initializationPromise: Promise<SentryReact | null> | null = null;

export const initializeSentry = async (dsn: string | null, version: string): Promise<SentryReact | null> => {
  if (!dsn || !getToken()) {
    return null;
  }

  if (initializedDsn === dsn && initializedSentry) {
    return initializedSentry;
  }

  if (!initializationPromise) {
    initializationPromise = (async () => {
      const Sentry = await import('@sentry/react');
      if (!getToken()) {
        return null;
      }

      Sentry.init({
        dsn,
        release: `hydra-srt@${version}`,
        environment: 'production',
        sendDefaultPii: false,
        tracesSampleRate: 0,
        maxBreadcrumbs: 0,
        sendClientReports: false,
        ignoreErrors: [/AbortError/i, /NetworkError/i, /Failed to fetch/i, /Load failed/i, /ResizeObserver/i],
        integrations: (integrations) => integrations.filter(({ name }) =>
          !['Breadcrumbs', 'HttpContext', 'BrowserTracing', 'Replay', 'ReplayCanvas', 'Feedback', 'BrowserProfiling', 'BrowserSession', 'BrowserApiErrors'].includes(name),
        ),
        beforeSend: (event) => scrubEvent(event) as typeof event | null,
        transport: authenticatedTransport,
      });

      initializedDsn = dsn;
      initializedSentry = Sentry;
      return Sentry;
    })();
  }

  return initializationPromise;
};

export const TelemetryErrorBoundary = ({ children }: { children: ReactNode }) => {
  const init = useInit();
  const [sentry, setSentry] = useState<SentryReact | null>(null);

  useEffect(() => {
    if (!init.sentry_dsn || !getToken()) {
      return undefined;
    }

    let active = true;
    initializeSentry(init.sentry_dsn, init.version).then((module) => {
      if (active && module) {
        setSentry(module);
      }
    }).catch(() => undefined);

    return () => {
      active = false;
    };
  }, [init.sentry_dsn, init.version]);

  const SentryErrorBoundary = sentry?.ErrorBoundary;
  const content = SentryErrorBoundary ? (
    <SentryErrorBoundary fallback={TelemetryFallback}>
      {children}
    </SentryErrorBoundary>
  ) : children;

  return <LocalErrorBoundary>{content}</LocalErrorBoundary>;
};
