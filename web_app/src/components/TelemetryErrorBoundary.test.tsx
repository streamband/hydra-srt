import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { setToken } from '../utils/auth';
import { TelemetryFallback, buildDiagnosticReport, initializeSentry } from './TelemetryErrorBoundary';

vi.mock('@sentry/react', () => ({
  ErrorBoundary: () => null,
  init: vi.fn(),
}));

vi.mock('../context/InitContext', () => ({
  useInit: () => ({ version: '0.6.9' }),
}));

describe('TelemetryFallback', () => {
  beforeEach(() => {
    const values = new Map<string, string>();
    Object.defineProperty(globalThis, 'localStorage', {
      configurable: true,
      value: {
        getItem: (key: string) => values.get(key) ?? null,
        setItem: (key: string, value: string) => values.set(key, value),
        removeItem: (key: string) => values.delete(key),
      },
    });
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { writeText: vi.fn().mockResolvedValue(undefined) },
    });
  });

  it('initializes only with a session token and filters request-bearing integrations', async () => {
    const Sentry = await import('@sentry/react');
    setToken('session-token');

    await initializeSentry('https://public@example.invalid/1', '0.6.9');

    expect(Sentry.init).toHaveBeenCalledWith(expect.objectContaining({
      dsn: 'https://public@example.invalid/1',
      release: 'hydra-srt@0.6.9',
      environment: 'production',
      sendDefaultPii: false,
      tracesSampleRate: 0,
      maxBreadcrumbs: 0,
    }));

    const options = vi.mocked(Sentry.init).mock.calls[0]?.[0];
    const filterIntegrations = options?.integrations as unknown as (integrations: Array<{ name: string }>) => Array<{ name: string }>;
    expect(filterIntegrations([
      { name: 'GlobalHandlers' },
      { name: 'Breadcrumbs' },
      { name: 'HttpContext' },
    ])).toEqual([{ name: 'GlobalHandlers' }]);
  });

  it('renders copy and reload controls with pathname-only diagnostics', async () => {
    window.history.replaceState({}, '', '/routes?secret=private#details');
    render(<TelemetryFallback error={new Error('streamid=private')} />);

    expect(screen.getByText('Application error')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Copy diagnostic report' }));
    expect(screen.getByRole('button', { name: 'Reload' })).toBeInTheDocument();

    const report = buildDiagnosticReport('0.6.9', new Error('message'), 'at App');
    expect(report).toContain('pathname: /routes');
    expect(report).not.toContain('secret=private');
    expect(report).not.toContain('#details');
    expect(report).not.toContain('streamid=private');
  });
});
