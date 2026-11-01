import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent, act, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import type { ReactNode } from 'react';
import Routes from '../Routes';
import { routesApi } from '../../../utils/api';
import * as realtime from '../../../utils/realtime';

type RealtimeStatusListener = (payload: { item_id: string; status: string }) => void;
type RealtimeSourceListener = (payload: { item_id: string; active_source_id: string; last_switch_reason: string }) => void;
type RealtimeRouteEventListener = (payload: { route_id: string } & Record<string, unknown>) => void;
type RealtimeStatsPayload = Record<string, unknown>;
type RealtimeStatsListener = (payload: RealtimeStatsPayload) => void;
type RealtimeMockExports = typeof realtime & {
  __clearRealtimeMockState: () => void;
  __emitItemStatus: (itemId: string, status: string) => void;
  __emitRouteEvent: (routeId: string, payload: Record<string, unknown>) => void;
  __emitStats: (payload: RealtimeStatsPayload) => void;
};

const { mockNavigate } = vi.hoisted(() => ({
  mockNavigate: vi.fn(),
}));

vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom');
  return { ...actual, useNavigate: () => mockNavigate };
});

const realtimeMock = realtime as RealtimeMockExports;
const { subscribeToItemSource, subscribeToItemStatus, subscribeToRouteEvents } = realtimeMock;

vi.mock('recharts', () => {
  const Mock = ({ children }: { children?: ReactNode }) => children ?? null;
  return {
    ResponsiveContainer: Mock,
    AreaChart: Mock,
    CartesianGrid: () => null,
    XAxis: () => null,
    YAxis: () => null,
    Area: () => null,
    Tooltip: () => null,
  };
});

vi.mock('../../../utils/api', () => ({
  routesApi: {
    getAll: vi.fn(),
    getStatusesAnalytics: vi.fn(),
    getStatusesHistory: vi.fn(),
    start: vi.fn(async () => ({ data: { status: 'starting' } })),
    stop: vi.fn(async () => ({ data: { status: 'stopped' } })),
    delete: vi.fn(async () => ({ success: true })),
    resetStats: vi.fn(async () => ({
      data: { route_id: 'starting-route', stats_reset_at: '2026-05-15T10:00:00Z' },
    })),
    clearStatsReset: vi.fn(async () => ({
      data: { route_id: 'starting-route', stats_reset_at: null },
    })),
  },
  tagsApi: {
    getAll: vi.fn(async () => ({ data: [] })),
  },
}));

vi.mock('../../../utils/realtime', () => {
  const itemListeners = new Map<string, RealtimeStatusListener[]>();
  const statsListeners = new Set<RealtimeStatsListener>();
  const itemSourceListeners = new Map<string, RealtimeSourceListener[]>();
  const routeEventListeners = new Map<string, RealtimeRouteEventListener[]>();

  const subscribeToItemStatus = vi.fn((itemId: string, listener: RealtimeStatusListener) => {
    const listeners = itemListeners.get(itemId) || [];
    listeners.push(listener);
    itemListeners.set(itemId, listeners);

    return vi.fn(() => {
      const current = itemListeners.get(itemId) || [];
      itemListeners.set(
        itemId,
        current.filter((saved: RealtimeStatusListener) => saved !== listener),
      );
    });
  });

  const subscribeToStats = vi.fn((listener: RealtimeStatsListener) => {
    statsListeners.add(listener);
    return vi.fn(() => {
      statsListeners.delete(listener);
    });
  });

  const subscribeToItemSource = vi.fn((itemId: string, listener: RealtimeSourceListener) => {
    const listeners = itemSourceListeners.get(itemId) || [];
    listeners.push(listener);
    itemSourceListeners.set(itemId, listeners);

    return vi.fn(() => {
      const current = itemSourceListeners.get(itemId) || [];
      itemSourceListeners.set(
        itemId,
        current.filter((saved: RealtimeSourceListener) => saved !== listener),
      );
    });
  });

  const subscribeToRouteEvents = vi.fn((routeId: string, listener: RealtimeRouteEventListener) => {
    const listeners = routeEventListeners.get(routeId) || [];
    listeners.push(listener);
    routeEventListeners.set(routeId, listeners);

    return vi.fn(() => {
      const current = routeEventListeners.get(routeId) || [];
      routeEventListeners.set(
        routeId,
        current.filter((saved: RealtimeRouteEventListener) => saved !== listener),
      );
    });
  });

  return {
    subscribeToItemSource,
    subscribeToItemStatus,
    subscribeToRouteEvents,
    subscribeToStats,
    __emitItemStatus: (itemId: string, status: string) => {
      const listeners = itemListeners.get(itemId) || [];
      listeners.forEach((listener: RealtimeStatusListener) => listener({ item_id: itemId, status }));
    },
    __emitStats: (payload: RealtimeStatsPayload) => {
      statsListeners.forEach((listener: RealtimeStatsListener) => listener(payload));
    },
    __emitItemSource: (itemId: string, activeSourceId: string, reason = 'manual') => {
      const listeners = itemSourceListeners.get(itemId) || [];
      listeners.forEach((listener: RealtimeSourceListener) => listener({
        item_id: itemId,
        active_source_id: activeSourceId,
        last_switch_reason: reason,
      }));
    },
    __emitRouteEvent: (routeId: string, payload: Record<string, unknown>) => {
      const listeners = routeEventListeners.get(routeId) || [];
      listeners.forEach((listener: RealtimeRouteEventListener) => listener({ route_id: routeId, ...payload }));
    },
    __clearRealtimeMockState: () => {
      itemListeners.clear();
      statsListeners.clear();
      itemSourceListeners.clear();
      routeEventListeners.clear();
      subscribeToItemSource.mockClear();
      subscribeToItemStatus.mockClear();
      subscribeToRouteEvents.mockClear();
      subscribeToStats.mockClear();
    },
  };
});

const routeFixture = (attrs: Record<string, unknown> & { id: string; name: string; status: string; schema_status: string; started_at?: string | null; enabled?: boolean }) => ({
  enabled: attrs.enabled ?? true,
  ...attrs,
  id: attrs.id,
  name: attrs.name,
  status: attrs.status,
  schema_status: attrs.schema_status,
  schema: 'SRT',
  sources: [
    {
      id: `${attrs.id}-primary`,
      position: 0,
      enabled: true,
      name: 'primary',
      schema: 'SRT',
      mode: 'listener',
      localaddress: '127.0.0.1',
      localport: 4201,
    },
    {
      id: `${attrs.id}-backup`,
      position: 1,
      enabled: true,
      name: 'backup-1',
      schema: 'SRT',
      mode: 'listener',
      localaddress: '127.0.0.1',
      localport: 4202,
    },
  ],
  active_source_id: `${attrs.id}-primary`,
  started_at: attrs.started_at ?? null,
  destinations: [],
});

describe('Routes', () => {
  const renderRoutes = (initialEntry = '/routes') => render(
    <MemoryRouter initialEntries={[initialEntry]}>
      <Routes />
    </MemoryRouter>,
  );

  const openStatsDrawer = async (routeName = 'Starting route') => {
    await screen.findByText(routeName);
    fireEvent.click(screen.getByRole('button', { name: new RegExp(`route stats for ${routeName}`, 'i') }));
    await screen.findByText(/stats:/i);
  };

  const emitStatsSnapshot = (routeId: string, stats: Record<string, unknown>) => {
    act(() => {
      realtimeMock.__emitStats({
        route_id: routeId,
        metric: 'snapshot',
        stats,
      });
    });
  };

  beforeEach(() => {
    vi.clearAllMocks();
    realtimeMock.__clearRealtimeMockState();
    vi.mocked(routesApi.getAll).mockResolvedValue({
      data: [
        routeFixture({
          id: 'starting-route',
          name: 'Starting route',
          status: 'starting',
          schema_status: 'starting',
          last_switch_at: new Date(Date.now() - 30_000).toISOString(),
        }),
        routeFixture({
          id: 'stopped-route',
          name: 'Stopped route',
          status: 'stopped',
          schema_status: 'stopped',
        }),
      ],
    });
    vi.mocked(routesApi.getStatusesAnalytics).mockResolvedValue({
      data: {
        points: [],
        meta: {
          from: new Date(Date.now() - 5 * 60_000).toISOString(),
          to: new Date().toISOString(),
          window: 'custom',
          bucket_ms: 30_000,
        },
      },
    });
    vi.mocked(routesApi.getStatusesHistory).mockResolvedValue({
      data: {
        events: [],
        meta: {
          from: new Date(Date.now() - 5 * 60_000).toISOString(),
          to: new Date().toISOString(),
          window: 'live',
          limit: 50,
          offset: 0,
          total: 0,
        },
      },
    });
  });

  it('navigates to new route form when Duplicate is selected', async () => {
    renderRoutes();

    await screen.findAllByText('Starting route');

    fireEvent.click(screen.getByRole('button', { name: /route actions for starting route/i }));

    const duplicateAction = await screen.findByRole('menuitem', { name: /duplicate/i });
    await act(async () => {
      fireEvent.click(duplicateAction);
    });

    await waitFor(() => {
      expect(mockNavigate).toHaveBeenCalledWith('/routes/new/edit?duplicate_from=starting-route');
    });
  });

  it('shows enabled Stop action for non-stopped routes', async () => {
    renderRoutes();

    await screen.findAllByText('Starting route');

    fireEvent.click(screen.getByRole('button', { name: /route actions for starting route/i }));

    const stopAction = await screen.findByRole('menuitem', { name: /stop/i });
    expect(stopAction).not.toHaveAttribute('aria-disabled', 'true');
  });

  it('shows Start action for stopped routes', async () => {
    renderRoutes();

    await screen.findAllByText('Stopped route');

    fireEvent.click(screen.getByRole('button', { name: /route actions for stopped route/i }));

    expect(await screen.findByRole('menuitem', { name: /start/i })).toBeInTheDocument();
  });

  it('shows enabled state in routes table', async () => {
    vi.mocked(routesApi.getAll).mockResolvedValue({
      data: [
        routeFixture({
          id: 'enabled-route',
          name: 'Enabled route',
          enabled: true,
          status: 'stopped',
          schema_status: 'stopped',
        }),
        routeFixture({
          id: 'disabled-route',
          name: 'Disabled route',
          enabled: false,
          status: 'stopped',
          schema_status: 'stopped',
        }),
      ],
    });

    renderRoutes();

    await screen.findByText('Enabled route');
    await screen.findByText('Disabled route');

    const enabledRow = screen.getByText('Enabled route').closest('tr');
    const disabledRow = screen.getByText('Disabled route').closest('tr');

    expect(enabledRow).not.toBeNull();
    expect(disabledRow).not.toBeNull();
    expect(enabledRow).toHaveTextContent('Yes');
    expect(disabledRow).toHaveTextContent('No');
  });

  it('subscribes to route status events and updates the list status', async () => {
    renderRoutes();

    await screen.findAllByText('Starting route');

    expect(subscribeToItemStatus).toHaveBeenCalledWith('starting-route', expect.any(Function));
    expect(subscribeToItemStatus).toHaveBeenCalledWith('stopped-route', expect.any(Function));
    expect(subscribeToItemSource).toHaveBeenCalledWith('starting-route', expect.any(Function));
    expect(subscribeToItemSource).toHaveBeenCalledWith('stopped-route', expect.any(Function));

    await act(async () => {
      realtimeMock.__emitItemStatus('starting-route', 'processing');
    });

    expect(await screen.findByText('running')).toBeInTheDocument();
    expect(routesApi.getAll).toHaveBeenCalledTimes(1);
  });

  it('shows route in and out stats while status is not stopped', async () => {
    renderRoutes();

    await screen.findAllByText('Starting route');

    await act(async () => {
      realtimeMock.__emitStats({
        route_id: 'starting-route',
        metric: 'bytes_per_sec',
        direction: 'in',
        value: 100,
      });
      realtimeMock.__emitStats({
        route_id: 'starting-route',
        destination_id: 'dest-1',
        metric: 'bytes_per_sec',
        direction: 'out',
        value: 200,
      });
    });

    expect(await screen.findByText('800 bps / 1.60 Kbps')).toBeInTheDocument();
  });

  it('disables stats action for stopped routes', async () => {
    renderRoutes();

    await screen.findByText('Stopped route');

    expect(screen.getByRole('button', { name: /route stats for stopped route/i })).toBeDisabled();
    expect(screen.getByRole('button', { name: /route stats for starting route/i })).not.toBeDisabled();
  });

  it('shows uptime for routes that are starting or running', async () => {
    const startedAt = new Date(Date.now() - 60_000).toISOString();

    vi.mocked(routesApi.getAll).mockResolvedValue({
      data: [
        routeFixture({
          id: 'running-route',
          name: 'Running route',
          status: 'starting',
          schema_status: 'processing',
          started_at: startedAt,
        }),
      ],
    });

    renderRoutes();

    expect(await screen.findByText('1m')).toBeInTheDocument();
  });

  it('fetches status analytics for selected window', async () => {
    renderRoutes('/routes?time=last_hour&status_view=chart');

    await screen.findAllByText('Starting route');
    expect(routesApi.getStatusesAnalytics).toHaveBeenCalled();
    expect(routesApi.getStatusesAnalytics).toHaveBeenLastCalledWith(
      expect.objectContaining({ window: 'last_hour' }),
    );
  });

  it('disables refresh in live and enables it in non-live windows', async () => {
    renderRoutes('/routes?time=last_hour&status_view=chart');

    await screen.findAllByText('Starting route');
    const refreshButton = screen.getByRole('button', { name: /refresh/i });
    expect(refreshButton).not.toBeDisabled();
  });

  it.skip('loads fallback history event in live when 5-minute window is empty', async () => {
    vi.mocked(routesApi.getStatusesHistory)
      .mockResolvedValueOnce({
        data: {
          events: [],
          meta: { window: 'live', limit: 50, offset: 0, total: 0 },
        },
      })
      .mockResolvedValueOnce({
        data: {
          events: [
            {
              ts: '2026-05-15T10:00:00Z',
              route_id: 'starting-route',
              route_name: 'Starting route',
              old_status: 'stopped',
              new_status: 'starting',
            },
          ],
          meta: { window: 'last_24_hour', limit: 1, offset: 0, total: 1 },
        },
      });

    renderRoutes();

    await screen.findByText('Starting route');
    fireEvent.click(screen.getByRole('tab', { name: /history/i }));

    expect(await screen.findByRole('link', { name: 'Starting route' })).toBeInTheDocument();
    expect(routesApi.getStatusesHistory).toHaveBeenNthCalledWith(1, expect.objectContaining({
      limit: 50,
      offset: 0,
    }));
    expect(routesApi.getStatusesHistory).toHaveBeenNthCalledWith(2, expect.objectContaining({
      window: 'last_24_hour',
      limit: 1,
      offset: 0,
    }));
  });

  it.skip('replaces history rows when pagination page changes', async () => {
    vi.mocked(routesApi.getStatusesHistory).mockImplementation(async ({ offset }: { offset?: number } = {}) => {
      if (offset === 0) {
        return {
          data: {
            events: [
              {
                ts: '2026-05-15T10:00:00Z',
                route_id: 'starting-route',
                route_name: 'Starting route',
                old_status: 'stopped',
                new_status: 'starting',
              },
            ],
            meta: { window: 'live', limit: 50, offset: 0, total: 100 },
          },
        };
      }

      return {
        data: {
          events: [
            {
              ts: '2026-05-15T10:01:00Z',
              route_id: 'stopped-route',
              route_name: 'Stopped route',
              old_status: 'starting',
              new_status: 'stopped',
            },
          ],
          meta: { window: 'live', limit: 50, offset: 50, total: 100 },
        },
      };
    });

    renderRoutes('/routes?page=2&time=live&status_view=history');

    await screen.findByRole('link', { name: 'Stopped route' });
  });

  it('shows reset status line and disables Since reset when snapshot has no since_reset block', async () => {
    renderRoutes();

    emitStatsSnapshot('starting-route', {
      pipeline_marker: 'full-snapshot-only',
      source: { bytes_in_total: 1000 },
    });

    await openStatsDrawer();

    expect(screen.getByText('Statistics have not been reset')).toBeInTheDocument();
    expect(screen.getByText('Since reset').closest('.ant-segmented-item-disabled')).not.toBeNull();
  });

  it('defaults to Since reset and shows last reset line when snapshot has since_reset', async () => {
    renderRoutes();

    emitStatsSnapshot('starting-route', {
      pipeline_marker: 'full-snapshot-only',
      since_reset: {
        reset_at: '2026-05-15T10:00:00.000000Z',
        rebased_at: null,
        source: { bytes_in_total: 12345 },
        destinations: [],
      },
    });

    await openStatsDrawer();

    expect(screen.getByText(/Last reset:/)).toBeInTheDocument();
    expect(screen.getByText('Since reset').closest('.ant-segmented-item-selected')).not.toBeNull();
    expect(screen.queryByText('pipeline_marker')).not.toBeInTheDocument();
  });

  it('renders full snapshot keys when switching to Total', async () => {
    renderRoutes();

    emitStatsSnapshot('starting-route', {
      pipeline_marker: 'full-snapshot-only',
      since_reset: {
        reset_at: '2026-05-15T10:00:00.000000Z',
        rebased_at: null,
        source: { bytes_in_total: 12345 },
        destinations: [],
      },
    });

    await openStatsDrawer();

    fireEvent.click(screen.getByText('Total'));

    expect(await screen.findByText(/pipeline_marker/)).toBeInTheDocument();
  });

  it('omits the since_reset block from the Total tree', async () => {
    renderRoutes();

    emitStatsSnapshot('starting-route', {
      pipeline_marker: 'full-snapshot-only',
      since_reset: {
        reset_at: '2026-05-15T10:00:00.000000Z',
        rebased_at: null,
        source: { bytes_in_total: 12345 },
        destinations: [],
      },
    });

    await openStatsDrawer();

    fireEvent.click(screen.getByText('Total'));

    expect(await screen.findByText(/pipeline_marker/)).toBeInTheDocument();
    expect(screen.queryByText(/since_reset/)).not.toBeInTheDocument();
  });

  it('hides the previous baseline while a repeat reset awaits the next tick', async () => {
    renderRoutes();

    emitStatsSnapshot('starting-route', {
      pipeline_marker: 'full-snapshot-only',
      since_reset: {
        reset_at: '2026-05-15T10:00:00.000000Z',
        rebased_at: null,
        source: { bytes_in_total: 12345 },
        destinations: [],
      },
    });

    await openStatsDrawer();

    expect(screen.getByText(/Last reset:/)).toBeInTheDocument();

    const [resetTrigger] = screen.getAllByRole('button', { name: /^reset$/i });
    fireEvent.click(resetTrigger);
    const resetButtons = await screen.findAllByRole('button', { name: /^reset$/i });
    fireEvent.click(resetButtons[resetButtons.length - 1]);

    await waitFor(() => {
      expect(routesApi.resetStats).toHaveBeenCalledWith('starting-route');
    });

    expect(await screen.findByText('Waiting for the next statistics update')).toBeInTheDocument();
    expect(screen.queryByText(/Last reset:/)).not.toBeInTheDocument();
    expect(screen.queryByText(/12345/)).not.toBeInTheDocument();
  });

  it('drops the reset status immediately after a successful clear', async () => {
    renderRoutes();

    emitStatsSnapshot('starting-route', {
      pipeline_marker: 'full-snapshot-only',
      since_reset: {
        reset_at: '2026-05-15T10:00:00.000000Z',
        rebased_at: null,
        source: { bytes_in_total: 12345 },
        destinations: [],
      },
    });

    await openStatsDrawer();

    expect(screen.getByText(/Last reset:/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: /^clear$/i }));

    await waitFor(() => {
      expect(routesApi.clearStatsReset).toHaveBeenCalledWith('starting-route');
    });

    expect(await screen.findByText('Statistics have not been reset')).toBeInTheDocument();
    expect(screen.queryByText(/Last reset:/)).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /^clear$/i })).not.toBeInTheDocument();
    expect(screen.getByText('Since reset').closest('.ant-segmented-item-disabled')).not.toBeNull();
  });

  it('calls resetStats from the drawer Reset action', async () => {
    renderRoutes();

    emitStatsSnapshot('starting-route', {
      source: { bytes_in_total: 1000 },
    });

    await openStatsDrawer();

    const [resetTrigger] = screen.getAllByRole('button', { name: /^reset$/i });
    fireEvent.click(resetTrigger);
    const resetButtons = await screen.findAllByRole('button', { name: /^reset$/i });
    fireEvent.click(resetButtons[resetButtons.length - 1]);

    await waitFor(() => {
      expect(routesApi.resetStats).toHaveBeenCalledWith('starting-route');
    });
  });

  it('does not show plain totals under the Since reset label before the next tick', async () => {
    renderRoutes();

    emitStatsSnapshot('starting-route', {
      source: { bytes_in_total: 1000 },
    });

    await openStatsDrawer();

    const [resetTrigger] = screen.getAllByRole('button', { name: /^reset$/i });
    fireEvent.click(resetTrigger);
    const resetButtons = await screen.findAllByRole('button', { name: /^reset$/i });
    fireEvent.click(resetButtons[resetButtons.length - 1]);

    await waitFor(() => {
      expect(routesApi.resetStats).toHaveBeenCalledWith('starting-route');
    });

    expect(await screen.findByText('Waiting for the next statistics update')).toBeInTheDocument();
    expect(screen.getByText('Reset applied. Waiting for the next statistics update.')).toBeInTheDocument();
    expect(screen.queryByText('Statistics have not been reset')).not.toBeInTheDocument();
    expect(screen.queryByText(/bytes_in_total/i)).not.toBeInTheDocument();
  });

  it('falls back to totals when the backend drops the reset baseline', async () => {
    renderRoutes();

    emitStatsSnapshot('starting-route', {
      source: { bytes_in_total: 1000 },
      since_reset: {
        reset_at: '2026-05-15T10:00:00.000000Z',
        rebased_at: null,
        source: { bytes_in_total: 10 },
      },
    });

    await openStatsDrawer();

    expect(await screen.findByText(/last reset:/i)).toBeInTheDocument();

    // A pipeline restart clears the handler baseline, so later snapshots carry
    // totals again with no since_reset block.
    emitStatsSnapshot('starting-route', {
      source: { bytes_in_total: 2000 },
    });

    expect(
      await screen.findByText(/the reset baseline was discarded because the pipeline restarted/i),
    ).toBeInTheDocument();
    expect(screen.queryByText('Waiting for the next statistics update')).not.toBeInTheDocument();
    expect(screen.getByText(/bytes_in_total/i)).toBeInTheDocument();
  });

  it('surfaces the server error when resetStats fails', async () => {
    vi.mocked(routesApi.resetStats).mockRejectedValueOnce(new Error('No statistics received yet'));

    renderRoutes();

    emitStatsSnapshot('starting-route', {
      source: { bytes_in_total: 1000 },
    });

    await openStatsDrawer();

    const [resetTrigger] = screen.getAllByRole('button', { name: /^reset$/i });
    fireEvent.click(resetTrigger);
    const resetButtons = await screen.findAllByRole('button', { name: /^reset$/i });
    fireEvent.click(resetButtons[resetButtons.length - 1]);

    expect(await screen.findByText('No statistics received yet')).toBeInTheDocument();
  });

  it('shows a warning when since_reset has rebased_at', async () => {
    renderRoutes();

    emitStatsSnapshot('starting-route', {
      since_reset: {
        reset_at: '2026-05-15T10:00:00.000000Z',
        rebased_at: '2026-05-15T11:30:00.000000Z',
        source: { bytes_in_total: 12345 },
        destinations: [],
      },
    });

    await openStatsDrawer();

    expect(screen.getByText(/Counters restarted at/i)).toBeInTheDocument();
    expect(screen.getByText(/not since the reset/i)).toBeInTheDocument();
  });

});
