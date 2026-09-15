import { beforeEach, describe, expect, it, vi } from 'vitest';
import { setToken } from '../utils/auth';
import { createAuthenticatedTransport } from './transport';

vi.mock('@sentry/core', async () => {
  const actual = await vi.importActual<typeof import('@sentry/core')>('@sentry/core');
  return { ...actual, serializeEnvelope: vi.fn(() => '{"event_id":"event"}\n{"type":"event"}\n{}\n') };
});

describe('authenticated Sentry transport', () => {
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
    vi.restoreAllMocks();
  });

  it('posts an SDK envelope with the current bearer token', async () => {
    setToken('session-token');
    const fetchImpl = vi.fn().mockResolvedValue(new Response(null, { status: 204 }));
    const transport = createAuthenticatedTransport({} as never, fetchImpl);

    await transport.send([{}, []] as never);

    expect(fetchImpl).toHaveBeenCalledWith('/api/telemetry/envelope', expect.objectContaining({
      method: 'POST',
      headers: expect.objectContaining({ Authorization: 'Bearer session-token' }),
      body: expect.stringContaining('event_id'),
    }));
  });

  it('does not send when the session token is absent', async () => {
    const fetchImpl = vi.fn();
    const transport = createAuthenticatedTransport({} as never, fetchImpl);

    const response = await transport.send([{}, []] as never);

    expect(response.statusCode).toBe(204);
    expect(fetchImpl).not.toHaveBeenCalled();
  });
});
