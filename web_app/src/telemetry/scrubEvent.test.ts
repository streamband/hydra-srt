import { describe, expect, it } from 'vitest';
import { scrubEvent, scrubText } from './scrubEvent';

describe('scrubText', () => {
  it('removes URLs, addresses, paths, and stream secrets', () => {
    const result = scrubText(
      'srt://host:9000?passphrase=secret&streamid=private 192.0.2.10 /home/alice/config.json',
    );

    expect(result).not.toContain('secret');
    expect(result).not.toContain('private');
    expect(result).not.toContain('192.0.2.10');
    expect(result).not.toContain('/home/alice');
    expect(result).toContain('[REDACTED_URL]');
  });
});

describe('scrubEvent', () => {
  it('removes request data and scrubs retained error fields', () => {
    const result = scrubEvent({
      event_id: 'event-id',
      request: { url: 'https://host/path?token=secret', headers: { Cookie: 'private' } },
      user: { username: 'admin' },
      contexts: { browser: { name: 'browser' } },
      extra: { route: 'private' },
      breadcrumbs: [{ message: 'private' }],
      exception: {
        values: [{
          type: 'Error',
          value: 'srt://host:9000?passphrase=secret',
          stacktrace: { frames: [{ filename: 'https://host/assets/app.js?secret=1', function: 'render' }] },
        }],
      },
      message: 'streamid=private',
      tags: { version: '0.6.9', component: 'web_ui', route: 'private' },
    });

    expect(result).not.toBeNull();
    expect(result).not.toHaveProperty('request');
    expect(result).not.toHaveProperty('user');
    expect(result).not.toHaveProperty('contexts');
    expect(result).not.toHaveProperty('extra');
    expect(result).not.toHaveProperty('breadcrumbs');
    expect(JSON.stringify(result)).not.toContain('secret');
    expect(JSON.stringify(result)).not.toContain('private');
    expect(JSON.stringify(result)).not.toContain('192.0.2.10');
    expect((result as Record<string, unknown>).tags).toEqual({ version: '0.6.9', component: 'web_ui' });
  });

  it('bounds values and rejects oversized events', () => {
    const result = scrubEvent({
      exception: {
        values: Array.from({ length: 20 }, () => ({ value: 'x'.repeat(2_000) })),
      },
      message: 'x'.repeat(2_000),
    });

    expect(result).not.toBeNull();
    expect((result as { exception: { values: unknown[] } }).exception.values).toHaveLength(10);
    expect((result as { message: string }).message).toHaveLength(512);
    expect(scrubEvent({ message: 'x'.repeat(201_000) })).toBeNull();
  });
});
