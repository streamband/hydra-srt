import type { BaseTransportOptions, Envelope, Transport, TransportMakeRequestResponse } from '@sentry/core';
import { getToken } from '../utils/auth';

export type FetchLike = typeof fetch;

export const createAuthenticatedTransport = (
  options: BaseTransportOptions,
  fetchImpl: FetchLike = fetch,
): Transport => {
  void options;

  return {
    send: async (envelope: Envelope): Promise<TransportMakeRequestResponse> => {
      const token = getToken();
      if (!token) {
        return { statusCode: 204 };
      }

      const { serializeEnvelope } = await import('@sentry/core');
      const serialized = serializeEnvelope(envelope);
      const body = typeof serialized === 'string' ? serialized : new TextDecoder().decode(serialized);
      const response = await fetchImpl('/api/telemetry/envelope', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/x-sentry-envelope',
        },
        body,
        credentials: 'same-origin',
      });

      return { statusCode: response.status };
    },
    flush: async (): Promise<boolean> => true,
  };
};

export const authenticatedTransport = (options: BaseTransportOptions): Transport =>
  createAuthenticatedTransport(options);
