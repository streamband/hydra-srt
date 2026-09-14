import { QuestionCircleOutlined } from '@ant-design/icons';
import { Alert, Card, Col, Empty, Row, Select, Space, Statistic, Tooltip, Typography } from 'antd';
import { useEffect, useMemo, useState } from 'react';
import {
  CartesianGrid,
  Legend,
  Line,
  LineChart,
  ReferenceLine,
  ResponsiveContainer,
  Tooltip as ChartTooltip,
  XAxis,
  YAxis,
} from 'recharts';
import type { RouteEndpoint, SrtHealthPoint, SrtTotalsEntry, StatsResetMarker } from '../../types/routes';

const { Text, Title } = Typography;

type Props = {
  sources: RouteEndpoint[];
  destinations: RouteEndpoint[];
  activeSourceId?: string;
  points: SrtHealthPoint[];
  totals?: SrtTotalsEntry[];
  resets?: StatsResetMarker[];
  loading: boolean;
  error: string | null;
  routeActive?: boolean;
};

type ChartSeries = {
  key: keyof SrtHealthPoint;
  name: string;
  color: string;
  maxKey?: keyof SrtHealthPoint;
};

const isSrt = (endpoint: RouteEndpoint) =>
  String(endpoint.schema || '').toLowerCase() === 'srt';

const endpointValue = (type: 'source' | 'destination', id: string) => `${type}:${id}`;

const formatTimestamp = (value?: string) => {
  if (!value) return '';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
};

const numeric = (value: number | null | undefined) =>
  typeof value === 'number' && Number.isFinite(value) ? value : null;

const formatCount = (value: number | null | undefined) => {
  const n = numeric(value);
  return n == null ? '-' : n.toLocaleString();
};

const formatBytes = (value: number | null | undefined): string => {
  const n = numeric(value);
  if (n == null) return '-';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let normalized = Math.max(0, n);
  let unitIndex = 0;
  while (normalized >= 1000 && unitIndex < units.length - 1) {
    normalized /= 1000;
    unitIndex += 1;
  }
  const precision = normalized >= 100 ? 0 : normalized >= 10 ? 1 : 2;
  return `${normalized.toFixed(precision)} ${units[unitIndex]}`;
};

const PEAK_LINE_HELP =
  ' Solid line: bucket average. Dashed line: highest one-second sample in the bucket.';

const METRIC_HELP = {
  rtt: `Smoothed round-trip time (SRTT), calculated as an EWMA of RTT samples. Unit: milliseconds. Available for sender and receiver.${PEAK_LINE_HELP}`,
  senderLoss: `Percentage derived from sender-side DATA packets considered or reported lost during the interval.${PEAK_LINE_HELP}`,
  receiverLoss: `Percentage derived from receiver-side DATA packets detected as presently missing during the interval.${PEAK_LINE_HELP}`,
  senderLatency: 'Timestamp-based packet delivery delay reported by the sender for its peer receiver. Unit: milliseconds.',
  receiverLatency: 'Timestamp-based packet delivery delay configured on the receiver socket. Unit: milliseconds.',
  bandwidth: 'Estimated network-link bandwidth. The receiver estimates it from probe-packet arrival spacing and reports the running average to the sender. Unit: Mbps.',
  sendRate: 'SRT sending rate measured for the statistics interval. Sender side. Unit: Mbps.',
  receiveRate: 'SRT receiving rate measured for the statistics interval. Receiver side. Unit: Mbps.',
  senderRetransmitted: `Number of retransmitted DATA packets sent by the SRT sender during the interval.${PEAK_LINE_HELP}`,
  receiverRetransmitted: `Number of retransmitted DATA packets registered by the SRT receiver during the interval.${PEAK_LINE_HELP}`,
  senderDropped: `Sender-side DATA packets dropped because they could not be delivered in time during the interval.${PEAK_LINE_HELP}`,
  receiverDropped: `Receiver-side DATA packets dropped and therefore not delivered to the upstream application during the interval.${PEAK_LINE_HELP}`,
  senderNak: `NAK (Negative Acknowledgement) control packets received by the sender during the interval.${PEAK_LINE_HELP}`,
  receiverNak: `NAK (Negative Acknowledgement) control packets sent by the receiver during the interval.${PEAK_LINE_HELP}`,
} as const;

const STATISTICS_URL = 'https://github.com/Haivision/srt/blob/master/docs/API/statistics.md';

/**
 * SRT reports the link-capacity estimate in Mbps, and on a LAN or loopback that runs into
 * the thousands. Rendering "1800 Mbps" next to a single-digit send rate reads as a broken
 * axis, so switch to Gbps once the number leaves the range a stream is measured in.
 */
const GBPS_THRESHOLD_MBPS = 1000;

const formatLinkRate = (valueMbps: number): string =>
  Math.abs(valueMbps) >= GBPS_THRESHOLD_MBPS
    ? `${(valueMbps / 1000).toFixed(2)} Gbps`
    : `${valueMbps.toFixed(2)} Mbps`;

const MetricTitle = ({
  label,
  help,
  anchor,
}: {
  label: string;
  help: string;
  anchor?: string;
}) => (
  <Space size={6}>
    <span>{label}</span>
    <Tooltip
      title={(
        <Space direction="vertical" size={4}>
          <span>{help}</span>
          <a
            href={`${STATISTICS_URL}${anchor ? `#${anchor}` : ''}`}
            target="_blank"
            rel="noreferrer"
          >
            More
          </a>
        </Space>
      )}
      styles={{ root: { maxWidth: 420 } }}
    >
      <QuestionCircleOutlined
        aria-label={`About ${label}`}
        style={{ color: 'rgba(255, 255, 255, 0.45)', fontSize: 13 }}
      />
    </Tooltip>
  </Space>
);

const SrtHealthTab = ({
  sources,
  destinations,
  activeSourceId,
  points,
  totals = [],
  resets = [],
  loading,
  error,
  routeActive = true,
}: Props) => {
  const srtSources = useMemo(() => sources.filter(isSrt).filter((endpoint) => endpoint.id), [sources]);
  const srtDestinations = useMemo(
    () => destinations.filter(isSrt).filter((endpoint) => endpoint.id),
    [destinations],
  );
  const defaultValue = useMemo(() => {
    const active = srtSources.find((source) => source.id === activeSourceId);
    if (active?.id) return endpointValue('source', active.id);
    if (srtSources[0]?.id) return endpointValue('source', srtSources[0].id);
    if (srtDestinations[0]?.id) return endpointValue('destination', srtDestinations[0].id);
    return undefined;
  }, [activeSourceId, srtDestinations, srtSources]);
  const [selected, setSelected] = useState<string | undefined>(defaultValue);

  useEffect(() => {
    const available = [
      ...srtSources.map((endpoint) => endpointValue('source', String(endpoint.id))),
      ...srtDestinations.map((endpoint) => endpointValue('destination', String(endpoint.id))),
    ];
    if (!selected || !available.includes(selected)) setSelected(defaultValue);
  }, [defaultValue, selected, srtDestinations, srtSources]);

  const [entityType, entityId] = selected?.split(':') || [];
  const selectedPoints = useMemo(
    () =>
      points
        .filter((point) => point.entity_type === entityType && point.entity_id === entityId)
        .sort((a, b) => Date.parse(a.timestamp || '') - Date.parse(b.timestamp || ''))
        .map((point) => ({ ...point, time: formatTimestamp(point.timestamp) })),
    [entityId, entityType, points],
  );
  const selectedTotals = useMemo(
    () => totals.find((entry) => entry.entity_type === entityType && entry.entity_id === entityId),
    [entityId, entityType, totals],
  );
  const chartResetMarkers = useMemo(() => {
    if (resets.length === 0 || selectedPoints.length === 0) {
      return [];
    }

    const minTs = Date.parse(selectedPoints[0].timestamp || '');
    const maxTs = Date.parse(selectedPoints[selectedPoints.length - 1].timestamp || '');
    if (Number.isNaN(minTs) || Number.isNaN(maxTs)) {
      return [];
    }

    return resets.flatMap((reset, index) => {
      const resetTs = Date.parse(reset.timestamp || '');
      if (Number.isNaN(resetTs) || resetTs < minTs || resetTs > maxTs) {
        return [];
      }

      let nearest = selectedPoints[0];
      let nearestDiff = Math.abs(Date.parse(nearest.timestamp || '') - resetTs);
      for (const point of selectedPoints) {
        const pointTs = Date.parse(point.timestamp || '');
        if (Number.isNaN(pointTs)) {
          continue;
        }
        const diff = Math.abs(pointTs - resetTs);
        if (diff < nearestDiff) {
          nearest = point;
          nearestDiff = diff;
        }
      }

      if (!nearest.time) {
        return [];
      }

      const reason = String(reset.reason || '').toLowerCase();
      const label = reason === 'cleared' ? 'C' : 'R';

      return [{
        key: `reset-${reset.timestamp}-${index}`,
        time: nearest.time,
        label,
      }];
    });
  }, [resets, selectedPoints]);

  const hasMaxData = (maxKey: keyof SrtHealthPoint) =>
    selectedPoints.some((point) => numeric(point[maxKey] as number | null | undefined) != null);

  const latest = selectedPoints[selectedPoints.length - 1];
  const displayLatest = routeActive ? latest : undefined;
  const bandwidth = numeric(displayLatest?.bandwidth_mbps);
  const rateLabel = entityType === 'source' ? 'Receive rate' : 'Send rate';
  const isReceiver = entityType === 'source';
  const metricHelp: Record<string, string> = {
    'Receive rate': METRIC_HELP.receiveRate,
    'Send rate': METRIC_HELP.sendRate,
    'Estimated bandwidth': METRIC_HELP.bandwidth,
    Retransmitted: isReceiver
      ? METRIC_HELP.receiverRetransmitted
      : METRIC_HELP.senderRetransmitted,
    Dropped: isReceiver ? METRIC_HELP.receiverDropped : METRIC_HELP.senderDropped,
    NAK: isReceiver ? METRIC_HELP.receiverNak : METRIC_HELP.senderNak,
    'RTT (peak)': METRIC_HELP.rtt,
    'Loss (peak)': isReceiver ? METRIC_HELP.receiverLoss : METRIC_HELP.senderLoss,
    'Retransmitted (peak)': isReceiver
      ? METRIC_HELP.receiverRetransmitted
      : METRIC_HELP.senderRetransmitted,
    'Dropped (peak)': isReceiver ? METRIC_HELP.receiverDropped : METRIC_HELP.senderDropped,
    'NAK (peak)': isReceiver ? METRIC_HELP.receiverNak : METRIC_HELP.senderNak,
  };
  const metricAnchors: Record<string, string> = {
    'Receive rate': 'mbpsrecvrate',
    'Send rate': 'mbpssendrate',
    'Estimated bandwidth': 'mbpsbandwidth',
    Retransmitted: isReceiver ? 'pktrcvretrans' : 'pktretrans',
    Dropped: isReceiver ? 'pktrcvdrop' : 'pktsnddrop',
    NAK: isReceiver ? 'pktsentnak' : 'pktrecvnak',
    'RTT (peak)': 'msrtt',
    'Loss (peak)': isReceiver ? 'pktrcvloss' : 'pktsndloss',
    'Retransmitted (peak)': isReceiver ? 'pktrcvretrans' : 'pktretrans',
    'Dropped (peak)': isReceiver ? 'pktrcvdrop' : 'pktsnddrop',
    'NAK (peak)': isReceiver ? 'pktsentnak' : 'pktrecvnak',
  };

  if (srtSources.length === 0 && srtDestinations.length === 0) {
    return <Empty description="This route has no SRT endpoints" />;
  }

  const options = [
    ...(srtSources.length
      ? [{
          label: 'Sources',
          options: srtSources.map((endpoint) => ({
            label: endpoint.name || endpoint.id,
            value: endpointValue('source', String(endpoint.id)),
          })),
        }]
      : []),
    ...(srtDestinations.length
      ? [{
          label: 'Destinations',
          options: srtDestinations.map((endpoint) => ({
            label: endpoint.name || endpoint.id,
            value: endpointValue('destination', String(endpoint.id)),
          })),
        }]
      : []),
  ];

  const resetMarkerLines = chartResetMarkers.map((marker) => (
    <ReferenceLine
      key={marker.key}
      x={marker.time}
      stroke="#8c8c8c"
      strokeDasharray="3 3"
      label={{ value: marker.label, position: 'top', fill: '#8c8c8c', fontSize: 10 }}
    />
  ));

  const chart = (
    dataKeys: ChartSeries[],
    unit: string,
  ) => (
    <div style={{ width: '100%', height: 240 }}>
      <ResponsiveContainer>
        <LineChart data={selectedPoints} margin={{ top: 8, right: 20, left: 12, bottom: 8 }}>
          <CartesianGrid stroke="#4f4f4f" strokeWidth={0.6} strokeDasharray="2 4" />
          <XAxis dataKey="time" />
          <YAxis unit={unit} width={72} />
          <ChartTooltip />
          {dataKeys.length > 1 && (
            <Legend
              formatter={(value) => (
                <MetricTitle
                  label={String(value)}
                  help={metricHelp[String(value)] || String(value)}
                  anchor={metricAnchors[String(value)]}
                />
              )}
            />
          )}
          {dataKeys.flatMap((item) => {
            const lines = [
              <Line
                key={String(item.key)}
                type="monotone"
                dataKey={item.key}
                name={item.name}
                stroke={item.color}
                dot={false}
                connectNulls
                isAnimationActive={false}
              />,
            ];
            if (item.maxKey && hasMaxData(item.maxKey)) {
              lines.push(
                <Line
                  key={String(item.maxKey)}
                  type="monotone"
                  dataKey={item.maxKey}
                  name={`${item.name} (peak)`}
                  stroke={item.color}
                  strokeDasharray="3 3"
                  strokeOpacity={0.55}
                  dot={false}
                  connectNulls
                  isAnimationActive={false}
                />,
              );
            }
            return lines;
          })}
          {resetMarkerLines}
        </LineChart>
      </ResponsiveContainer>
    </div>
  );

  // One unit for the whole bandwidth axis, chosen from its peak, so ticks don't mix
  // "900 Mbps" with "1.80 Gbps" on the same scale.
  const bandwidthPeakMbps = selectedPoints.reduce(
    (peak, point) => Math.max(peak, numeric(point.bandwidth_mbps) ?? 0),
    0,
  );
  const bandwidthInGbps = bandwidthPeakMbps >= GBPS_THRESHOLD_MBPS;

  const rateAndBandwidthChart = (
    <div style={{ width: '100%', height: 240 }}>
      <ResponsiveContainer>
        <LineChart data={selectedPoints} margin={{ top: 8, right: 20, left: 12, bottom: 8 }}>
          <CartesianGrid stroke="#4f4f4f" strokeWidth={0.6} strokeDasharray="2 4" />
          <XAxis dataKey="time" />
          <YAxis
            yAxisId="rate"
            width={72}
            unit=" Mbps"
            stroke="#1677ff"
            domain={[0, 'auto']}
          />
          <YAxis
            yAxisId="bandwidth"
            orientation="right"
            width={72}
            unit={bandwidthInGbps ? ' Gbps' : ' Mbps'}
            stroke="#52c41a"
            domain={[0, 'auto']}
            tickFormatter={(value) => (bandwidthInGbps ? (Number(value) / 1000).toFixed(2) : String(value))}
          />
          <ChartTooltip formatter={(value) => formatLinkRate(Number(value))} />
          <Legend
            formatter={(value) => (
              <MetricTitle
                label={String(value)}
                help={metricHelp[String(value)] || String(value)}
                anchor={metricAnchors[String(value)]}
              />
            )}
          />
          <Line
            yAxisId="rate"
            type="monotone"
            dataKey="rate_mbps"
            name={rateLabel}
            stroke="#1677ff"
            dot={false}
            connectNulls
            isAnimationActive={false}
          />
          <Line
            yAxisId="bandwidth"
            type="monotone"
            dataKey="bandwidth_mbps"
            name="Estimated bandwidth"
            stroke="#52c41a"
            dot={false}
            connectNulls
            isAnimationActive={false}
          />
          {resetMarkerLines}
        </LineChart>
      </ResponsiveContainer>
    </div>
  );

  return (
    <Space direction="vertical" size="large" style={{ width: '100%' }}>
      <Select
        aria-label="SRT endpoint"
        value={selected}
        options={options}
        onChange={setSelected}
        style={{ minWidth: 320 }}
      />

      {error && <Alert type="error" showIcon message={error} />}
      {!routeActive && selectedPoints.length > 0 && (
        <Alert
          type="info"
          showIcon
          message="Route is stopped. Charts show the last collected metrics; current values are unavailable."
        />
      )}
      {!error && !loading && selectedPoints.length === 0 && (
        <Empty description="No SRT health data for this endpoint and time range" />
      )}

      {selectedPoints.length > 0 && (
        <>
          {selectedTotals && (
            <div>
              <Title level={5}>Totals for the selected window</Title>
              <Text type="secondary">
                Increases over the selected time range from cumulative SRT counters, unaffected by chart smoothing.
              </Text>
              <Row gutter={[12, 12]} style={{ marginTop: 12 }}>
                <Col xs={12} lg={6} xl={4}>
                  <Card size="small">
                    <Statistic title="Packets" value={formatCount(selectedTotals.packets_total)} />
                  </Card>
                </Col>
                <Col xs={12} lg={6} xl={4}>
                  <Card size="small">
                    <Statistic title="Lost" value={formatCount(selectedTotals.packets_lost_total)} />
                  </Card>
                </Col>
                <Col xs={12} lg={6} xl={4}>
                  <Card size="small">
                    <Statistic
                      title="Retransmitted"
                      value={formatCount(selectedTotals.packets_retransmitted_total)}
                    />
                  </Card>
                </Col>
                <Col xs={12} lg={6} xl={4}>
                  <Card size="small">
                    <Statistic title="Dropped" value={formatCount(selectedTotals.packets_dropped_total)} />
                  </Card>
                </Col>
                <Col xs={12} lg={6} xl={4}>
                  <Card size="small">
                    <Statistic title="NAK" value={formatCount(selectedTotals.nack_total)} />
                  </Card>
                </Col>
                <Col xs={12} lg={6} xl={4}>
                  <Card size="small">
                    <Statistic title="Bytes" value={formatBytes(selectedTotals.bytes_total)} />
                  </Card>
                </Col>
                <Col xs={12} lg={6} xl={4}>
                  <Card size="small">
                    <Statistic
                      title="Loss %"
                      value={numeric(selectedTotals.loss_percent) ?? '-'}
                      precision={2}
                      suffix={numeric(selectedTotals.loss_percent) != null ? '%' : undefined}
                    />
                  </Card>
                </Col>
              </Row>
            </div>
          )}

          <div>
            <Title level={5}>
              <MetricTitle
                label="Quality"
                help="Instantaneous and interval-based SRT socket statistics used to assess connection quality."
                anchor="srt-socket-statistics"
              />
            </Title>
            <Row gutter={[12, 12]}>
              <Col xs={12} lg={6}>
                <Card size="small">
                  <Statistic
                    title={<MetricTitle label="RTT" help={METRIC_HELP.rtt} anchor="msrtt" />}
                    value={numeric(displayLatest?.rtt_ms) ?? '-'}
                    suffix="ms"
                  />
                </Card>
              </Col>
              <Col xs={12} lg={6}>
                <Card size="small">
                  <Statistic
                    title={
                      <MetricTitle
                        label="Loss"
                        help={isReceiver ? METRIC_HELP.receiverLoss : METRIC_HELP.senderLoss}
                        anchor={isReceiver ? 'pktrcvloss' : 'pktsndloss'}
                      />
                    }
                    value={numeric(displayLatest?.packet_loss_percent) ?? '-'}
                    precision={2}
                    suffix="%"
                  />
                </Card>
              </Col>
              <Col xs={12} lg={6}>
                <Card size="small">
                  <Statistic
                    title={
                      <MetricTitle
                        label="Latency"
                        help={isReceiver ? METRIC_HELP.receiverLatency : METRIC_HELP.senderLatency}
                        anchor={isReceiver ? 'msrcvtsbpddelay' : 'mssndtsbpddelay'}
                      />
                    }
                    value={numeric(displayLatest?.negotiated_latency_ms) ?? '-'}
                    suffix="ms"
                  />
                </Card>
              </Col>
              <Col xs={12} lg={6}>
                <Card size="small">
                  <Statistic
                    title={
                      <MetricTitle
                        label="Estimated bandwidth"
                        help={METRIC_HELP.bandwidth}
                        anchor="mbpsbandwidth"
                      />
                    }
                    value={
                      bandwidth === undefined || bandwidth === null
                        ? '-'
                        : bandwidth >= GBPS_THRESHOLD_MBPS
                          ? bandwidth / 1000
                          : bandwidth
                    }
                    precision={2}
                    suffix={
                      bandwidth !== undefined && bandwidth !== null && bandwidth >= GBPS_THRESHOLD_MBPS
                        ? 'Gbps'
                        : 'Mbps'
                    }
                  />
                </Card>
              </Col>
            </Row>
          </div>

          <Row gutter={[16, 16]}>
            <Col xs={24} xl={12}>
              <Card
                size="small"
                title={
                  <MetricTitle label="Round-trip time" help={METRIC_HELP.rtt} anchor="msrtt" />
                }
              >
                {chart([{ key: 'rtt_ms', name: 'RTT', color: '#1677ff', maxKey: 'rtt_ms_max' }], ' ms')}
              </Card>
            </Col>
            <Col xs={24} xl={12}>
              <Card
                size="small"
                title={
                  <MetricTitle
                    label="Packet loss"
                    help={isReceiver ? METRIC_HELP.receiverLoss : METRIC_HELP.senderLoss}
                    anchor={isReceiver ? 'pktrcvloss' : 'pktsndloss'}
                  />
                }
              >
                {chart([{
                  key: 'packet_loss_percent',
                  name: 'Loss',
                  color: '#ff4d4f',
                  maxKey: 'packet_loss_percent_max',
                }], '%')}
              </Card>
            </Col>
            <Col span={24}>
              <Card
                size="small"
                title={
                  <MetricTitle
                    label={`${rateLabel} and estimated bandwidth`}
                    help={`${metricHelp[rateLabel]} ${METRIC_HELP.bandwidth}`}
                    anchor={metricAnchors[rateLabel]}
                  />
                }
                extra={
                  <Text type="secondary">
                    {`Rate left · bandwidth right (${bandwidthInGbps ? 'Gbps' : 'Mbps'})`}
                  </Text>
                }
              >
                {rateAndBandwidthChart}
              </Card>
            </Col>
          </Row>

          <div>
            <Title level={5}>
              <MetricTitle
                label="Recovery"
                help="Interval statistics for SRT retransmission, packet drop, and NAK control traffic."
                anchor="interval-based-statistics"
              />
            </Title>
            <Text type="secondary">Interval rates reported by the selected SRT socket.</Text>
            <Card size="small" style={{ marginTop: 12 }}>
              {chart([
                {
                  key: 'retransmitted_packets_per_sec',
                  name: 'Retransmitted',
                  color: '#faad14',
                  maxKey: 'retransmitted_packets_per_sec_max',
                },
                {
                  key: 'dropped_packets_per_sec',
                  name: 'Dropped',
                  color: '#ff4d4f',
                  maxKey: 'dropped_packets_per_sec_max',
                },
                {
                  key: 'nack_packets_per_sec',
                  name: 'NAK',
                  color: '#722ed1',
                  maxKey: 'nack_packets_per_sec_max',
                },
              ], '/s')}
            </Card>
          </div>
        </>
      )}
    </Space>
  );
};

export default SrtHealthTab;
