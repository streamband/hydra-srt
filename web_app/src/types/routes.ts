import type { ReactNode } from 'react';
import type { BadgeProps } from 'antd';
import type { NdiEndpointFields, NdiEndpointHealthRecord } from './ndi';
import type { YoutubeEndpointFields } from './youtube';

/** Shared route/domain shapes for the routes UI (API payloads are partially typed). */

export type RouteEndpoint = Record<string, unknown> & NdiEndpointFields & YoutubeEndpointFields & {
  id?: string;
  name?: string;
  enabled?: boolean;
  schema?: string;
  mode?: string;
  position?: number;
  host?: string;
  port?: number;
  program_number?: number | null;
  address?: string;
  localaddress?: string;
  multicast?: boolean;
  multicast_iface?: string;
  bind_address_option?: string;
  path?: string;
  location?: string;
};

export type RouteEndpointHealthMap = Record<string, NdiEndpointHealthRecord>;

export type RouteRecord = Record<string, unknown> & {
  id: string;
  name?: string;
  status?: string;
  schema_status?: string;
  started_at?: string;
  active_source_id?: string;
  last_switch_reason?: string;
  sources?: RouteEndpoint[];
  destinations?: RouteEndpoint[];
  source?: RouteEndpoint;
  tags?: string[];
  node?: string;
  enabled?: boolean;
};

export type RouteTag = {
  id?: string;
  name: string;
};

export type PaginationMeta = {
  page?: number;
  page_size?: number;
  total?: number;
};

export type ListResponse<T> = {
  data?: T[];
  meta?: PaginationMeta;
};

export type RouteFormValues = Record<string, unknown> & {
  enabled?: boolean;
  name?: string;
  node?: string;
  backup_mode?: string;
  backup_switch_after_ms?: number;
  backup_cooldown_ms?: number;
  backup_primary_stable_ms?: number;
  backup_probe_interval_ms?: number;
  sources?: RouteEndpoint[];
  destinations?: RouteEndpoint[];
  tags?: string[];
};

export type SourceProgram = {
  program_number: number;
  pmt_pid: number;
  pcr_pid: number;
  name: string | null;
  streams: Array<{
    codec_type: string;
    codec_name: string;
  }>;
};

export type SourceTestResult = Record<string, unknown> & {
  programs?: SourceProgram[];
  streams?: unknown[];
};

export type SwitchEvent = {
  ts?: string;
};

export type TimelineSegment = {
  source_id?: string;
  from?: string;
  to?: string;
};

export type RouteActiveSourceView = {
  sources?: Array<Pick<RouteEndpoint, 'id' | 'name' | 'position'>>;
  active_source_id?: string | number;
  last_switch_reason?: string;
  last_switch_at?: string;
};

export type RouteSourceEditProps = {
  initialValues?: Partial<RouteFormValues>;
  onChange?: ((values: RouteFormValues) => void) | null;
};

export type RouteAction = 'start' | 'stop';
export type RoutePendingAction = 'start' | 'stop' | 'restart' | null;

export type AnalyticsPoint = Record<string, unknown> & {
  timestamp?: string;
  source?: number | null;
  destinations?: Record<string, number | null>;
};

export type SrtHealthPoint = {
  timestamp?: string;
  entity_type?: 'source' | 'destination';
  entity_id?: string;
  rtt_ms?: number | null;
  negotiated_latency_ms?: number | null;
  bandwidth_mbps?: number | null;
  rate_mbps?: number | null;
  packet_loss_percent?: number | null;
  retransmitted_packets_per_sec?: number | null;
  dropped_packets_per_sec?: number | null;
  nack_packets_per_sec?: number | null;
  packets_lost_total?: number | null;
  rtt_ms_max?: number | null;
  packet_loss_percent_max?: number | null;
  retransmitted_packets_per_sec_max?: number | null;
  dropped_packets_per_sec_max?: number | null;
  nack_packets_per_sec_max?: number | null;
};

export type SrtTotalsEntry = {
  entity_type?: 'source' | 'destination';
  entity_id?: string;
  packets_total?: number | null;
  packets_lost_total?: number | null;
  packets_retransmitted_total?: number | null;
  packets_dropped_total?: number | null;
  nack_total?: number | null;
  bytes_total?: number | null;
  loss_percent?: number | null;
};

export type StatsResetMarker = {
  timestamp?: string;
  reason?: string | null;
};

export type AnalyticsMeta = Record<string, unknown> | null;

export type AnalyticsData = {
  points: AnalyticsPoint[];
  meta: AnalyticsMeta;
  switches?: unknown[];
  source_timeline?: unknown[];
  srt_quality?: unknown[];
  srt_health?: SrtHealthPoint[];
  srt_totals?: SrtTotalsEntry[];
  stats_resets?: StatsResetMarker[];
};

export type StatusHistoryEvent = Record<string, unknown>;

export type StatusHistoryData = {
  events: StatusHistoryEvent[];
  meta: Record<string, unknown> | null;
};

export type StatusAnalyticsData = {
  points: AnalyticsPoint[];
  meta: Record<string, unknown> | null;
};

export type StatsSinceReset = {
  reset_at?: string;
  rebased_at?: string | null;
  source?: Record<string, unknown>;
  destinations?: Array<Record<string, unknown>>;
} & Record<string, unknown>;

export type RouteStatsEntry = {
  in?: number;
  snapshot?: unknown;
  outByDestination?: Record<string, number>;
};

export type RouteStatsMap = Record<string, RouteStatsEntry>;

export type TagOption = { label: string; value: string };

export type PendingRouteActionsMap = Record<string, RouteAction | undefined>;

export type TimeRangeQuery = {
  from?: string;
  to?: string;
  window?: string;
  limit?: number;
  offset?: number;
};

export type StatsTreeNode = {
  title: ReactNode;
  key: string;
  children?: StatsTreeNode[];
};

export type RuntimeStatusMeta = {
  badgeStatus: NonNullable<BadgeProps['status']>;
  label: string;
};

export type LiveSnapshotBuffer = {
  timestamp: string;
  source: number | null;
  destinations: Record<string, number | null>;
  srtHealth: SrtHealthPoint[];
} | null;
