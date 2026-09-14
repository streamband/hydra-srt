import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  Card,
  Typography,
  Space,
  Tag,
  Row,
  Col,
  Button,
  type ButtonProps,
  Table,
  Modal,
  message,
  Input,
  Dropdown,
  Tooltip as AntTooltip,
  Badge,
  Select,
  DatePicker,
  Alert,
  Empty,
  Tabs,
} from 'antd';
import {
  PlayCircleOutlined,
  PauseCircleOutlined,
  EditOutlined,
  DeleteOutlined,
  PlusOutlined,
  ExclamationCircleFilled,
  HomeOutlined,
  LoadingOutlined,
  SearchOutlined,
  HolderOutlined,
  ArrowLeftOutlined,
  ReloadOutlined,
  ApiOutlined,
  SwapOutlined,
} from '@ant-design/icons';
import { useParams, useNavigate, useSearchParams } from 'react-router-dom';
import { routesApi, destinationsApi, sourcesApi } from '../../utils/api';
import {
  subscribeToItemSource,
  subscribeToItemStatus,
  subscribeToStats,
} from '../../utils/realtime';
import { ROUTES } from "../../utils/constants";
import {
  ACTIVE_ROUTE_STATUSES,
  formatStatusLabel,
  getRouteRuntimeStatus,
  isRouteBusy,
  LIVE_ROUTE_STATUSES,
  resolvePendingRouteStatus,
} from '../../utils/routes';
import { getEndpointAddressString, renderEndpointAddress } from '../../utils/routeEndpointAddress';
import SwitchMarkers from './SwitchMarkers';
import SourceTimeline from './SourceTimeline';
import PipelineLogsTab from './PipelineLogsTab';
import SrtHealthTab from './SrtHealthTab';
import NdiHealthTab from './NdiHealthTab';
import YoutubeHealthTab from './YoutubeHealthTab';
import { useNdiCapabilities } from './useNdiCapabilities';
import { isNdiRunnable } from './ndiCapabilityState';
import { ndiApi } from '../../utils/ndiApi';
import dayjs from 'dayjs';
import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip as RechartsTooltip,
  Legend,
  ResponsiveContainer,
  ReferenceArea,
} from 'recharts';
type BandwidthTooltipProps = {
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
import type { ApiDataResponse } from '../../types/api';
import { getErrorMessage } from '../../types/errors';
import {
  AnalyticsData,
  AnalyticsPoint,
  LiveSnapshotBuffer,
  RouteEndpoint,
  RoutePendingAction,
  RouteRecord,
  RuntimeStatusMeta,
  SrtHealthPoint,
  SwitchEvent,
  TimelineSegment,
  TimeRangeQuery,
} from '../../types/routes';

type EndpointRow = RouteEndpoint & {
  rowType: 'source' | 'destination';
  typeLabel: string;
  endpointId?: string;
  position?: number;
  schema_status?: string;
};

const { Title, Text } = Typography;
const ROUTE_ACTION_POLL_ATTEMPTS = 5;
const ROUTE_ACTION_POLL_DELAY_MS = 250;
const LIVE_ANALYTICS_WINDOW = 'live';
const DEFAULT_ANALYTICS_WINDOW = LIVE_ANALYTICS_WINDOW;
const CUSTOM_ANALYTICS_WINDOW = 'custom';
const LIVE_WINDOW_MINUTES = 5;
const LIVE_SNAPSHOT_THROTTLE_MS = 300;
const MAX_LIVE_POINTS = 300;
const ANALYTICS_COLORS = ['#1677ff', '#52c41a', '#faad14', '#722ed1', '#13c2c2', '#f5222d', '#2f54eb'];
const CHART_GRID_STYLE = {
  stroke: '#4f4f4f',
  strokeWidth: 0.6,
  strokeDasharray: '2 4',
};
const SRT_HEALTH_FIELDS = [
  'rtt_ms',
  'negotiated_latency_ms',
  'bandwidth_mbps',
  'rate_mbps',
  'packet_loss_percent',
  'retransmitted_packets_per_sec',
  'dropped_packets_per_sec',
  'nack_packets_per_sec',
] as const;

const snapshotSrtHealthPoint = (
  timestamp: string,
  entityType: 'source' | 'destination',
  entityId: string | undefined,
  srt: Record<string, unknown> | undefined,
): SrtHealthPoint | null => {
  if (!entityId || !srt) return null;
  const point: SrtHealthPoint = { timestamp, entity_type: entityType, entity_id: entityId };
  const sourceKeys: Record<(typeof SRT_HEALTH_FIELDS)[number], string> = {
    rtt_ms: 'rtt-ms',
    negotiated_latency_ms: 'negotiated-latency-ms',
    bandwidth_mbps: 'bandwidth-mbps',
    rate_mbps: entityType === 'source' ? 'receive-rate-mbps' : 'send-rate-mbps',
    packet_loss_percent: 'packet-loss-percent',
    retransmitted_packets_per_sec: 'retransmitted-packets-per-sec',
    dropped_packets_per_sec: 'dropped-packets-per-sec',
    nack_packets_per_sec: 'nack-packets-per-sec',
  };
  let hasValue = false;
  SRT_HEALTH_FIELDS.forEach((field) => {
    const value = toNumberOrNull(srt[sourceKeys[field]]);
    point[field] = value;
    hasValue ||= value != null;
  });
  return hasValue ? point : null;
};

const ANALYTICS_WINDOW_OPTIONS = [
  { label: 'live', value: LIVE_ANALYTICS_WINDOW },
  { label: 'last 30 min', value: 'last_30_min' },
  { label: 'last hour', value: 'last_hour' },
  { label: 'last 6 hour', value: 'last_6_hour' },
  { label: 'last 24 hour', value: 'last_24_hour' },
  { label: 'custom range', value: CUSTOM_ANALYTICS_WINDOW },
];
const ANALYTICS_WINDOW_VALUES = new Set(ANALYTICS_WINDOW_OPTIONS.map((item) => item.value));

const getRuntimeStatusMeta = (status: string | null | undefined): RuntimeStatusMeta => {
  const normalized = (status || '').toLowerCase();
  switch (normalized) {
    case 'processing':
      return { badgeStatus: 'success', label: 'running' };
    case 'started':
      return { badgeStatus: 'processing', label: 'starting' };
    case 'starting':
    case 'stopping':
    case 'reconnecting':
      return { badgeStatus: 'processing', label: normalized };
    case 'restarting':
      return { badgeStatus: 'warning', label: normalized };
    case 'failed':
      return { badgeStatus: 'error', label: normalized };
    case 'completed':
      return { badgeStatus: 'success', label: normalized };
    case 'stopped':
      return { badgeStatus: 'error', label: normalized };
    default:
      return { badgeStatus: 'default', label: status || 'unknown' };
  }
};

const renderRuntimeStatusBadge = (status: string | null | undefined) => {
  const { badgeStatus, label } = getRuntimeStatusMeta(status);
  return <Badge status={badgeStatus} text={formatStatusLabel(label).toLowerCase()} />;
};

const formatChartTimestamp = (value: string | null | undefined, includeSeconds = false) => {
  if (!value) {
    return '';
  }

  const parsed = new Date(value);

  if (Number.isNaN(parsed.getTime())) {
    return '';
  }

  const pad = (input: number) => String(input).padStart(2, '0');
  const hours = pad(parsed.getHours());
  const minutes = pad(parsed.getMinutes());

  if (!includeSeconds) {
    return `${hours}:${minutes}`;
  }

  const seconds = pad(parsed.getSeconds());
  return `${hours}:${minutes}:${seconds}`;
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

const renderBandwidthTooltip = ({ active, payload }: BandwidthTooltipProps) => {
  if (!active || !Array.isArray(payload) || payload.length === 0) {
    return null;
  }

  const rawTimestamp = payload[0]?.payload?.timestamp;
  const timeLabel = formatChartTimestamp(rawTimestamp, true) || '-';

  return (
    <div
      style={{
        background: '#141414',
        border: '1px solid #303030',
        borderRadius: 6,
        padding: '8px 10px',
      }}
    >
      <div style={{ color: '#bfbfbf', fontSize: 12, fontWeight: 700, marginBottom: 10 }}>
        {timeLabel}
      </div>
      {payload.map((entry) => (
        <div key={entry?.dataKey} style={{ color: entry?.color || '#d9d9d9', fontSize: 12 }}>
          {entry?.name}: {formatBitrate(entry?.value)}
        </div>
      ))}
    </div>
  );
};

const toNumberOrNull = (value: unknown) => {
  if (typeof value !== 'number' || Number.isNaN(value)) {
    return null;
  }

  return value;
};

const alignToSecondIso = (date = new Date()) => {
  const aligned = new Date(date);
  aligned.setMilliseconds(0);
  return aligned.toISOString();
};

const sleep = (ms: number) => new Promise((resolve) => window.setTimeout(resolve, ms));

const hasRouteReachedActionResult = (route: RouteRecord | null | undefined, action: 'start' | 'stop') => {
  const runtimeStatus = ((route?.schema_status || route?.status) || '').toLowerCase();

  if (action === 'start') {
    return ACTIVE_ROUTE_STATUSES.has(runtimeStatus);
  }

  return runtimeStatus === 'stopped' || runtimeStatus === 'failed' || runtimeStatus === 'completed';
};

const isTerminalRuntimeStatus = (status: string | null | undefined) =>
  ['stopped', 'failed', 'completed'].includes((status || '').toLowerCase());

const RouteItem = () => {
  const navigate = useNavigate();
  const { id } = useParams<{ id: string }>();
  const [searchParams, setSearchParams] = useSearchParams();
  const [routeData, setRouteData] = useState<RouteRecord | null>(null);
  const [loading, setLoading] = useState(true);
  const [messageApi, contextHolder] = message.useMessage();
  const [modal, modalContextHolder] = Modal.useModal();
  const [destinationFilter, setDestinationFilter] = useState('');
  const [pendingAction, setPendingAction] = useState<RoutePendingAction>(null);
  const [analyticsWindow, setAnalyticsWindow] = useState(DEFAULT_ANALYTICS_WINDOW);
  const [customRangeDraft, setCustomRangeDraft] = useState([
    dayjs().subtract(1, 'hour'),
    dayjs(),
  ]);
  const [customRangeApplied, setCustomRangeApplied] = useState([
    dayjs().subtract(1, 'hour'),
    dayjs(),
  ]);
  const [analyticsLoading, setAnalyticsLoading] = useState(false);
  const [analyticsError, setAnalyticsError] = useState<string | null>(null);
  const [analyticsData, setAnalyticsData] = useState<AnalyticsData>({ points: [], meta: null });
  const [analyticsRefreshTick, setAnalyticsRefreshTick] = useState(0);
  const [pipelineLogsRefreshTick, setPipelineLogsRefreshTick] = useState(0);
  const [analyticsCardTab, setAnalyticsCardTab] = useState('bandwidth');
  const [pipelineLogsLoading, setPipelineLogsLoading] = useState(false);
  const { capabilities: ndiCapabilities } = useNdiCapabilities();
  const liveSnapshotBufferRef = useRef<LiveSnapshotBuffer>(null);
  const liveSnapshotFlushTimerRef = useRef<ReturnType<typeof window.setTimeout> | null>(null);
  const lastAnalyticsFetchKeyRef = useRef<string | null>(null);
  const prevAnalyticsCardTabRef = useRef(analyticsCardTab);
  const didInitFromUrlRef = useRef(false);
  const sourceIdsDependency = (routeData?.sources || [])
    .map((source) => source?.id)
    .filter(Boolean)
    .sort()
    .join('|');
  const destinationIdsDependency = (routeData?.destinations || [])
    .map((destination) => destination?.id)
    .filter(Boolean)
    .sort()
    .join('|');

  const sourceIdsSignature = useMemo(() => sourceIdsDependency, [sourceIdsDependency]);
  const destinationIdsSignature = useMemo(
    () => destinationIdsDependency,
    [destinationIdsDependency]
  );

  const appendLiveZeroPoint = useCallback(() => {
    if (analyticsWindow !== LIVE_ANALYTICS_WINDOW) {
      return;
    }

    if (liveSnapshotFlushTimerRef.current) {
      window.clearTimeout(liveSnapshotFlushTimerRef.current);
      liveSnapshotFlushTimerRef.current = null;
    }

    liveSnapshotBufferRef.current = null;

    const timestamp = alignToSecondIso(new Date());
    const cutoffMs = Date.now() - (LIVE_WINDOW_MINUTES * 60 * 1000);

    const zeroDestinations = (routeData?.destinations || []).reduce<Record<string, number>>(
      (acc, destination) => {
        if (destination?.id && destination.enabled !== false) {
          acc[String(destination.id)] = 0;
        }

        return acc;
      },
      {},
    );

    setAnalyticsData((prev) => {
      const prevPoints = prev?.points || [];
      const zeroPoint: AnalyticsPoint = {
        timestamp,
        source: 0,
        destinations: zeroDestinations,
      };
      const existingIndex = prevPoints.findIndex((point) => point.timestamp === timestamp);

      const mergedPoints = existingIndex >= 0
        ? prevPoints.map((point, index) => (index === existingIndex ? zeroPoint : point))
        : [...prevPoints, zeroPoint];

      const trimmedPoints = mergedPoints
        .filter((point) => {
          const pointMs = Date.parse(String(point.timestamp ?? ''));
          return !Number.isNaN(pointMs) && pointMs >= cutoffMs;
        })
        .slice(-MAX_LIVE_POINTS);

      const trimmedSrtHealth = (prev?.srt_health || [])
        .filter((point) => {
          const pointMs = Date.parse(String(point.timestamp ?? ''));
          return !Number.isNaN(pointMs) && pointMs >= cutoffMs;
        })
        .slice(-MAX_LIVE_POINTS * Math.max(1, (routeData?.destinations || []).length + 1));

      return {
        ...prev,
        points: trimmedPoints,
        srt_health: trimmedSrtHealth,
      };
    });
  }, [analyticsWindow, routeData?.destinations]);

  // Breadcrumb setup
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
        },
        {
          title: loading ? <><LoadingOutlined style={{ marginRight: 8 }} />Loading...</> : (routeData ? routeData.name : 'Route Details'),
        }
      ]);
    }
  }, [id, routeData, loading]);

  // Fetch route data
  useEffect(() => {
    fetchRouteData();
  }, [id]);

  useEffect(() => {
    if (!routeData?.id) {
      return undefined;
    }

    const itemIds = [
      routeData.id,
      ...(routeData.sources || []).map((source) => source.id).filter(Boolean),
      ...(routeData.destinations || []).map((destination) => destination.id).filter(Boolean),
    ];

    const uniqueItemIds = Array.from(new Set(itemIds));
    const unsubscribers = uniqueItemIds.map((itemId) =>
      subscribeToItemStatus(String(itemId), (payload) => {
        const itemIdFromEvent = payload?.item_id;
        const status = payload?.status;

        if (!itemIdFromEvent || typeof status !== 'string' || status.length === 0) {
          return;
        }

        if (itemIdFromEvent === routeData.id && isTerminalRuntimeStatus(status)) {
          appendLiveZeroPoint();
        }

        setRouteData((prev) => {
          if (!prev) {
            return prev;
          }

          if (itemIdFromEvent === prev.id) {
            return {
              ...prev,
              status,
              schema_status: status,
            };
          }

          let sourcesChanged = false;
          const nextSources = (prev.sources || []).map((source) => {
            if (source.id !== itemIdFromEvent) {
              return source;
            }

            sourcesChanged = true;
            return {
              ...source,
              status,
              schema_status: status,
            };
          });

          let destinationsChanged = false;
          const nextDestinations = (prev.destinations || []).map((destination) => {
            if (destination.id !== itemIdFromEvent) {
              return destination;
            }

            destinationsChanged = true;
            return {
              ...destination,
              status,
            };
          });

          if (!sourcesChanged && !destinationsChanged) {
            return prev;
          }

          return {
            ...prev,
            ...(sourcesChanged ? { sources: nextSources } : {}),
            ...(destinationsChanged ? { destinations: nextDestinations } : {}),
          };
        });
      })
    );

    return () => {
      unsubscribers.forEach((unsubscribe) => {
        unsubscribe?.();
      });
    };
  }, [routeData?.id, sourceIdsSignature, destinationIdsSignature, appendLiveZeroPoint]);

  useEffect(() => {
    if (!routeData?.id) {
      return undefined;
    }

    return subscribeToItemSource(routeData.id, (payload) => {
      const itemId = payload?.item_id;
      const activeSourceId = payload?.active_source_id;

      if (!itemId || itemId !== routeData.id || !activeSourceId) {
        return;
      }

      setRouteData((prev) => {
        if (!prev) {
          return prev;
        }

        return {
          ...prev,
          active_source_id: String(activeSourceId),
          last_switch_reason: (payload?.last_switch_reason as string | undefined) || (prev.last_switch_reason as string | undefined),
          last_switch_at: (payload?.last_switch_at as string | undefined) || (prev.last_switch_at as string | undefined),
        };
      });
    });
  }, [routeData?.id]);

  const fetchRouteData = async () => {
    if (!id) {
      return;
    }

    try {
      const result = (await routesApi.getById(id)) as ApiDataResponse<RouteRecord>;
      const route = result.data;
      setRouteData(route);

      console.log("Route data:", route);
    } catch (error) {
      messageApi.error(`Failed to fetch route data: ${getErrorMessage(error, 'Unknown error')}`);
      console.error('Error:', error);
    } finally {
      setLoading(false);
    }
  };

  const fetchAnalyticsData = useCallback(async (queryParams: TimeRangeQuery): Promise<boolean> => {
    if (!id) {
      return false;
    }

    const normalizePoint = (point: AnalyticsPoint) => {
      const rawDestinations = (point.destinations || {}) as Record<string, unknown>;
      const normalizedDestinations = Object.entries(rawDestinations).reduce<Record<string, number | null>>(
        (acc, [destinationId, value]) => {
          acc[destinationId] = toNumberOrNull(value);
          return acc;
        },
        {},
      );

      return {
        timestamp: point?.timestamp,
        source: toNumberOrNull(point?.source),
        destinations: normalizedDestinations,
      };
    };
    const normalizeSrtHealthPoint = (point: SrtHealthPoint): SrtHealthPoint => {
      const normalized = { ...point };
      SRT_HEALTH_FIELDS.forEach((field) => {
        normalized[field] = toNumberOrNull(point[field]);
      });
      return normalized;
    };

    try {
      setAnalyticsLoading(true);
      setAnalyticsError(null);
      const result = (await routesApi.getAnalytics(id, queryParams)) as ApiDataResponse<AnalyticsData>;
      const nextData = result.data || { points: [], meta: null };
      setAnalyticsData({
        ...nextData,
        points: (nextData.points || []).map(normalizePoint),
        srt_health: (nextData.srt_health || []).map(normalizeSrtHealthPoint),
      });
      return true;
    } catch (error) {
      setAnalyticsError(getErrorMessage(error, 'Unknown error') || 'Failed to fetch analytics data');
      setAnalyticsData({ points: [], meta: null });
      return false;
    } finally {
      setAnalyticsLoading(false);
    }
  }, [id]);

  useEffect(() => {
    if (didInitFromUrlRef.current) {
      return;
    }

    didInitFromUrlRef.current = true;
    const timeFromUrl = searchParams.get('time');
    if (timeFromUrl && ANALYTICS_WINDOW_VALUES.has(timeFromUrl)) {
      setAnalyticsWindow(timeFromUrl);
    }
  }, [searchParams]);

  useEffect(() => {
    const nextParams = new URLSearchParams(searchParams);
    nextParams.set('time', analyticsWindow);

    const current = searchParams.toString();
    const next = nextParams.toString();
    if (current !== next) {
      setSearchParams(nextParams, { replace: true });
    }
  }, [analyticsWindow, searchParams, setSearchParams]);

  useEffect(() => {
    if (!id || !['bandwidth', 'srt_health'].includes(analyticsCardTab)) {
      if (!['bandwidth', 'srt_health'].includes(analyticsCardTab)) {
        lastAnalyticsFetchKeyRef.current = null;
      }
      prevAnalyticsCardTabRef.current = analyticsCardTab;
      return;
    }

    const queryParams: TimeRangeQuery = {};

    if (analyticsWindow === LIVE_ANALYTICS_WINDOW) {
      const liveTo = dayjs();
      const liveFrom = liveTo.subtract(LIVE_WINDOW_MINUTES, 'minute');
      queryParams.from = liveFrom.toISOString();
      queryParams.to = liveTo.toISOString();
    } else if (analyticsWindow === CUSTOM_ANALYTICS_WINDOW) {
      const [customFrom, customTo] = customRangeApplied;

      if (!customFrom || !customTo) {
        return;
      }

      queryParams.from = customFrom.toISOString();
      queryParams.to = customTo.toISOString();
    } else {
      queryParams.window = analyticsWindow;
    }

    const fetchKey = JSON.stringify({
      id,
      analyticsWindow,
      customRangeApplied: customRangeApplied.map((value) => value.toISOString()),
      analyticsRefreshTick,
    });

    const previousTab = prevAnalyticsCardTabRef.current;
    prevAnalyticsCardTabRef.current = analyticsCardTab;

    const isLiveAnalyticsTabSwitch =
      analyticsWindow === LIVE_ANALYTICS_WINDOW &&
      ['bandwidth', 'srt_health'].includes(previousTab) &&
      previousTab !== analyticsCardTab;

    if (isLiveAnalyticsTabSwitch && lastAnalyticsFetchKeyRef.current === fetchKey) {
      return;
    }

    void fetchAnalyticsData(queryParams).then((success) => {
      if (success && analyticsWindow === LIVE_ANALYTICS_WINDOW) {
        lastAnalyticsFetchKeyRef.current = fetchKey;
      }
    });
  }, [
    id,
    analyticsWindow,
    customRangeApplied,
    analyticsRefreshTick,
    analyticsCardTab,
    fetchAnalyticsData,
  ]);

  useEffect(() => {
    if (
      !id ||
      analyticsWindow !== LIVE_ANALYTICS_WINDOW ||
      !['bandwidth', 'srt_health'].includes(analyticsCardTab) ||
      isTerminalRuntimeStatus(routeData?.schema_status || routeData?.status)
    ) {
      return undefined;
    }

    const flushBufferedSnapshot = () => {
      const buffered = liveSnapshotBufferRef.current;
      liveSnapshotBufferRef.current = null;
      liveSnapshotFlushTimerRef.current = null;

      if (!buffered) {
        return;
      }

      const cutoffMs = Date.now() - (LIVE_WINDOW_MINUTES * 60 * 1000);

      setAnalyticsData((prev) => {
        const prevPoints = prev?.points || [];
        const existingIndex = prevPoints.findIndex((point) => point.timestamp === buffered.timestamp);

        let mergedPoints;
        if (existingIndex >= 0) {
          mergedPoints = [...prevPoints];
          mergedPoints[existingIndex] = buffered;
        } else {
          mergedPoints = [...prevPoints, buffered];
        }

        const trimmedPoints = mergedPoints
          .filter((point) => {
            const pointMs = Date.parse(String(point.timestamp ?? ''));
            return !Number.isNaN(pointMs) && pointMs >= cutoffMs;
          })
          .slice(-MAX_LIVE_POINTS);

        const bufferedEntities = new Set(
          buffered.srtHealth.map((point) => `${point.entity_type}:${point.entity_id}`),
        );

        return {
          ...prev,
          points: trimmedPoints,
          srt_health: [
            ...(prev.srt_health || []).filter((point) => {
              const pointMs = Date.parse(String(point.timestamp ?? ''));
              if (Number.isNaN(pointMs) || pointMs < cutoffMs) {
                return false;
              }

              if (point.timestamp !== buffered.timestamp) {
                return true;
              }

              return !bufferedEntities.has(`${point.entity_type}:${point.entity_id}`);
            }),
            ...buffered.srtHealth,
          ].slice(-MAX_LIVE_POINTS * Math.max(1, (routeData?.destinations || []).length + 1)),
        };
      });
    };

    const unsubscribe = subscribeToStats((payload) => {
      if (payload?.route_id !== id || payload?.metric !== 'snapshot' || !payload?.stats) {
        return;
      }

      const snapshotTs = alignToSecondIso(new Date());
      const statsPayload = payload?.stats as {
        source?: { bytes_in_per_sec?: number; srt?: Record<string, unknown> };
        destinations?: Array<{
          id?: string;
          bytes_out_per_sec?: number;
          srt?: Record<string, unknown>;
        }>;
      } | undefined;
      const snapshotSource = toNumberOrNull(statsPayload?.source?.bytes_in_per_sec);
      const snapshotDestinations = (statsPayload?.destinations || [])
        .reduce<Record<string, number | null>>((acc, destination) => {
          if (!destination?.id) {
            return acc;
          }

          acc[String(destination.id)] = toNumberOrNull(destination.bytes_out_per_sec);
          return acc;
        }, {});
      liveSnapshotBufferRef.current = {
        timestamp: snapshotTs,
        source: snapshotSource,
        destinations: snapshotDestinations,
        srtHealth: [
          snapshotSrtHealthPoint(
            snapshotTs,
            'source',
            routeData?.active_source_id,
            statsPayload?.source?.srt,
          ),
          ...(statsPayload?.destinations || []).map((destination) =>
            snapshotSrtHealthPoint(
              snapshotTs,
              'destination',
              destination.id,
              destination.srt,
            )
          ),
        ].filter((point): point is SrtHealthPoint => point != null),
      };

      if (!liveSnapshotFlushTimerRef.current) {
        liveSnapshotFlushTimerRef.current = window.setTimeout(
          flushBufferedSnapshot,
          LIVE_SNAPSHOT_THROTTLE_MS
        );
      }
    });

    return () => {
      unsubscribe();

      if (liveSnapshotFlushTimerRef.current) {
        window.clearTimeout(liveSnapshotFlushTimerRef.current);
        liveSnapshotFlushTimerRef.current = null;
      }

      liveSnapshotBufferRef.current = null;
    };
  }, [
    id,
    analyticsWindow,
    analyticsCardTab,
    routeData?.active_source_id,
    routeData?.destinations,
    routeData?.schema_status,
    routeData?.status,
  ]);

  useEffect(
    () => () => {
      if (liveSnapshotFlushTimerRef.current) {
        window.clearTimeout(liveSnapshotFlushTimerRef.current);
        liveSnapshotFlushTimerRef.current = null;
      }

      liveSnapshotBufferRef.current = null;
    },
    []
  );

  const applyCustomRange = () => {
    const [customFrom, customTo] = customRangeDraft;

    if (!customFrom || !customTo) {
      messageApi.error('Please select both start and end date');
      return;
    }

    if (customFrom.valueOf() >= customTo.valueOf()) {
      messageApi.error('Start date must be earlier than end date');
      return;
    }

    setCustomRangeApplied([customFrom, customTo]);
  };

  const fetchRouteDataSnapshot = async () => {
    const result = (await routesApi.getById(id as string)) as ApiDataResponse<RouteRecord>;
    return result.data;
  };

  const refreshRouteUntilStable = async (
    action: 'start' | 'stop',
    options: { authoritative?: boolean } = {},
  ) => {
    const { authoritative = false } = options;

    for (let attempt = 0; attempt < ROUTE_ACTION_POLL_ATTEMPTS; attempt += 1) {
      const nextRoute = await fetchRouteDataSnapshot();
      setRouteData((prev): RouteRecord | null => {
        if (!prev) {
          return nextRoute;
        }

        return {
          ...nextRoute,
          schema_status: authoritative
            ? nextRoute.schema_status ?? undefined
            : resolvePendingRouteStatus(
                prev.schema_status,
                nextRoute.schema_status,
                pendingAction === 'restart' ? action : (pendingAction || action),
              ) ?? undefined,
        };
      });

      if (
        hasRouteReachedActionResult(nextRoute, action) ||
        (authoritative && isTerminalRuntimeStatus(getRouteRuntimeStatus(nextRoute)))
      ) {
        return true;
      }

      if (attempt < ROUTE_ACTION_POLL_ATTEMPTS - 1) {
        await sleep(ROUTE_ACTION_POLL_DELAY_MS);
      }
    }

    return false;
  };

  // Status color and button mapping
  const getStatusDetails = (routeData: RouteRecord | null) => {
    // First check if routeData exists
    if (!routeData) {
      return {
        color: 'default',
        buttonColor: 'default',
        buttonIcon: <PlayCircleOutlined />,
        buttonText: 'Start',
        buttonType: 'default' as ButtonProps['type'],
      };
    }

    const runtimeStatus = (getRouteRuntimeStatus(routeData) || '').toLowerCase();
    const canStop = ACTIVE_ROUTE_STATUSES.has(runtimeStatus);

    if (canStop) {
      return {
        color: 'success',
        buttonColor: 'default',
        buttonIcon: <PauseCircleOutlined />,
        buttonText: 'Stop',
        buttonType: 'default' as ButtonProps['type'],
      };
    }

    return {
      color: 'error',
      buttonColor: 'primary',
      buttonIcon: <PlayCircleOutlined />,
      buttonText: 'Start',
      buttonType: 'primary' as ButtonProps['type'],
    };
  };

  const sourceRows: EndpointRow[] = (routeData?.sources || [])
    .map((source): EndpointRow => ({
      ...source,
      id: `source-${source.id}`,
      endpointId: source.id,
      typeLabel: source.position === 0 ? 'Primary Source' : 'Backup Source',
      rowType: 'source',
      name: source.name || (source.position === 0 ? 'Primary Source' : `Backup Source #${source.position}`),
      schema_status: (source.schema_status || source.status) as string | undefined,
    }));
  const routeBusy = isRouteBusy(routeData);
  const hasNdiEndpoints = useMemo(() => {
    const endpoints = [...(routeData?.sources || []), ...(routeData?.destinations || [])];
    return endpoints.some((endpoint) => String(endpoint?.schema || '').toUpperCase() === 'NDI');
  }, [routeData?.destinations, routeData?.sources]);
  const hasYoutubeSources = useMemo(
    () => (routeData?.sources || []).some((endpoint) => String(endpoint?.schema || '').toUpperCase() === 'YOUTUBE'),
    [routeData?.sources],
  );
  const ndiStartBlocked = useMemo(() => {
    if (!hasNdiEndpoints) {
      return false;
    }
    const sources = routeData?.sources || [];
    const destinations = routeData?.destinations || [];
    const hasNdiSource = sources.some((endpoint) => String(endpoint?.schema || '').toUpperCase() === 'NDI');
    const hasNdiDest = destinations.some(
      (endpoint) => String(endpoint?.schema || '').toUpperCase() === 'NDI' && endpoint.enabled !== false,
    );
    if (hasNdiSource && !isNdiRunnable(ndiCapabilities, 'receive')) {
      return true;
    }
    if (hasNdiDest && !isNdiRunnable(ndiCapabilities, 'send')) {
      return true;
    }
    return false;
  }, [hasNdiEndpoints, ndiCapabilities, routeData?.destinations, routeData?.sources]);
  const deleteDisabledMessage = 'If you want to delete it, stop the route first';

  // Filter destinations
  const filteredDestinations = (routeData?.destinations || []).filter((dest) =>
    String(dest.name || '').toLowerCase().includes(destinationFilter.toLowerCase()) ||
    getEndpointAddressString(dest).toLowerCase().includes(destinationFilter.toLowerCase())
  );

  const endpointsData: EndpointRow[] = [
    ...sourceRows,
    ...filteredDestinations.map((dest): EndpointRow => ({
      ...dest,
      endpointId: dest.id ? String(dest.id) : undefined,
      typeLabel: 'Destination',
      rowType: 'destination',
    })),
  ];

  const destinationNameById = useMemo(
    () =>
      (routeData?.destinations || []).reduce<Record<string, string>>((acc, destination) => {
        if (destination?.id) {
          acc[destination.id] = destination.name || destination.id;
        }

        return acc;
      }, {}),
    [routeData?.destinations]
  );

  const analyticsPoints = useMemo(() => analyticsData?.points || [], [analyticsData?.points]);
  const switches = (analyticsData?.switches || []) as SwitchEvent[];
  const sourceTimeline = (analyticsData?.source_timeline || []) as TimelineSegment[];
  const destinationSeriesIds = useMemo(
    () =>
      Array.from(
        new Set(
          analyticsPoints.flatMap((point) => Object.keys(point?.destinations || {}))
        )
      ),
    [analyticsPoints]
  );

  const chartData = useMemo(
    () =>
      analyticsPoints.map((point) => {
        const destinationValues = Object.entries(point.destinations || {}).reduce<Record<string, number | null>>(
          (acc, [destinationId, value]) => {
            acc[`dest_${destinationId}`] = value;
            return acc;
          },
          {},
        );

        return {
          timestamp: point.timestamp,
          xLabel: formatChartTimestamp(point.timestamp, analyticsWindow === LIVE_ANALYTICS_WINDOW),
          source: point.source,
          ...destinationValues,
        };
      }),
    [analyticsPoints, analyticsWindow]
  );

  const sourceNameById = useMemo(
    () =>
      (routeData?.sources || []).reduce<Record<string, string>>((acc, source) => {
        if (source?.id) {
          acc[String(source.id)] = String(source.name || `#${source.position}`);
        }

        return acc;
      }, {}),
    [routeData?.sources]
  );
  const sourceColorById = useMemo(
    () =>
      (routeData?.sources || []).reduce<Record<string, string>>((acc, source) => {
        if (!source?.id) {
          return acc;
        }

        acc[String(source.id)] = source.position === 0 ? '#95de64' : '#ffd591';
        return acc;
      }, {}),
    [routeData?.sources]
  );

  const resolveEndpointStatus = (record: EndpointRow): string | undefined => {
    if (record.rowType !== 'source') {
      return record.status as string | undefined;
    }

    const sourceStatus = (record.schema_status || record.status) as string | undefined;
    if (!sourceStatus) {
      return undefined;
    }

    const routeStatus = (routeData?.schema_status || routeData?.status) as string | undefined;
    const routeStatusNormalized = (routeStatus || '').toLowerCase();
    const sourceStatusNormalized = String(sourceStatus || '').toLowerCase();
    const isActiveSource = record.endpointId === routeData?.active_source_id;
    const routeIsLive = LIVE_ROUTE_STATUSES.has(routeStatusNormalized);
    const sourceLooksStale = ['stopped', 'failed'].includes(sourceStatusNormalized);

    if (isActiveSource && routeIsLive && sourceLooksStale) {
      return routeStatus ? String(routeStatus) : undefined;
    }

    return String(sourceStatus);
  };

  const endpointColumns: ColumnsType<EndpointRow> = [
    {
      title: 'Type',
      dataIndex: 'typeLabel',
      key: 'typeLabel',
      width: 200,
      render: (typeLabel, record) => {
        let color = 'default';
        if (record.rowType === 'source') {
          color = record.position === 0 ? 'geekblue' : 'gold';
        }
        const isActiveSource =
          record.rowType === 'source' && record.endpointId === routeData?.active_source_id;

        return (
          <Space size={4} wrap>
            <Tag color={color}>{typeLabel}</Tag>
            {isActiveSource ? (
              <AntTooltip title="This source is live for the route">
                <Tag color="success">Active</Tag>
              </AntTooltip>
            ) : null}
          </Space>
        );
      },
      filters: [
        { text: 'Source', value: 'source' },
        { text: 'Destination', value: 'destination' },
      ],
      onFilter: (value, record) => record.rowType === value,
    },
    {
      title: 'Name',
      dataIndex: 'name',
      key: 'name',
      sorter: (a, b) => String(a.name || '').localeCompare(String(b.name || '')),
      render: (text, record) => (
        <Space>
          <a href={record.rowType === 'source' ? `#/routes/${id}/sources/${record.endpointId}/edit` : `#/routes/${id}/destinations/${record.endpointId}/edit`}>
            {text}
          </a>
        </Space>
      ),
    },
    {
      title: 'Addr',
      key: 'addr',
      render: (_, record) => renderEndpointAddress(record),
      sorter: (a, b) => getEndpointAddressString(a).localeCompare(getEndpointAddressString(b)),
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
      key: 'status',
      width: 160,
      render: (_, record) => renderRuntimeStatusBadge(resolveEndpointStatus(record) ?? undefined),
      filters: [
        { text: 'Starting', value: 'starting' },
        { text: 'Restarting', value: 'restarting' },
        { text: 'Processing', value: 'processing' },
        { text: 'Reconnecting', value: 'reconnecting' },
        { text: 'Completed', value: 'completed' },
        { text: 'Failed', value: 'failed' },
        { text: 'Stopped', value: 'stopped' },
      ],
      onFilter: (value, record) => {
        const endpointStatus = resolveEndpointStatus(record);
        return (endpointStatus || '').toLowerCase() === value;
      },
    },
    {
      title: 'Actions',
      key: 'actions',
      render: (_, record) => {
        const items = [
          {
            key: 'edit',
            icon: <EditOutlined />,
            label: 'Edit',
          },
          ...(record.rowType === 'source'
            ? [
                ...(record.endpointId !== routeData?.active_source_id
                  ? [
                      {
                        key: 'switch_source',
                        icon: <SwapOutlined />,
                        label: 'Switch to this source',
                      },
                    ]
                  : []),
                {
                  key: 'restart_with_source',
                  icon: <ReloadOutlined />,
                  label: 'Restart route with this source',
                },
                {
                  key: 'test',
                  icon: <ApiOutlined />,
                  label: 'Test',
                },
              ]
            : []),
          ...(record.rowType === 'destination'
            ? [{
                key: 'delete',
                icon: <DeleteOutlined />,
                label: routeBusy ? (
                  <AntTooltip title={deleteDisabledMessage}>
                    <span>Delete</span>
                  </AntTooltip>
                ) : 'Delete',
                danger: true,
                disabled: routeBusy,
              }]
            : []),
        ];

        const handleMenuClick = ({ key }: { key: string }) => {
          const endpointId = record.endpointId;
          if (!endpointId) {
            return;
          }

          if (key === 'edit') {
            navigate(record.rowType === 'source' ? `/routes/${id}/sources/${endpointId}/edit` : `/routes/${id}/destinations/${endpointId}/edit`);
            return;
          }

          if (key === 'test') {
            handleTestSource(endpointId);
            return;
          }

          if (key === 'switch_source') {
            handleSwitchSource(endpointId);
            return;
          }

          if (key === 'restart_with_source') {
            handleRestartWithSource(endpointId);
            return;
          }

          if (key === 'delete') {
            handleDeleteDestination(record);
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
            <Button
              icon={<HolderOutlined />}
              aria-label={`Actions for ${record.name}`}
            />
          </Dropdown>
        );
      },
    },
  ];

  // Delete destination handler
  const handleDeleteDestination = (record: EndpointRow) => {
    modal.confirm({
      title: 'Are you sure you want to delete this destination?',
      icon: <ExclamationCircleFilled />,
      content: `Destination: ${record.name}`,
      okText: 'Yes, delete',
      okType: 'danger',
      cancelText: 'No, cancel',
      onOk() {
        return deleteDestination(String(record.endpointId || record.id));
      },
    });
  };

  // Delete destination API call
  const deleteDestination = async (destId: string) => {
    if (!id) {
      return;
    }

    try {
      await destinationsApi.delete(id, destId);
      messageApi.success('Destination deleted successfully');
      fetchRouteData(); // Refresh the data
    } catch (error) {
      messageApi.error(`Failed to delete destination: ${getErrorMessage(error, 'Unknown error')}`);
      console.error('Error:', error);
    }
  };

  const applySwitchedRouteState = (
    prev: RouteRecord | null,
    sourceId: string,
    updatedRoute: RouteRecord | undefined,
  ) => {
    if (!prev) {
      return prev;
    }

    if (!updatedRoute) {
      return {
        ...prev,
        active_source_id: sourceId,
        last_switch_reason: 'manual',
      };
    }

    return {
      ...prev,
      ...updatedRoute,
      sources: updatedRoute.sources || prev.sources,
    };
  };

  const markRouteStartingState = (prev: RouteRecord | null) =>
    prev
      ? {
          ...prev,
          status: 'starting',
          schema_status: 'starting',
        }
      : prev;

  const handleSwitchSource = async (sourceId: string) => {
    if (!id) {
      return;
    }

    try {
      const result = (await routesApi.switchSource(id, sourceId)) as ApiDataResponse<RouteRecord>;
      const updatedRoute = result.data;

      setRouteData((prev) => applySwitchedRouteState(prev, sourceId, updatedRoute));

      messageApi.success('Source switched');
    } catch (error) {
      messageApi.error(`Failed to switch source: ${getErrorMessage(error, 'Unknown error')}`);
    }
  };

  const handleTestSource = async (sourceId: string) => {
    if (!id) {
      return;
    }

    try {
      await sourcesApi.test(id, sourceId);
      messageApi.success('Source test completed');
    } catch (error) {
      messageApi.error(`Failed to test source: ${getErrorMessage(error, 'Unknown error')}`);
    }
  };

  const handleRestartWithSource = async (sourceId: string) => {
    if (!id) {
      return;
    }

    const loading = messageApi.loading('Restarting route with selected source...', 0);
    const routeSnapshot = routeData;

    try {
      setPendingAction('restart');

      if (routeData?.active_source_id !== sourceId) {
        const result = (await routesApi.switchSource(id, sourceId)) as ApiDataResponse<RouteRecord>;
        const updatedRoute = result.data;
        setRouteData((prev) => applySwitchedRouteState(prev, sourceId, updatedRoute));
      }

      setRouteData(markRouteStartingState);
      await routesApi.restart(id);
      await refreshRouteUntilStable('start');
      messageApi.success('Route restarted with selected source');
    } catch (error) {
      setRouteData((prev) => (prev ? routeSnapshot || prev : prev));
      messageApi.error(`Failed to restart with source: ${getErrorMessage(error, 'Unknown error')}`);
    } finally {
      setPendingAction(null);
      loading();
    }
  };

  if (loading || !routeData) {
    return (
      <div style={{ padding: '24px' }}>
        <Card loading={true} />
      </div>
    );
  }

  // Get status details
  const statusDetails = getStatusDetails(routeData);
  const runtimeStatus = routeData?.schema_status || routeData?.status;

  // Route status toggle handler
  const handleRouteStatusToggle = async () => {
    if (!id) {
      return;
    }

    const routeSnapshot = routeData;

    try {
      if (routeBusy) {
        setPendingAction('stop');
        setRouteData((prev) => (prev ? { ...prev, schema_status: 'stopping' } : prev));
        await routesApi.stop(id);
        const settled = await refreshRouteUntilStable('stop');
        messageApi.success('Route stopped successfully');
        if (settled === false) {
          messageApi.warning('Route is still stopping. Refresh in a moment if it does not update.');
        }
      } else {
        setPendingAction('start');
        setRouteData((prev) => (prev ? { ...prev, schema_status: 'starting' } : prev));
        await routesApi.start(id);
        const settled = await refreshRouteUntilStable('start');
        messageApi.success('Route started successfully');
        if (settled === false) {
          messageApi.warning('Route is still starting. Refresh in a moment if it does not update.');
        }
      }
    } catch (error) {
      // Handle specific error cases
      const errorMessage = getErrorMessage(error, 'Unknown error');
      if (errorMessage.includes('already_started')) {
        messageApi.info('Could not confirm the route started. Refreshing its status.');
        try {
          await refreshRouteUntilStable('start', { authoritative: true });
        } catch (refreshError) {
          setRouteData(routeSnapshot);
          messageApi.error(`Failed to refresh route status: ${getErrorMessage(refreshError, 'Unknown error')}`);
          console.error('Error refreshing route status:', refreshError);
        }
      } else if (errorMessage.includes('not_found')) {
        messageApi.info('Route process not found. It may have already been stopped.');
        await fetchRouteData();
      } else if (
        typeof error === 'object' &&
        error !== null &&
        'response' in error &&
        (error as { response?: { status?: number } }).response?.status === 422
      ) {
        // Handle 422 Unprocessable Entity error
        messageApi.error('Invalid request. The server could not process the request.');

        // Keep the current state
        console.error('422 Error:', error);
      } else {
        const action = routeBusy ? 'stop' : 'start';
        messageApi.error(`Failed to ${action} route: ${getErrorMessage(error, 'Unknown error')}`);
      }
      console.error('Error:', error);
    } finally {
      setPendingAction(null);
    }
  };

  // Route deletion handler
  const handleRouteDelete = () => {
    modal.confirm({
      title: 'Are you sure you want to delete this route?',
      icon: <ExclamationCircleFilled />,
      content: `Route: ${routeData.name}`,
      okText: 'Yes, delete',
      okType: 'danger',
      cancelText: 'No, cancel',
      onOk() {
        return deleteRoute();
      },
    });
  };

  // Delete route API call
  const deleteRoute = async () => {
    if (!id) {
      return;
    }

    try {
      await routesApi.delete(id);
      messageApi.success('Route deleted successfully');
      navigate('/routes');
    } catch (error) {
      messageApi.error(`Failed to delete route: ${getErrorMessage(error, 'Unknown error')}`);
      console.error('Error:', error);
    }
  };

  return (
    <Space
      direction="vertical"
      size="large"
      style={{ width: '100%', maxWidth: 1200, margin: '0 auto' }}
    >
      {contextHolder}
      {modalContextHolder}

      <Row justify="space-between" align="middle" gutter={[16, 16]}>
        <Col flex="auto">
          <Space direction="vertical" size="small" style={{ width: '100%' }}>
            <Space align="center" size="middle" wrap>
              <Button
                icon={<ArrowLeftOutlined />}
                onClick={() => navigate(ROUTES.ROUTES)}
              >
                Back
              </Button>
              <Title level={3} style={{ margin: 0, fontSize: '1.75rem', fontWeight: 600 }}>
                {routeData.name}
              </Title>
            </Space>

            <Space size="small" wrap>
              <Tag color={routeData?.enabled ? 'success' : 'error'}>
                Enabled: {routeData?.enabled ? 'Yes' : 'No'}
              </Tag>
              {renderRuntimeStatusBadge(runtimeStatus)}
              <Text type="secondary">
                Last Updated: {new Date(String(routeData.updated_at ?? '')).toLocaleString()}
              </Text>
            </Space>
          </Space>
        </Col>

        <Col>
          <Space wrap>
            <Button
              icon={<EditOutlined />}
              onClick={() => navigate(`/routes/${id}/edit`)}
              disabled={pendingAction != null}
            >
              Edit route
            </Button>
            <AntTooltip
              title={
                !routeBusy && ndiStartBlocked
                  ? 'NDI is not available on this server, so this route cannot start yet.'
                  : null
              }
            >
              <Button
                type={statusDetails.buttonType}
                icon={statusDetails.buttonIcon}
                onClick={handleRouteStatusToggle}
                loading={pendingAction != null}
                disabled={pendingAction != null || (!routeBusy && ndiStartBlocked)}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  minWidth: '80px'
                }}
              >
                {statusDetails.buttonText}
              </Button>
            </AntTooltip>
            <AntTooltip title={routeBusy ? deleteDisabledMessage : null}>
              <Button
                danger
                type="primary"
                icon={<DeleteOutlined />}
                onClick={handleRouteDelete}
                disabled={routeBusy || pendingAction != null}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  minWidth: '80px'
                }}
              >
                Delete
              </Button>
            </AntTooltip>
          </Space>
        </Col>
      </Row>

      <Card
        title="Overview"
        extra={(
          <Space wrap>
            <Select
              value={analyticsWindow}
              onChange={setAnalyticsWindow}
              options={ANALYTICS_WINDOW_OPTIONS}
              style={{ minWidth: 180 }}
            />
            <Button
              icon={<ReloadOutlined />}
              onClick={() => {
                if (analyticsCardTab === 'pipeline_logs') {
                  setPipelineLogsRefreshTick((prev) => prev + 1);
                  return;
                }

                setAnalyticsRefreshTick((prev) => prev + 1);
              }}
              loading={analyticsCardTab === 'pipeline_logs' ? pipelineLogsLoading : analyticsLoading}
              disabled={
                analyticsCardTab !== 'pipeline_logs' &&
                analyticsWindow === LIVE_ANALYTICS_WINDOW
              }
            >
              Refresh
            </Button>
            {analyticsWindow === CUSTOM_ANALYTICS_WINDOW && (
              <>
                <DatePicker
                  showTime
                  value={customRangeDraft[0]}
                  onChange={(value) => setCustomRangeDraft((prev) => [value, prev[1]])}
                  placeholder="Start time"
                />
                <DatePicker
                  showTime
                  value={customRangeDraft[1]}
                  onChange={(value) => setCustomRangeDraft((prev) => [prev[0], value])}
                  placeholder="End time"
                />
                <Button onClick={applyCustomRange}>Apply</Button>
              </>
            )}
          </Space>
        )}
      >
        <Tabs
          activeKey={analyticsCardTab}
          onChange={setAnalyticsCardTab}
          items={[
            {
              key: 'bandwidth',
              label: 'Bandwidth',
              children: (
                <Space direction="vertical" size="middle" style={{ width: '100%' }}>
                  {analyticsError && (
                    <Alert type="error" showIcon message={analyticsError} />
                  )}

                  {!analyticsError && chartData.length === 0 && !analyticsLoading && (
                    <Empty description="No analytics data for selected period" />
                  )}

                  <div style={{ width: '100%', height: chartData.length === 0 && !analyticsLoading ? 0 : 320, overflow: 'hidden' }}>
                    <ResponsiveContainer>
                      <LineChart data={chartData} margin={{ top: 8, right: 20, left: 28, bottom: 8 }}>
                        <CartesianGrid {...CHART_GRID_STYLE} />
                        <XAxis dataKey="xLabel" />
                        <YAxis width={88} tickMargin={8} tickFormatter={(value) => formatBitrate(value)} />
                        <RechartsTooltip content={(props) => renderBandwidthTooltip(props as unknown as BandwidthTooltipProps)} />
                        <Legend />
                        <Line
                          type="monotone"
                          dataKey="source"
                          name={`${routeData.name || 'Source'} Media In`}
                          stroke={ANALYTICS_COLORS[0]}
                          dot={false}
                          isAnimationActive={false}
                          connectNulls
                        />
                        {sourceTimeline.map((segment, index) => (
                          <ReferenceArea
                            key={`${segment.source_id}-${segment.from}-${index}-bg`}
                            x1={formatChartTimestamp(segment.from, analyticsWindow === LIVE_ANALYTICS_WINDOW)}
                            x2={formatChartTimestamp(segment.to, analyticsWindow === LIVE_ANALYTICS_WINDOW)}
                            y1={0}
                            y2={1}
                            ifOverflow="extendDomain"
                            fill={(segment.source_id && sourceColorById[segment.source_id]) || '#d9d9d9'}
                            fillOpacity={0.08}
                            strokeOpacity={0}
                          />
                        ))}
                        <SwitchMarkers
                          switches={switches}
                          isLiveWindow={analyticsWindow === LIVE_ANALYTICS_WINDOW}
                          formatChartTimestamp={formatChartTimestamp}
                        />
                        {destinationSeriesIds.map((destinationId, index) => (
                          <Line
                            key={destinationId}
                            type="monotone"
                            dataKey={`dest_${destinationId}`}
                            name={`${destinationNameById[destinationId] || destinationId} Media Out`}
                            stroke={ANALYTICS_COLORS[(index + 1) % ANALYTICS_COLORS.length]}
                            dot={false}
                            isAnimationActive={false}
                            connectNulls
                          />
                        ))}
                      </LineChart>
                    </ResponsiveContainer>
                  </div>

                  <SourceTimeline
                    sourceTimeline={sourceTimeline}
                    sourceNameById={sourceNameById}
                    formatChartTimestamp={formatChartTimestamp}
                  />
                </Space>
              ),
            },
            {
              key: 'srt_health',
              label: 'SRT Health',
              children: (
                <SrtHealthTab
                  sources={routeData?.sources || []}
                  destinations={routeData?.destinations || []}
                  activeSourceId={routeData?.active_source_id}
                  points={analyticsData?.srt_health || []}
                  totals={analyticsData?.srt_totals || []}
                  resets={analyticsData?.stats_resets || []}
                  loading={analyticsLoading}
                  error={analyticsError}
                  routeActive={!isTerminalRuntimeStatus(routeData?.schema_status || routeData?.status)}
                />
              ),
            },
            ...(hasNdiEndpoints
              ? [{
                  key: 'ndi_health',
                  label: 'NDI Health',
                  children: (
                    <NdiHealthTab
                      routeId={id as string}
                      sources={routeData?.sources || []}
                      destinations={routeData?.destinations || []}
                      activeSourceId={routeData?.active_source_id}
                      routeActive={!isTerminalRuntimeStatus(routeData?.schema_status || routeData?.status)}
                      onRestartWithSource={(sourceId) => {
                        void handleRestartWithSource(sourceId);
                      }}
                      onStop={() => {
                        if (!routeBusy) {
                          return;
                        }
                        void handleRouteStatusToggle();
                      }}
                      onTestEndpoint={(endpointId) => {
                        void ndiApi.probe({ endpoint_id: endpointId }).then(() => {
                          messageApi.success('NDI probe completed');
                        }).catch((error) => {
                          messageApi.error(getErrorMessage(error, 'NDI probe failed'));
                        });
                      }}
                    />
                  ),
                }]
              : []),
            ...(hasYoutubeSources
              ? [{
                  key: 'youtube_health',
                  label: 'YouTube Health',
                  children: (
                    <YoutubeHealthTab
                      routeId={id as string}
                      sources={routeData?.sources || []}
                      routeActive={!isTerminalRuntimeStatus(routeData?.schema_status || routeData?.status)}
                    />
                  ),
                }]
              : []),
            {
              key: 'pipeline_logs',
              label: 'Pipeline Logs',
              children: (
                <PipelineLogsTab
                  routeId={id as string}
                  active={analyticsCardTab === 'pipeline_logs'}
                  analyticsWindow={analyticsWindow}
                  customRangeApplied={customRangeApplied}
                  refreshTick={pipelineLogsRefreshTick}
                  onLoadingChange={setPipelineLogsLoading}
                />
              ),
            },
          ]}
        />
      </Card>

      <Card
        title="Endpoints"
        extra={
          <Button
            type="primary"
            icon={<PlusOutlined />}
            onClick={() => navigate(`/routes/${id}/destinations/new/edit`)}
          >
            Add Destination
          </Button>
        }
      >
        <Input
          prefix={<SearchOutlined />}
          placeholder="Filter endpoints by name or address"
          style={{ marginBottom: 16, width: '100%' }}
          value={destinationFilter}
          onChange={(e) => setDestinationFilter(e.target.value)}
        />
        <Table
          columns={endpointColumns}
          dataSource={endpointsData}
          rowKey="id"
          pagination={{
            defaultPageSize: 10,
            showSizeChanger: true,
            showTotal: (total) => `Total ${total} endpoints`,
          }}
          scroll={{ x: true }}
          rowClassName={(record) => (record.rowType === 'source' ? 'route-endpoint-source-row' : '')}
        />
      </Card>
    </Space>
  );
};

export default RouteItem;
