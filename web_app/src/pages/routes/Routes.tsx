import { useEffect, useRef, useState, type Key } from 'react';
import { Table, Card, Button, Space, Typography, message, Modal, Dropdown, Tooltip, Input, Badge, Drawer, Tree, Empty, Tag, Select, DatePicker, Tabs, Collapse, Segmented, Popconfirm, Alert } from 'antd';
import {
  PlusOutlined,
  EditOutlined,
  CopyOutlined,
  DeleteOutlined,
  ExclamationCircleFilled,
  CloseCircleFilled,
  CaretRightOutlined,
  StopOutlined,
  HomeOutlined,
  HolderOutlined,
  SearchOutlined,
  BarChartOutlined,
  DownOutlined,
  ReloadOutlined,
} from '@ant-design/icons';
import { useNavigate, useSearchParams } from 'react-router-dom';
import dayjs from 'dayjs';
import {
  Area,
  AreaChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip as RechartsTooltip,
  XAxis,
  YAxis,
} from 'recharts';
import { routesApi, tagsApi } from '../../utils/api';
import { ROUTES } from '../../utils/constants';
import { subscribeToItemSource, subscribeToItemStatus, subscribeToRouteEvents, subscribeToStats } from '../../utils/realtime';
import {
  ACTIVE_ROUTE_STATUSES,
  compareUptime,
  formatStatusLabel,
  getRouteRuntimeStatus,
  isRouteBusy,
  ROUTE_RUNTIME_STATUSES,
} from '../../utils/routes';
import { getEndpointAddressString, renderEndpointAddress } from '../../utils/routeEndpointAddress';
type StatusTimelineTooltipProps = {
  active?: boolean;
  payload?: Array<{
    dataKey?: string | number;
    name?: string;
    value?: number;
    color?: string;
    payload?: AnalyticsPoint;
  }>;
};
import type { ColumnsType } from 'antd/es/table';
import type { FilterDropdownProps } from 'antd/es/table/interface';
import { getErrorMessage } from '../../types/errors';
import {
  AnalyticsPoint,
  PendingRouteActionsMap,
  RouteEndpoint,
  RouteRecord,
  RouteStatsMap,
  StatusAnalyticsData,
  StatusHistoryData,
  StatusHistoryEvent,
  StatsSinceReset,
  StatsTreeNode,
  TagOption,
  TimeRangeQuery,
} from '../../types/routes';
import type { Dayjs } from 'dayjs';

const { Title, Text } = Typography;
const ONE_MINUTE_SECONDS = 60;
const ONE_HOUR_SECONDS = 60 * ONE_MINUTE_SECONDS;
const ONE_DAY_SECONDS = 24 * ONE_HOUR_SECONDS;
const ONE_MONTH_SECONDS = 30 * ONE_DAY_SECONDS;
const DELETE_DISABLED_MESSAGE = 'If you want to delete it, stop the route first';
const ROUTE_ACTION_POLL_ATTEMPTS = 5;
const ROUTE_ACTION_POLL_DELAY_MS = 250;
const DEFAULT_PAGE = 1;
const DEFAULT_PAGE_SIZE = 10;
const LIVE_REFRESH_INTERVAL_MS = 5_000;
const CHART_GRID_STYLE = {
  stroke: '#4f4f4f',
  strokeWidth: 0.6,
  strokeDasharray: '2 4',
};
const STATUS_SERIES = [
  { key: 'processing', label: 'processing', color: '#52c41a' },
  { key: 'starting', label: 'starting', color: '#1677ff' },
  { key: 'reconnecting', label: 'reconnecting', color: '#fa8c16' },
  { key: 'restarting', label: 'restarting', color: '#fa8c16' },
  { key: 'failed', label: 'failed', color: '#b37feb' },
  { key: 'stopped', label: 'stopped', color: '#ff4d4f' },
  { key: 'other', label: 'other', color: '#8c8c8c' },
];
const LIVE_WINDOW = 'live';
const CUSTOM_WINDOW = 'custom';
const LIVE_WINDOW_MINUTES = 5;
const LIVE_WINDOW_MS = LIVE_WINDOW_MINUTES * 60 * 1000;
const STATUS_VIEW_CHART = 'chart';
const STATUS_VIEW_HISTORY = 'history';
const STATUS_VIEW_VALUES = new Set([STATUS_VIEW_CHART, STATUS_VIEW_HISTORY]);
const STATUS_TIMELINE_EXPANDED_STORAGE_KEY = 'routes.status_timeline_expanded';
const WINDOW_OPTIONS = [
  { label: 'live', value: LIVE_WINDOW },
  { label: 'last 30 min', value: 'last_30_min' },
  { label: 'last hour', value: 'last_hour' },
  { label: 'last 6 hour', value: 'last_6_hour' },
  { label: 'last 24 hour', value: 'last_24_hour' },
  { label: 'custom range', value: CUSTOM_WINDOW },
];
const WINDOW_VALUES = new Set(WINDOW_OPTIONS.map((item) => item.value));

const formatChartTimestamp = (value: string | null | undefined, includeSeconds = false) => {
  if (!value) return '';
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return '';

  const pad = (input: number) => String(input).padStart(2, '0');
  const hours = pad(parsed.getHours());
  const minutes = pad(parsed.getMinutes());
  if (!includeSeconds) return `${hours}:${minutes}`;
  return `${hours}:${minutes}:${pad(parsed.getSeconds())}`;
};

const renderStatusTimelineTooltip = ({ active, payload }: StatusTimelineTooltipProps) => {
  if (!active || !Array.isArray(payload) || payload.length === 0) return null;
  const rawTimestamp = payload[0]?.payload?.timestamp;
  const timeLabel = formatChartTimestamp(rawTimestamp, true) || '-';

  return (
    <div style={{ background: '#141414', border: '1px solid #303030', borderRadius: 6, padding: '8px 10px' }}>
      <div style={{ color: '#bfbfbf', fontSize: 12, fontWeight: 700, marginBottom: 10 }}>{timeLabel}</div>
      {payload.map((entry) => (
        <div key={entry?.dataKey} style={{ color: entry?.color || '#d9d9d9', fontSize: 12 }}>
          {entry?.name}: {entry?.value ?? 0}
        </div>
      ))}
    </div>
  );
};

const getStatusMeta = (status: string | null | undefined) => {
  switch ((status || '').toLowerCase()) {
    case 'processing':
      return { color: '#52c41a', label: 'running' };
    case 'started':
      return { color: '#1677ff', label: 'starting' };
    case 'starting':
      return { color: '#1677ff', label: status };
    case 'reconnecting':
      return { color: '#fa8c16', label: status };
    case 'stopping':
      return { color: '#1677ff', label: status };
    case 'restarting':
      return { color: '#fa8c16', label: status };
    case 'completed':
      return { color: '#52c41a', label: status };
    case 'failed':
      return { color: '#b37feb', label: status };
    case 'stopped':
      return { color: '#ff4d4f', label: status };
    default:
      return { color: '#8c8c8c', label: status || 'unknown' };
  }
};

const renderStatusBadge = (status: string | null | undefined) => {
  const { color, label } = getStatusMeta(status);
  return <Badge color={color} text={formatStatusLabel(label).toLowerCase()} />;
};

const historyEventKey = (event: StatusHistoryEvent) =>
  `${String(event.route_id ?? '')}:${String(event.ts ?? '')}:${String(event.new_status ?? '')}`;

const mergeHistoryEvents = (incoming: StatusHistoryEvent[], current: StatusHistoryEvent[]) => {
  const all = [...(incoming || []), ...(current || [])];
  const deduped = all.filter((event, index, arr) => (
    arr.findIndex((candidate) => historyEventKey(candidate) === historyEventKey(event)) === index
  ));

  return deduped.sort((a, b) => Date.parse(String(b.ts ?? '')) - Date.parse(String(a.ts ?? '')));
};

const sleep = (ms: number) => new Promise((resolve) => window.setTimeout(resolve, ms));

const hasRouteReachedActionResult = (route: RouteRecord | null | undefined, action: 'start' | 'stop') => {
  const runtimeStatus = (getRouteRuntimeStatus(route) || '').toLowerCase();

  if (action === 'start') {
    return ACTIVE_ROUTE_STATUSES.has(runtimeStatus);
  }

  return runtimeStatus === 'stopped' || runtimeStatus === 'failed' || runtimeStatus === 'completed';
};

const formatUptime = (startedAt: string | null | undefined, status: string | null | undefined, nowMs: number) => {
  if (
    typeof status !== 'string' ||
    !ACTIVE_ROUTE_STATUSES.has(status.toLowerCase()) ||
    !startedAt
  ) {
    return '-';
  }

  const startedAtMs = new Date(startedAt).getTime();

  if (Number.isNaN(startedAtMs) || startedAtMs > nowMs) {
    return '-';
  }

  let totalSeconds = Math.floor((nowMs - startedAtMs) / 1000);

  if (totalSeconds < 0) {
    return '-';
  }

  const months = Math.floor(totalSeconds / ONE_MONTH_SECONDS);
  totalSeconds -= months * ONE_MONTH_SECONDS;

  const days = Math.floor(totalSeconds / ONE_DAY_SECONDS);
  totalSeconds -= days * ONE_DAY_SECONDS;

  const hours = Math.floor(totalSeconds / ONE_HOUR_SECONDS);
  totalSeconds -= hours * ONE_HOUR_SECONDS;

  const minutes = Math.floor(totalSeconds / ONE_MINUTE_SECONDS);
  totalSeconds -= minutes * ONE_MINUTE_SECONDS;

  const seconds = totalSeconds;

  const parts = [];

  if (months > 0) {
    parts.push(`${months}mo`);
  }

  if (days > 0) {
    parts.push(`${days}d`);
  }

  if (months === 0 && hours > 0) {
    parts.push(`${hours}h`);
  }

  if (months === 0 && days === 0 && minutes > 0) {
    parts.push(`${minutes}m`);
  }

  if (months === 0 && days === 0 && minutes === 0 && seconds > 0) {
    parts.push(`${seconds}s`);
  }

  if (parts.length === 0) {
    return '0s';
  }

  return parts.join('');
};

const formatBitrate = (bytesPerSecond: number | null | undefined) => {
  if (typeof bytesPerSecond !== 'number' || Number.isNaN(bytesPerSecond)) {
    return '-';
  }

  const bitsPerSecond = bytesPerSecond * 8;
  const units = ['bps', 'Kbps', 'Mbps', 'Gbps'];
  let value = bitsPerSecond;
  let unitIndex = 0;

  while (value >= 1000 && unitIndex < units.length - 1) {
    value /= 1000;
    unitIndex += 1;
  }

  const digits = value >= 100 || unitIndex === 0 ? 0 : value >= 10 ? 1 : 2;
  return `${value.toFixed(digits)} ${units[unitIndex]}`;
};

const formatStatsValue = (value: unknown) => {
  if (value === null) {
    return 'null';
  }

  if (value === undefined) {
    return 'undefined';
  }

  if (typeof value === 'string') {
    return value;
  }

  return String(value);
};

const buildStatsTreeData = (value: unknown, path = 'stats', label = 'stats'): StatsTreeNode => {
  if (Array.isArray(value)) {
    return {
      title: `${label} [${value.length}]`,
      key: path,
      children: value.map((item, index) => buildStatsTreeData(item, `${path}.${index}`, `[${index}]`)),
    };
  }

  if (value && typeof value === 'object') {
    const entries = Object.entries(value);

    return {
      title: `${label} {${entries.length}}`,
      key: path,
      children: entries.map(([key, childValue]) => buildStatsTreeData(childValue, `${path}.${key}`, key)),
    };
  }

  return {
    title: (
      <span>
        <Text>{label}: </Text>
        <Text code>{formatStatsValue(value)}</Text>
      </span>
    ),
    key: path,
  };
};

type StatsDrawerViewMode = 'total' | 'since_reset';

const getSnapshotSinceReset = (snapshot: unknown): StatsSinceReset | null => {
  if (!snapshot || typeof snapshot !== 'object') {
    return null;
  }

  const sinceReset = (snapshot as Record<string, unknown>).since_reset;

  if (!sinceReset || typeof sinceReset !== 'object') {
    return null;
  }

  return sinceReset as StatsSinceReset;
};

const buildSinceResetTreeSource = (sinceReset: StatsSinceReset) => {
  const counters = { ...sinceReset };
  delete counters.reset_at;
  delete counters.rebased_at;
  return counters;
};

const buildTotalTreeSource = (snapshot: unknown) => {
  if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot)) {
    return snapshot;
  }

  const totals = { ...(snapshot as Record<string, unknown>) };
  delete totals.since_reset;
  return totals;
};

const formatResetTimestampLocal = (value: string | null | undefined) => {
  if (!value) {
    return null;
  }

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return null;
  }

  return date.toLocaleString();
};

const formatElapsedSince = (value: string | null | undefined, nowMs: number) => {
  if (!value) {
    return null;
  }

  const atMs = new Date(value).getTime();

  if (Number.isNaN(atMs) || atMs > nowMs) {
    return null;
  }

  let totalSeconds = Math.floor((nowMs - atMs) / 1000);

  if (totalSeconds < ONE_MINUTE_SECONDS) {
    return 'less than a minute';
  }

  const months = Math.floor(totalSeconds / ONE_MONTH_SECONDS);
  totalSeconds -= months * ONE_MONTH_SECONDS;

  const days = Math.floor(totalSeconds / ONE_DAY_SECONDS);
  totalSeconds -= days * ONE_DAY_SECONDS;

  const hours = Math.floor(totalSeconds / ONE_HOUR_SECONDS);
  totalSeconds -= hours * ONE_HOUR_SECONDS;

  const minutes = Math.floor(totalSeconds / ONE_MINUTE_SECONDS);

  if (months > 0) {
    return `${months}mo`;
  }

  if (days > 0) {
    return `${days}d`;
  }

  if (hours > 0) {
    return `${hours}h`;
  }

  return `${minutes}m`;
};

const collectTreeKeys = (nodes: StatsTreeNode[]) => {
  const keys: string[] = [];

  nodes.forEach((node) => {
    keys.push(node.key);

    if (node.children?.length) {
      keys.push(...collectTreeKeys(node.children));
    }
  });

  return keys;
};

const getRouteSourceEndpoint = (route: RouteRecord | null | undefined): RouteEndpoint | null => {
  if (!route) {
    return null;
  }

  const sources = Array.isArray(route.sources) ? route.sources : [];
  const activeSource =
    sources.find((source) => source?.id === route.active_source_id) ||
    sources.find((source) => source?.position === 0) ||
    sources[0];

  if (activeSource) {
    return activeSource;
  }

  // Backward compatibility for legacy route payloads.
  if (route.source?.schema) {
    return route.source;
  }

  return null;
};

const Routes = () => {
  const [searchParams, setSearchParams] = useSearchParams();
  const [routes, setRoutes] = useState<RouteRecord[]>([]);
  const [routesFilter, setRoutesFilter] = useState('');
  const [selectedTags, setSelectedTags] = useState<string[]>([]);
  const [availableTags, setAvailableTags] = useState<TagOption[]>([]);
  const [tagsLoadFailed, setTagsLoadFailed] = useState(false);
  const [routeStats, setRouteStats] = useState<RouteStatsMap>({});
  const [statsDrawerRouteId, setStatsDrawerRouteId] = useState<string | null>(null);
  const [statsViewMode, setStatsViewMode] = useState<StatsDrawerViewMode>('total');
  const [statsResetActionPending, setStatsResetActionPending] = useState(false);
  const [statsResetPending, setStatsResetPending] = useState(false);
  const [statsBaselineDropped, setStatsBaselineDropped] = useState(false);
  const statsResetSnapshotRef = useRef<unknown>(null);
  const [loading, setLoading] = useState(true);
  const [pagination, setPagination] = useState({
    current: DEFAULT_PAGE,
    pageSize: DEFAULT_PAGE_SIZE,
    total: 0,
  });
  const [nowMs, setNowMs] = useState(() => Date.now());
  const [pendingRouteActions, setPendingRouteActions] = useState<PendingRouteActionsMap>({});
  const [selectedRouteIds, setSelectedRouteIds] = useState<string[]>([]);
  const [statusChartWindow, setStatusChartWindow] = useState(() => {
    const timeFromUrl = searchParams.get('time');
    return timeFromUrl && WINDOW_VALUES.has(timeFromUrl) ? timeFromUrl : LIVE_WINDOW;
  });
  const [customRangeDraft, setCustomRangeDraft] = useState<[Dayjs, Dayjs]>([dayjs().subtract(1, 'hour'), dayjs()]);
  const [customRangeApplied, setCustomRangeApplied] = useState<[Dayjs, Dayjs]>([dayjs().subtract(1, 'hour'), dayjs()]);
  const [statusAnalyticsData, setStatusAnalyticsData] = useState<StatusAnalyticsData>({ points: [], meta: null });
  const [statusAnalyticsLoading, setStatusAnalyticsLoading] = useState(false);
  const [statusAnalyticsError, setStatusAnalyticsError] = useState<string | null>(null);
  const [statusAnalyticsRefreshTick, setStatusAnalyticsRefreshTick] = useState(0);
  const [statusTimelineView, setStatusTimelineView] = useState(() => {
    const viewFromUrl = searchParams.get('status_view');
    return viewFromUrl && STATUS_VIEW_VALUES.has(viewFromUrl) ? viewFromUrl : STATUS_VIEW_CHART;
  });
  const [statusHistoryData, setStatusHistoryData] = useState<StatusHistoryData>({ events: [], meta: null });
  const [statusHistoryLoading, setStatusHistoryLoading] = useState(false);
  const [statusHistoryError, setStatusHistoryError] = useState<string | null>(null);
  const [statusHistoryPage, setStatusHistoryPage] = useState(1);
  const [statusHistoryPageSize, setStatusHistoryPageSize] = useState(50);
  const [statusHistoryRefreshTick, setStatusHistoryRefreshTick] = useState(0);
  const [statusTimelineExpanded, setStatusTimelineExpanded] = useState(() => {
    try {
      const raw = window.localStorage.getItem(STATUS_TIMELINE_EXPANDED_STORAGE_KEY);
      return raw === null ? true : raw === 'true';
    } catch {
      return true;
    }
  });
  const [messageApi, contextHolder] = message.useMessage();
  const [modal, modalContextHolder] = Modal.useModal();
  const navigate = useNavigate();
  const urlInitRef = useRef(false);
  const initialPageFromUrl = (() => {
    const raw = searchParams.get('page');
    const parsed = raw ? Number.parseInt(raw, 10) : NaN;
    return Number.isInteger(parsed) && parsed > 0 ? parsed : DEFAULT_PAGE;
  })();
  const routeIdsSignature = routes
    .map((route) => route?.id)
    .filter(Boolean)
    .sort()
    .join('|');
  const statusFilters = ROUTE_RUNTIME_STATUSES.map((status) => ({
    text: status,
    value: status,
  }));

  useEffect(() => {
    if (urlInitRef.current) {
      return;
    }

    urlInitRef.current = true;
  }, []);

  useEffect(() => {
    const timeFromUrl = searchParams.get('time');
    if (timeFromUrl && WINDOW_VALUES.has(timeFromUrl)) {
      setStatusChartWindow(timeFromUrl);
    }

    const viewFromUrl = searchParams.get('status_view');
    if (viewFromUrl && STATUS_VIEW_VALUES.has(viewFromUrl)) {
      setStatusTimelineView(viewFromUrl);
    }
  // Only re-run when the URL (searchParams) changes — not when state changes.
  // State values must NOT be deps here: this effect syncs URL → state on external
  // navigation (browser back/forward). If state were a dep, clicking a tab would
  // re-run this effect before Effect 2 updates the URL, reading the stale URL value
  // and resetting the state, creating an infinite redirect loop.
  // React's built-in bail-out handles no-op setState calls (same-value strings).
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchParams]);

  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.setBreadcrumbItems([
        {
          href: ROUTES.ROUTES,
          title: <HomeOutlined />,
        },
        {
          href: ROUTES.ROUTES,
          title: 'Routes',
        }
      ]);
    }
  }, []);

  useEffect(() => {
    fetchRoutes({ page: initialPageFromUrl, pageSize: DEFAULT_PAGE_SIZE });
    fetchAvailableTags();
  }, []);

  useEffect(() => {
    return subscribeToStats((payload) => {
      setRouteStats((prev) => {
        const routeId = payload?.route_id ? String(payload.route_id) : undefined;
        const value = payload?.value;

        if (!routeId) {
          return prev;
        }

        const current = prev[routeId] || { outByDestination: {} as Record<string, number> };

        if (payload.metric === 'snapshot' && payload.stats && typeof payload.stats === 'object') {
          return {
            ...prev,
            [routeId]: {
              ...current,
              snapshot: payload.stats,
              outByDestination: current.outByDestination || {},
            },
          };
        }

        if (typeof value !== 'number') {
          return prev;
        }

        if (payload.direction === 'in') {
          return {
            ...prev,
            [routeId]: {
              ...current,
              in: value,
              outByDestination: current.outByDestination || {},
            },
          };
        }

        if (payload.direction === 'out' && payload.destination_id) {
          const destinationId = String(payload.destination_id);
          return {
            ...prev,
            [routeId]: {
              ...current,
              outByDestination: {
                ...(current.outByDestination || {}),
                [destinationId]: value as number,
              },
            },
          };
        }

        return prev;
      });
    });
  }, []);

  useEffect(() => {
    const routeIds = routeIdsSignature ? routeIdsSignature.split('|') : [];

    if (routeIds.length === 0) {
      return undefined;
    }

    const unsubscribers = routeIds.map((routeId) =>
      subscribeToItemStatus(routeId, (payload) => {
        const itemId = payload?.item_id;
        const status = payload?.status;

        if (!itemId || typeof status !== 'string' || status.length === 0) {
          return;
        }

        setRoutes((prev) =>
          prev.map((route) =>
            route.id === itemId
              ? {
                  ...route,
                  status,
                  schema_status: status,
                }
              : route
          )
        );
      })
    );

    return () => {
      unsubscribers.forEach((unsubscribe) => unsubscribe());
    };
  }, [routeIdsSignature]);

  useEffect(() => {
    try {
      window.localStorage.setItem(
        STATUS_TIMELINE_EXPANDED_STORAGE_KEY,
        statusTimelineExpanded ? 'true' : 'false'
      );
    } catch {
      // ignore
    }
  }, [statusTimelineExpanded]);

  useEffect(() => {
    if (!statusTimelineExpanded) {
      return;
    }

    if (statusTimelineView !== STATUS_VIEW_CHART) {
      return;
    }

    let mounted = true;

    const fetchStatusesAnalytics = async () => {
      setStatusAnalyticsLoading(true);
      setStatusAnalyticsError(null);

      const params: TimeRangeQuery = {};

      if (statusChartWindow === LIVE_WINDOW) {
        const liveTo = dayjs();
        const liveFrom = liveTo.subtract(LIVE_WINDOW_MINUTES, 'minute');
        params.from = liveFrom.toISOString();
        params.to = liveTo.toISOString();
      } else if (statusChartWindow === CUSTOM_WINDOW) {
        const [from, to] = customRangeApplied;
        if (from && to) {
          params.from = from.toDate().toISOString();
          params.to = to.toDate().toISOString();
        }
      } else {
        params.window = statusChartWindow;
      }

      try {
        const result = await routesApi.getStatusesAnalytics(params);
        if (!mounted) return;
        if (result?.error) throw new Error(result.error);

        setStatusAnalyticsData({
          points: Array.isArray(result?.data?.points) ? result.data.points : [],
          meta: result?.data?.meta || null,
        });
      } catch (error) {
        if (!mounted) return;
        setStatusAnalyticsError(getErrorMessage(error, 'Failed to load status timeline'));
        setStatusAnalyticsData({ points: [], meta: null });
      } finally {
        if (mounted) {
          setStatusAnalyticsLoading(false);
        }
      }
    };

    fetchStatusesAnalytics();
    return () => {
      mounted = false;
    };
  }, [
    statusChartWindow,
    customRangeApplied,
    statusAnalyticsRefreshTick,
    statusTimelineExpanded,
    statusTimelineView,
  ]);

  useEffect(() => {
    if (!statusTimelineExpanded) {
      return;
    }

    if (statusTimelineView !== STATUS_VIEW_HISTORY) {
      return;
    }

    let mounted = true;

    const fetchStatusesHistory = async () => {
      setStatusHistoryLoading(true);
      setStatusHistoryError(null);

      const params: TimeRangeQuery = {
        limit: statusHistoryPageSize,
        offset: (statusHistoryPage - 1) * statusHistoryPageSize,
      };

      if (statusChartWindow === LIVE_WINDOW) {
        const liveTo = dayjs();
        const liveFrom = liveTo.subtract(LIVE_WINDOW_MINUTES, 'minute');
        params.from = liveFrom.toISOString();
        params.to = liveTo.toISOString();
      } else if (statusChartWindow === CUSTOM_WINDOW) {
        const [from, to] = customRangeApplied;
        if (from && to) {
          params.from = from.toDate().toISOString();
          params.to = to.toDate().toISOString();
        }
      } else {
        params.window = statusChartWindow;
      }

      try {
        const result = await routesApi.getStatusesHistory(params);
        if (!mounted) return;
        if (result?.error) throw new Error(result.error);

        let events = Array.isArray(result?.data?.events) ? result.data.events : [];
        let meta = result?.data?.meta || null;
        let isFallback = false;

        if (statusChartWindow === LIVE_WINDOW && events.length === 0) {
          const fallbackResult = await routesApi.getStatusesHistory({
            window: 'last_24_hour',
            limit: 1,
            offset: 0,
          });

          if (!mounted) return;
          if (fallbackResult?.error) throw new Error(fallbackResult.error);

          const fallbackEvents = Array.isArray(fallbackResult?.data?.events)
            ? fallbackResult.data.events
            : [];

          if (fallbackEvents.length > 0) {
            events = fallbackEvents.map((event: StatusHistoryEvent) => ({ ...event, _fallback: true }));
            isFallback = true;
            meta = {
              ...(meta || {}),
              ...(fallbackResult?.data?.meta || {}),
              limit: statusHistoryPageSize,
              offset: (statusHistoryPage - 1) * statusHistoryPageSize,
              window: LIVE_WINDOW,
              total: fallbackEvents.length,
              is_fallback: true,
            };
          }
        }

        const shouldMergeWithLiveRealtime =
          statusTimelineView === STATUS_VIEW_HISTORY &&
          statusChartWindow === LIVE_WINDOW &&
          statusHistoryPage === 1;

        setStatusHistoryData((prev) => {
          const prevEvents = Array.isArray(prev?.events) ? prev.events : [];
          const nextEvents = shouldMergeWithLiveRealtime
            ? mergeHistoryEvents(events, prevEvents)
            : events;

          return {
            events: nextEvents,
            meta: {
              ...(meta || {}),
              total: isFallback ? nextEvents.length : meta?.total,
              is_fallback: isFallback,
            },
          };
        });
      } catch (error) {
        if (!mounted) return;
        setStatusHistoryError(getErrorMessage(error, 'Failed to load status history'));
        setStatusHistoryData({ events: [], meta: null });
      } finally {
        if (mounted) {
          setStatusHistoryLoading(false);
        }
      }
    };

    fetchStatusesHistory();
    return () => {
      mounted = false;
    };
  }, [
    statusTimelineView,
    statusChartWindow,
    customRangeApplied,
    statusHistoryPage,
    statusHistoryPageSize,
    statusHistoryRefreshTick,
    statusTimelineExpanded,
  ]);

  useEffect(() => {
    if (!statusTimelineExpanded) {
      return undefined;
    }

    if (statusTimelineView !== STATUS_VIEW_HISTORY || statusChartWindow !== LIVE_WINDOW) {
      return undefined;
    }

    if (statusHistoryPage !== 1) {
      return undefined;
    }

    const routeIds = routeIdsSignature ? routeIdsSignature.split('|') : [];
    if (routeIds.length === 0) {
      return undefined;
    }

    const routeNameById = routes.reduce<Record<string, string | null>>((acc, route) => {
      if (route?.id) {
        acc[String(route.id)] = route.name || null;
      }
      return acc;
    }, {});

    const unsubscribers = routeIds.map((routeId) =>
      subscribeToRouteEvents(routeId, (payload) => {
        if (payload?.event_type !== 'route_status_change') {
          return;
        }

        let oldStatus = null;
        let newStatus = null;
        try {
          const details = payload?.details_json ? JSON.parse(String(payload.details_json)) : null;
          oldStatus = details?.old_status || null;
          newStatus = details?.new_status || null;
        } catch {
          oldStatus = null;
          newStatus = null;
        }

        if (!newStatus) {
          return;
        }

        const ts = payload?.ts || new Date().toISOString();

        setStatusHistoryData((prev) => {
          const prevEvents = Array.isArray(prev?.events) ? prev.events : [];
          const cutoffMs = Date.now() - LIVE_WINDOW_MS;

          const nextEvent: StatusHistoryEvent = {
            ts,
            route_id: routeId,
            route_name: routeNameById[routeId] || routeId,
            old_status: oldStatus ? String(oldStatus) : null,
            new_status: String(newStatus),
          };

          const merged = mergeHistoryEvents([nextEvent], prevEvents);
          const hasLiveEvent = merged.some((event) => {
            const tsMs = Date.parse(String(event.ts ?? ''));
            return Number.isFinite(tsMs) && tsMs >= cutoffMs && event?._fallback !== true;
          });

          const trimmed = merged.filter((event) => {
            const tsMs = Date.parse(String(event.ts ?? ''));
            if (!Number.isFinite(tsMs)) return false;
            if (tsMs >= cutoffMs) return true;
            if (event?._fallback === true && !hasLiveEvent) return true;
            return false;
          });

          return {
            events: trimmed,
            meta: {
              ...(prev?.meta || {}),
              from: new Date(cutoffMs).toISOString(),
              to: new Date().toISOString(),
              window: LIVE_WINDOW,
              total: trimmed.length,
              is_fallback: false,
            },
          };
        });
      }),
    );

    return () => {
      unsubscribers.forEach((unsubscribe) => unsubscribe());
    };
  }, [
    routeIdsSignature,
    routes,
    statusChartWindow,
    statusHistoryPage,
    statusTimelineExpanded,
    statusTimelineView,
  ]);

  useEffect(() => {
    if (
      !statusTimelineExpanded ||
      statusTimelineView !== STATUS_VIEW_CHART ||
      statusChartWindow !== LIVE_WINDOW
    ) {
      return undefined;
    }

    const timer = window.setInterval(() => {
      setStatusAnalyticsRefreshTick((prev) => prev + 1);
    }, LIVE_REFRESH_INTERVAL_MS);

    return () => window.clearInterval(timer);
  }, [statusChartWindow, statusTimelineExpanded, statusTimelineView]);

  useEffect(() => {
    const nextParams = new URLSearchParams(searchParams);

    if (statusChartWindow === LIVE_WINDOW) {
      nextParams.delete('time');
    } else {
      nextParams.set('time', statusChartWindow);
    }

    if (statusTimelineView === STATUS_VIEW_CHART) {
      nextParams.delete('status_view');
    } else {
      nextParams.set('status_view', statusTimelineView);
    }

    const current = searchParams.toString();
    const next = nextParams.toString();
    if (current !== next) {
      setSearchParams(nextParams, { replace: true });
    }
  }, [searchParams, setSearchParams, statusChartWindow, statusTimelineView]);

  useEffect(() => {
    const routeIds = routeIdsSignature ? routeIdsSignature.split('|') : [];

    if (routeIds.length === 0) {
      return undefined;
    }

    const unsubscribers = routeIds.map((routeId) =>
      subscribeToItemSource(routeId, (payload) => {
        const itemId = payload?.item_id;
        const activeSourceId = payload?.active_source_id;

        if (!itemId || !activeSourceId) {
          return;
        }

        setRoutes((prev) =>
          prev.map((route) =>
            route.id === itemId
              ? {
                  ...route,
                  active_source_id: String(activeSourceId),
                  last_switch_reason: (payload?.last_switch_reason as string | undefined) || (route.last_switch_reason as string | undefined),
                  last_switch_at: (payload?.last_switch_at as string | undefined) || (route.last_switch_at as string | undefined),
                }
              : route
          )
        );
      })
    );

    return () => {
      unsubscribers.forEach((unsubscribe) => unsubscribe());
    };
  }, [routeIdsSignature]);

  useEffect(() => {
    const intervalId = window.setInterval(() => {
      setNowMs(Date.now());
    }, 10_000);

    return () => window.clearInterval(intervalId);
  }, []);

  const fetchRoutes = async ({ page = DEFAULT_PAGE, pageSize = DEFAULT_PAGE_SIZE } = {}) => {
    try {
      setLoading(true);
      const result = await routesApi.getAll({ page, limit: pageSize });
      const nextRoutes = (Array.isArray(result?.data) ? result.data : []) as RouteRecord[];
      const nextMeta = result?.meta || {};
      const nextPage = Number.isInteger(nextMeta.page) && nextMeta.page > 0 ? nextMeta.page : page;
      const nextPageSize =
        Number.isInteger(nextMeta.limit) && nextMeta.limit > 0 ? nextMeta.limit : pageSize;
      const nextTotal = Number.isInteger(nextMeta.total) && nextMeta.total >= 0 ? nextMeta.total : 0;

      setRoutes(nextRoutes);
      setPagination({
        current: nextPage,
        pageSize: nextPageSize,
        total: nextTotal,
      });

      setSearchParams((prev) => {
        const next = new URLSearchParams(prev);
        if (nextPage === DEFAULT_PAGE) {
          next.delete('page');
        } else {
          next.set('page', String(nextPage));
        }
        return next;
      }, { replace: true });
    } catch (error) {
      messageApi.error(`Failed to fetch routes: ${getErrorMessage(error, 'Unknown error')}`);
      console.error('Error:', error);
    } finally {
      setLoading(false);
    }
  };

  const fetchRoutesData = async () => {
    const result = await routesApi.getAll({
      page: pagination.current,
      limit: pagination.pageSize,
    });
    return {
      data: (Array.isArray(result?.data) ? result.data : []) as RouteRecord[],
      meta: result?.meta || null,
    };
  };

  const fetchAvailableTags = async () => {
    try {
      const result = await tagsApi.getAll();
      const tags = Array.isArray(result?.data) ? result.data : [];
      setAvailableTags(tags.map((tag: string) => ({ label: tag, value: tag })));
      setTagsLoadFailed(false);
    } catch (error) {
      setAvailableTags([]);
      setTagsLoadFailed(true);
      console.error('Failed to load tag filters', error);
    }
  };

  const refreshRoutesUntilStable = async (routeId: string, action: 'start' | 'stop') => {
    for (let attempt = 0; attempt < ROUTE_ACTION_POLL_ATTEMPTS; attempt += 1) {
      const { data: nextRoutes, meta } = await fetchRoutesData();
      setRoutes(nextRoutes);
      if (meta) {
        setPagination((prev) => ({
          current: Number.isInteger(meta.page) && meta.page > 0 ? meta.page : prev.current,
          pageSize: Number.isInteger(meta.limit) && meta.limit > 0 ? meta.limit : prev.pageSize,
          total: Number.isInteger(meta.total) && meta.total >= 0 ? meta.total : prev.total,
        }));
      }

      const nextRoute = nextRoutes.find((route) => route.id === routeId);
      if (!nextRoute || hasRouteReachedActionResult(nextRoute, action)) {
        return true;
      }

      if (attempt < ROUTE_ACTION_POLL_ATTEMPTS - 1) {
        await sleep(ROUTE_ACTION_POLL_DELAY_MS);
      }
    }

    return false;
  };

  const showDeleteConfirm = (record: RouteRecord) => {
    modal.confirm({
      title: 'Delete route',
      icon: <ExclamationCircleFilled />,
      content: `Are you sure you want to delete route "${record.name || record.id}"?`,
      okText: 'Continue',
      okType: 'danger',
      cancelText: 'No, cancel',
      maskClosable: true,
      onOk() {
        modal.confirm({
          title: 'Delete route permanently',
          icon: <CloseCircleFilled style={{ color: '#ff4d4f' }} />,
          content: (
            <Space direction="vertical" size={4}>
              <Text>{"You're about to permanently delete this route:"}</Text>
              <Text strong>{record.name || record.id}</Text>
              <Text type="danger">This action cannot be undone.</Text>
            </Space>
          ),
          okText: 'Yes, delete',
          okType: 'danger',
          cancelText: 'No, cancel',
          maskClosable: true,
          onOk() {
            return handleDelete(record.id);
          },
        });
      },
    });
  };

  const handleDelete = async (id: string, options: { silent?: boolean } = {}) => {
    const { silent = false } = options;

    try {
      await routesApi.delete(id);
      if (!silent) {
        messageApi.success('Route deleted successfully');
        await fetchRoutes();
      }
      return true;
    } catch (error) {
      if (!silent) {
        messageApi.error(`Failed to delete route: ${getErrorMessage(error, 'Unknown error')}`);
      }
      console.error('Error:', error);
      return false;
    }
  };

  const handleRouteStatus = async (id: string, action: 'start' | 'stop', options: { silent?: boolean } = {}) => {
    const { silent = false } = options;

    try {
      setPendingRouteActions((prev) => ({ ...prev, [id]: action }));
      setRoutes((prev) => prev.map((route) => (
        route.id === id
          ? {
              ...route,
              schema_status: action === 'start' ? 'starting' : 'stopping',
            }
          : route
      )));

      await (action === 'start' ? routesApi.start(id) : routesApi.stop(id));
      const settled = await refreshRoutesUntilStable(id, action);

      if (!silent) {
        messageApi.success(`Route ${action}ed successfully`);
      }
      if (settled === false && !silent) {
        messageApi.warning(`Route is still ${action === 'start' ? 'starting' : 'stopping'}. Refresh in a moment if it does not update.`);
      }
      return true;
    } catch (error) {
      await fetchRoutes();
      if (!silent) {
        messageApi.error(`Failed to ${action} route: ${getErrorMessage(error, 'Unknown error')}`);
      }
      console.error('Error:', error);
      return false;
    } finally {
      setPendingRouteActions((prev) => {
        const next = { ...prev };
        delete next[id];
        return next;
      });
    }
  };

  const runBulkRouteAction = async (action: 'start' | 'stop' | 'delete') => {
    const ids = [...selectedRouteIds];
    if (ids.length === 0) {
      return;
    }

    const loading = messageApi.loading(
      `${action === 'delete' ? 'Deleting' : `${action === 'start' ? 'Starting' : 'Stopping'}`} ${ids.length} route(s)...`,
      0
    );

    try {
      const results = await Promise.all(
        ids.map(async (id) => {
          if (action === 'delete') {
            const ok = await handleDelete(id, { silent: true });
            return { id, ok };
          }

          const ok = await handleRouteStatus(id, action, { silent: true });
          return { id, ok };
        })
      );

      const successCount = results.filter((item) => item.ok).length;
      const failedCount = results.length - successCount;

      if (action === 'delete') {
        await fetchRoutes();
      }

      setSelectedRouteIds([]);

      if (failedCount === 0) {
        messageApi.success(`${action === 'delete' ? 'Deleted' : `${action === 'start' ? 'Started' : 'Stopped'}`} ${successCount} route(s) successfully`);
      } else if (successCount === 0) {
        messageApi.error(`Failed to ${action} all selected routes`);
      } else {
        messageApi.warning(`${action === 'delete' ? 'Deleted' : `${action === 'start' ? 'Started' : 'Stopped'}`} ${successCount} route(s), failed ${failedCount}`);
      }
    } finally {
      loading();
    }
  };

  const showBulkActionConfirm = (action: 'start' | 'stop' | 'delete') => {
    const count = selectedRouteIds.length;
    if (count === 0) {
      messageApi.info('Select at least one route');
      return;
    }

    const verb = action === 'start' ? 'start' : action === 'stop' ? 'stop' : 'delete';
    const title = action === 'delete' ? 'Delete selected routes' : `${verb[0].toUpperCase()}${verb.slice(1)} selected routes`;
    const content = `Are you sure you want to ${verb} ${count} selected route(s)?`;

    modal.confirm({
      title,
      icon: <ExclamationCircleFilled />,
      content,
      okText: action === 'delete' ? 'Continue' : `Yes, ${verb}`,
      okType: action === 'delete' ? 'danger' : 'primary',
      cancelText: 'No, cancel',
      maskClosable: true,
      onOk() {
        if (action !== 'delete') {
          return runBulkRouteAction(action);
        }

        modal.confirm({
          title: 'Delete selected routes permanently',
          icon: <CloseCircleFilled style={{ color: '#ff4d4f' }} />,
          content: (
            <Space direction="vertical" size={4}>
              <Text>{`You're about to permanently delete ${count} selected route(s).`}</Text>
              <Text type="danger">This action cannot be undone.</Text>
            </Space>
          ),
          okText: 'Yes, delete',
          okType: 'danger',
          cancelText: 'No, cancel',
          maskClosable: true,
          onOk() {
            return runBulkRouteAction(action);
          },
        });
      },
    });
  };

  const getNameColumnSearchProps = () => ({
    filterDropdown: ({ setSelectedKeys, selectedKeys, confirm, clearFilters }: FilterDropdownProps) => (
      <div style={{ padding: 8 }}>
        <Input
          placeholder="Search name"
          value={selectedKeys[0]}
          onChange={(event) => {
            const value = event.target.value;
            setSelectedKeys(value ? [value] : []);
          }}
          onPressEnter={() => confirm()}
          style={{ marginBottom: 8, display: 'block', width: 200 }}
        />
        <Space>
          <Button
            type="primary"
            icon={<SearchOutlined />}
            size="small"
            onClick={() => confirm()}
          >
            Search
          </Button>
          <Button
            size="small"
            onClick={() => {
              clearFilters?.();
              confirm();
            }}
          >
            Reset
          </Button>
        </Space>
      </div>
    ),
    filterIcon: (filtered: boolean) => <SearchOutlined style={{ color: filtered ? '#1677ff' : undefined }} />,
      onFilter: (value: boolean | React.Key, record: RouteRecord) => (record.name || '').toLowerCase().includes(String(value).toLowerCase()),
  });

  const columns: ColumnsType<RouteRecord> = [
    {
      title: 'Name',
      dataIndex: 'name',
      key: 'name',
      sorter: (a, b) => (a.name || '').localeCompare(b.name || ''),
      ...getNameColumnSearchProps(),
      render: (text, record) => {
        return (
          <Space>
            <a href={`#/routes/${record.id}`}>
              {text}
            </a>
          </Space>
        );
      },
    },
    {
      title: 'Tags',
      key: 'tags',
      render: (_, record) => {
        const tags = Array.isArray(record.tags) ? record.tags : [];
        return (
          <Space size={[0, 4]} wrap>
            {tags.map((tag) => (
              <Tag key={tag}>{tag}</Tag>
            ))}
          </Space>
        );
      },
    },
    {
      title: 'Enabled',
      dataIndex: 'enabled',
      key: 'enabled',
      width: 120,
      render: (enabled) => (
        <Tag color={enabled ? 'success' : 'error'}>
          {enabled ? 'Yes' : 'No'}
        </Tag>
      ),
      filters: [
        { text: 'Enabled', value: true },
        { text: 'Disabled', value: false },
      ],
      onFilter: (value, record) => record.enabled === value,
    },
    {
      title: 'Status',
      dataIndex: 'status',
      key: 'status',
      filters: statusFilters,
      onFilter: (value, record) => (getRouteRuntimeStatus(record) || '') === value,
      render: (_, record) => renderStatusBadge(getRouteRuntimeStatus(record)),
    },
    {
      title: 'In / Out',
      key: 'throughput',
      render: (_, record) => {
        const runtime = (getRouteRuntimeStatus(record) || '').toLowerCase();

        if (runtime === 'stopped') {
          return <span>- / -</span>;
        }

        const stats = routeStats[record.id] || {};
        const outValues = Object.values(stats.outByDestination || {})
          .filter((value) => typeof value === 'number' && !Number.isNaN(value));
        const out = outValues.length > 0
          ? outValues.reduce((sum, value) => sum + value, 0)
          : null;

        return (
          <span>
            {formatBitrate(stats.in)} / {formatBitrate(out)}
          </span>
        );
      },
    },
    {
      title: 'Uptime',
      key: 'uptime',
      sorter: (a, b, sortOrder) => compareUptime(
        a,
        b,
        sortOrder === 'ascend' || sortOrder === 'descend' ? sortOrder : 'ascend',
        nowMs,
      ),
      render: (_, record) => formatUptime(record.started_at, getRouteRuntimeStatus(record), nowMs),
    },
    {
      title: 'Stats',
      key: 'stats',
      align: 'center',
      render: (_, record) => {
        const runtime = (getRouteRuntimeStatus(record) || '').toLowerCase();
        const statsDisabled = runtime === 'stopped';

        return (
          <Tooltip title={statsDisabled ? 'Stats are available when the route is not stopped' : 'Stats'}>
            <Button
              aria-label={`Route stats for ${record.name || record.id}`}
              icon={<BarChartOutlined />}
              disabled={statsDisabled}
              onClick={() => {
                const snapshot = routeStats[record.id]?.snapshot;
                setStatsResetPending(false);
                setStatsBaselineDropped(false);
                setStatsViewMode(getSnapshotSinceReset(snapshot) ? 'since_reset' : 'total');
                setStatsDrawerRouteId(record.id);
              }}
            />
          </Tooltip>
        );
      },
    },
    {
      title: 'Actions',
      key: 'actions',
      render: (_, record) => {
        const pendingAction = pendingRouteActions[record.id];
        const routeBusy = isRouteBusy(record);
        const runtimeStatus = getRouteRuntimeStatus(record);
        const runtimeStatusLower = (runtimeStatus || '').toLowerCase();
        const canStart = runtimeStatusLower === 'stopped';
        const routeAction = canStart ? 'start' : 'stop';
        const actionsDisabled = !!pendingAction;
        const items = [
          {
            key: 'toggle-status',
            icon: canStart ? <CaretRightOutlined /> : <StopOutlined />,
            label: canStart ? 'Start' : 'Stop',
            disabled: actionsDisabled,
          },
          {
            key: 'edit',
            icon: <EditOutlined />,
            label: 'Edit',
          },
          {
            key: 'duplicate',
            icon: <CopyOutlined />,
            label: 'Duplicate',
          },
          {
            key: 'delete',
            icon: <DeleteOutlined />,
            label: routeBusy ? (
              <Tooltip title={DELETE_DISABLED_MESSAGE}>
                <span>Delete</span>
              </Tooltip>
            ) : 'Delete',
            danger: true,
            disabled: routeBusy || !!pendingAction,
          },
        ];

        const handleMenuClick = ({ key }: { key: string }) => {
          if (key === 'toggle-status') {
            handleRouteStatus(record.id, routeAction);
            return;
          }

          if (key === 'edit') {
            navigate(`/routes/${record.id}/edit`);
            return;
          }

          if (key === 'duplicate') {
            navigate(`/routes/new/edit?duplicate_from=${encodeURIComponent(record.id)}`);
            return;
          }

          if (key === 'delete') {
            showDeleteConfirm(record);
          }
        };

        return (
          <Dropdown
            menu={{
              items,
              onClick: handleMenuClick,
            }}
            trigger={['click']}
          >
            <Button aria-label={`Route actions for ${record.name || record.id}`} icon={<HolderOutlined />} />
          </Dropdown>
        );
      },
    },
  ];

  const normalizedRoutesFilter = routesFilter.trim().toLowerCase();
  const filteredRoutes = routes.filter((route) => {
    if (normalizedRoutesFilter) {
      const routeName = (route.name || '').toLowerCase();
      const routeAddress = getEndpointAddressString(getRouteSourceEndpoint(route)).toLowerCase();
      if (!routeName.includes(normalizedRoutesFilter) && !routeAddress.includes(normalizedRoutesFilter)) {
        return false;
      }
    }

    if (selectedTags.length > 0) {
      const routeTags = Array.isArray(route.tags) ? route.tags : [];
      if (!selectedTags.some((tag) => routeTags.includes(tag))) {
        return false;
      }
    }

    return true;
  });
  const statsDrawerRoute = routes.find((route) => route.id === statsDrawerRouteId);
  const statsSnapshot = statsDrawerRouteId ? routeStats[statsDrawerRouteId]?.snapshot : null;
  // Reset and Clear only take effect on the next stats tick. Until that tick
  // arrives the snapshot still describes the state before the action: plain
  // totals after a first reset, the previous baseline's deltas after a repeat
  // reset, and a baseline that no longer exists after a clear. None of those
  // may be shown as the outcome of the action just taken.
  const statsResetAwaitingTick =
    statsResetPending && statsSnapshot === statsResetSnapshotRef.current;
  const statsSinceReset = statsResetAwaitingTick ? null : getSnapshotSinceReset(statsSnapshot);
  const hasStatsSinceReset = statsSinceReset !== null;
  const statsResetAt = statsSinceReset?.reset_at;
  const statsRebasedAt = statsSinceReset?.rebased_at;
  // The route handler discards the baseline whenever the pipeline restarts, so
  // a snapshot newer than the reset that still carries no since_reset block
  // means the baseline is gone rather than late. Without that distinction the
  // drawer would wait forever on a baseline that is never coming back.
  const statsBaselineMissingAfterTick =
    statsViewMode === 'since_reset' &&
    !statsSinceReset &&
    !statsResetAwaitingTick &&
    !!statsSnapshot;
  const statsEffectiveViewMode: StatsDrawerViewMode = statsBaselineMissingAfterTick
    ? 'total'
    : statsViewMode;
  const statsAwaitingSinceReset = statsEffectiveViewMode === 'since_reset' && !statsSinceReset;
  const statsTreeSource =
    statsEffectiveViewMode === 'since_reset'
      ? (statsSinceReset ? buildSinceResetTreeSource(statsSinceReset) : null)
      : buildTotalTreeSource(statsSnapshot);
  const statsTreeData = statsTreeSource ? [buildStatsTreeData(statsTreeSource)] : [];
  const expandedStatsKeys = collectTreeKeys(statsTreeData);
  const statsResetAtLocal = formatResetTimestampLocal(statsResetAt);
  const statsResetAtRelative = formatElapsedSince(statsResetAt, nowMs);
  const statsRebasedAtLocal = formatResetTimestampLocal(
    typeof statsRebasedAt === 'string' ? statsRebasedAt : null,
  );

  useEffect(() => {
    if (statsResetAwaitingTick) {
      return;
    }

    setStatsResetPending(false);

    if (statsSinceReset) {
      setStatsBaselineDropped(false);
      return;
    }

    if (statsBaselineMissingAfterTick) {
      setStatsBaselineDropped(true);
      setStatsViewMode('total');
    }
  }, [statsBaselineMissingAfterTick, statsResetAwaitingTick, statsSinceReset]);

  const handleResetStats = async () => {
    if (!statsDrawerRouteId) {
      return;
    }

    setStatsResetActionPending(true);

    try {
      await routesApi.resetStats(statsDrawerRouteId);
      messageApi.success('Statistics reset');
      statsResetSnapshotRef.current = statsSnapshot;
      setStatsResetPending(true);
      setStatsBaselineDropped(false);
      setStatsViewMode('since_reset');
    } catch (error) {
      messageApi.error(getErrorMessage(error, 'Failed to reset route statistics'));
    } finally {
      setStatsResetActionPending(false);
    }
  };

  const handleClearStatsReset = async () => {
    if (!statsDrawerRouteId) {
      return;
    }

    setStatsResetActionPending(true);

    try {
      await routesApi.clearStatsReset(statsDrawerRouteId);
      statsResetSnapshotRef.current = statsSnapshot;
      setStatsResetPending(true);
      setStatsBaselineDropped(false);
      setStatsViewMode('total');
    } catch (error) {
      messageApi.error(getErrorMessage(error, 'Failed to clear the statistics reset'));
    } finally {
      setStatsResetActionPending(false);
    }
  };
  const hasLocalFilters = normalizedRoutesFilter.length > 0 || selectedTags.length > 0;
  const tableTotal = hasLocalFilters ? filteredRoutes.length : pagination.total;
  const selectedRoutesCount = selectedRouteIds.length;
  const rawChartSeriesData = (statusAnalyticsData.points || []).map((point) => ({
    ...point,
    tsMs: new Date(String(point.timestamp ?? '')).getTime(),
  }));
  const metaFromMs = Date.parse(String(statusAnalyticsData?.meta?.from ?? ''));
  const metaToMs = Date.parse(String(statusAnalyticsData?.meta?.to ?? ''));
  const latestPointMs = rawChartSeriesData.reduce(
    (max, point) => (Number.isFinite(point.tsMs) && point.tsMs > max ? point.tsMs : max),
    Number.NEGATIVE_INFINITY
  );
  const liveDomainEnd = Math.max(
    nowMs,
    Number.isFinite(metaToMs) ? metaToMs : Number.NEGATIVE_INFINITY,
    Number.isFinite(latestPointMs) ? latestPointMs : Number.NEGATIVE_INFINITY
  );
  const liveDomainStart = liveDomainEnd - LIVE_WINDOW_MS;
  const chartSeriesData = statusChartWindow === LIVE_WINDOW
    ? rawChartSeriesData.filter((point) => Number.isFinite(point.tsMs) && point.tsMs >= liveDomainStart && point.tsMs <= liveDomainEnd)
    : rawChartSeriesData;
  const chartDomain = (statusChartWindow === LIVE_WINDOW
    ? [liveDomainStart, liveDomainEnd]
    : [
        Number.isFinite(metaFromMs) ? metaFromMs : 'auto',
        Number.isFinite(metaToMs) ? metaToMs : 'auto',
      ]) as [number, number] | [number | 'auto', number | 'auto'];
  const rowSelection = {
    selectedRowKeys: selectedRouteIds,
    onChange: (selectedRowKeys: Key[]) => {
      setSelectedRouteIds(selectedRowKeys.map(String));
    },
  };
  const statusHistoryRows = statusHistoryData?.events || [];
  const statusHistoryTotal = Number(statusHistoryData?.meta?.total ?? 0);
  const statusHistoryColumns: ColumnsType<StatusHistoryEvent> = [
    {
      title: 'Time',
      dataIndex: 'ts',
      key: 'ts',
      render: (value) => formatChartTimestamp(value, true),
    },
    {
      title: 'Route',
      key: 'route',
      render: (_, row) => (
        <a href={`#/routes/${String(row.route_id ?? '')}`}>
          {String(row.route_name || row.route_id || '')}
        </a>
      ),
    },
    {
      title: 'To',
      dataIndex: 'new_status',
      key: 'new_status',
      render: (value) => renderStatusBadge(value),
    },
    {
      title: 'From',
      dataIndex: 'old_status',
      key: 'old_status',
      render: (value) => renderStatusBadge(value),
    },
  ];

  return (
    <div>
      {contextHolder}
      {modalContextHolder}
      <Space direction="vertical" size="large" style={{ width: '100%' }}>
        <Space style={{ width: '100%', justifyContent: 'space-between' }}>
          <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>Routes</Title>
          <Space>
            <Button
              type="primary"
              icon={<PlusOutlined />}
              onClick={() => navigate('/routes/new/edit')}
            >
              Add Route
            </Button>
          </Space>
        </Space>

        <Collapse
          activeKey={statusTimelineExpanded ? ['status_timeline'] : []}
          onChange={(keys) => {
            const activeKeys = Array.isArray(keys) ? keys : [keys];
            setStatusTimelineExpanded(activeKeys.includes('status_timeline'));
          }}
          items={[
            {
              key: 'status_timeline',
              label: 'Status timeline',
              collapsible: 'icon',
              extra: (
                <Space
                  wrap
                  onClick={(event) => {
                    event.stopPropagation();
                  }}
                >
                  <Select
                    style={{ minWidth: 180 }}
                    value={statusChartWindow}
                    options={WINDOW_OPTIONS}
                    onChange={setStatusChartWindow}
                    aria-label="Route status time window"
                  />
                  <Button
                    aria-label="Refresh status timeline"
                    icon={<ReloadOutlined />}
                    onClick={() => {
                      if (statusTimelineView === STATUS_VIEW_HISTORY) {
                        setStatusHistoryRefreshTick((prev) => prev + 1);
                        return;
                      }

                      setStatusAnalyticsRefreshTick((prev) => prev + 1);
                    }}
                    loading={
                      statusTimelineView === STATUS_VIEW_HISTORY
                        ? statusHistoryLoading
                        : statusAnalyticsLoading
                    }
                    disabled={statusTimelineView === STATUS_VIEW_CHART && statusChartWindow === LIVE_WINDOW}
                  >
                    Refresh
                  </Button>
                </Space>
              ),
              children: (
                <>
          {statusChartWindow === CUSTOM_WINDOW ? (
            <Space style={{ width: '100%', justifyContent: 'flex-end', marginBottom: 12 }} wrap>
              <DatePicker.RangePicker
                showTime
                value={customRangeDraft}
                onChange={(next) => {
                  if (!next?.[0] || !next?.[1]) return;
                  setCustomRangeDraft([next[0], next[1]]);
                }}
              />
              <Button
                type="primary"
                onClick={() => setCustomRangeApplied(customRangeDraft)}
              >
                Apply
              </Button>
            </Space>
          ) : null}
          <Tabs
            activeKey={statusTimelineView}
            onChange={(value) => {
              setStatusTimelineView(value);
              if (value === STATUS_VIEW_HISTORY) {
                setStatusHistoryPage(1);
              }
            }}
            items={[
              {
                key: STATUS_VIEW_CHART,
                label: 'Charts',
                children: statusAnalyticsError ? (
                  <Empty description={statusAnalyticsError} />
                ) : chartSeriesData.length === 0 && !statusAnalyticsLoading ? (
                  <Empty description="No analytics data for selected period" />
                ) : (
                  <div style={{ width: '100%', height: 300 }}>
                    <ResponsiveContainer width="100%" height="100%">
                      <AreaChart data={chartSeriesData} margin={{ top: 8, right: 20, left: 8, bottom: 8 }}>
                        <CartesianGrid {...CHART_GRID_STYLE} />
                        <XAxis
                          type="number"
                          dataKey="tsMs"
                          domain={chartDomain}
                          tickFormatter={(value) => formatChartTimestamp(new Date(value).toISOString())}
                          minTickGap={24}
                        />
                        <YAxis allowDecimals={false} />
                        <RechartsTooltip content={(props) => renderStatusTimelineTooltip(props as unknown as StatusTimelineTooltipProps)} />
                        {STATUS_SERIES.map((item) => (
                          <Area
                            key={item.key}
                            type="stepBefore"
                            dataKey={item.key}
                            name={item.label}
                            stackId="statuses"
                            stroke={item.color}
                            fill={item.color}
                            fillOpacity={0.45}
                            isAnimationActive={false}
                          />
                        ))}
                      </AreaChart>
                    </ResponsiveContainer>
                  </div>
                ),
              },
              {
                key: STATUS_VIEW_HISTORY,
                label: 'History',
                children: statusHistoryError ? (
                  <Empty description={statusHistoryError} />
                ) : (
                  <Table
                    rowKey={(row) => `${row.route_id}-${row.ts}-${row.new_status}`}
                    columns={statusHistoryColumns}
                    dataSource={statusHistoryRows}
                    loading={statusHistoryLoading}
                    pagination={{
                      current: statusHistoryPage,
                      pageSize: statusHistoryPageSize,
                      total: statusHistoryTotal,
                      showSizeChanger: true,
                      onChange: (page, pageSize) => {
                        setStatusHistoryPage(page);
                        setStatusHistoryPageSize(pageSize);
                      },
                    }}
                  />
                ),
              },
            ]}
          />
                </>
              ),
            },
          ]}
        />

        <Card>
          <Space style={{ marginBottom: 16, width: '100%' }} wrap>
            <Button
              onClick={() => showBulkActionConfirm('start')}
              disabled={selectedRoutesCount === 0}
              icon={<CaretRightOutlined />}
            >
              Start selected
            </Button>
            <Button
              onClick={() => showBulkActionConfirm('stop')}
              disabled={selectedRoutesCount === 0}
              icon={<StopOutlined />}
            >
              Stop selected
            </Button>
            <Button
              danger
              onClick={() => showBulkActionConfirm('delete')}
              disabled={selectedRoutesCount === 0}
              icon={<DeleteOutlined />}
            >
              Delete selected
            </Button>
            <Input
              prefix={<SearchOutlined />}
              placeholder="Filter routes by name or address"
              style={{ width: 280 }}
              value={routesFilter}
              onChange={(event) => setRoutesFilter(event.target.value)}
            />
            <Select
              mode="multiple"
              allowClear
              placeholder={tagsLoadFailed ? 'Tag filters unavailable' : 'Filter by tags'}
              style={{ minWidth: 200 }}
              options={availableTags}
              value={selectedTags}
              onChange={setSelectedTags}
              status={tagsLoadFailed ? 'error' : undefined}
            />
          </Space>

          <Table
            columns={columns}
            dataSource={filteredRoutes}
            rowSelection={rowSelection}
            rowKey="id"
            loading={loading}
            pagination={{
              current: pagination.current,
              pageSize: pagination.pageSize,
              total: tableTotal,
              showSizeChanger: true,
              onChange: (page, pageSize) => {
                fetchRoutes({ page, pageSize });
              },
              showTotal: (total) => `Total ${total} routes`,
            }}
          />
        </Card>
      </Space>
      <Drawer
        title={`Stats${statsDrawerRoute?.name ? `: ${statsDrawerRoute.name}` : ''}`}
        open={!!statsDrawerRouteId}
        onClose={() => setStatsDrawerRouteId(null)}
        width={640}
        extra={(
          <Space>
            {hasStatsSinceReset ? (
              <Button
                disabled={statsResetActionPending}
                onClick={() => {
                  void handleClearStatsReset();
                }}
              >
                Clear
              </Button>
            ) : null}
            <Popconfirm
              title="Reset statistics?"
              description="This discards the previous baseline and starts measuring from the current counters."
              okText="Reset"
              onConfirm={() => {
                void handleResetStats();
              }}
            >
              <Button loading={statsResetActionPending}>Reset</Button>
            </Popconfirm>
          </Space>
        )}
      >
        <Space direction="vertical" size="middle" style={{ width: '100%' }}>
          <Text type="secondary">
            {statsResetAtLocal && statsResetAtRelative
              ? `Last reset: ${statsResetAtLocal} (${statsResetAtRelative} ago)`
              : statsAwaitingSinceReset
                ? 'Reset applied. Waiting for the next statistics update.'
                : 'Statistics have not been reset'}
          </Text>
          <Segmented<StatsDrawerViewMode>
            value={statsEffectiveViewMode}
            onChange={(mode) => {
              setStatsBaselineDropped(false);
              setStatsViewMode(mode);
            }}
            options={[
              { label: 'Total', value: 'total' },
              {
                label: hasStatsSinceReset ? (
                  'Since reset'
                ) : (
                  <Tooltip title="Reset statistics first to view counters since reset">
                    <span>Since reset</span>
                  </Tooltip>
                ),
                value: 'since_reset',
                disabled: !hasStatsSinceReset && !statsAwaitingSinceReset,
              },
            ]}
          />
          {statsBaselineDropped ? (
            <Alert
              type="warning"
              showIcon
              message="The reset baseline was discarded because the pipeline restarted. Showing totals. Reset again to start a new baseline."
            />
          ) : null}
          {statsRebasedAtLocal ? (
            <Alert
              type="warning"
              showIcon
              message={`Counters restarted at ${statsRebasedAtLocal} (connection re-established). Figures cover the period since then, not since the reset.`}
            />
          ) : null}
          {statsTreeData.length > 0 ? (
            <Tree
              showLine
              switcherIcon={<DownOutlined />}
              expandedKeys={expandedStatsKeys}
              treeData={statsTreeData}
            />
          ) : (
            <Empty
              description={
                statsAwaitingSinceReset
                  ? 'Waiting for the next statistics update'
                  : 'No stats received yet'
              }
            />
          )}
        </Space>
      </Drawer>
    </div>
  );
};

export default Routes;
