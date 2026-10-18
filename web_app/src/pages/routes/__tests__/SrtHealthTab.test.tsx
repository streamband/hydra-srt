import { fireEvent, render, screen, within } from '@testing-library/react';
import type { ReactNode } from 'react';
import { describe, expect, it, vi } from 'vitest';
import SrtHealthTab from '../SrtHealthTab';

vi.mock('recharts', () => {
  const Mock = ({ children }: { children?: ReactNode }) => <div>{children}</div>;
  const Line = ({
    name,
    dataKey,
    strokeDasharray,
  }: {
    name?: string;
    dataKey?: string;
    strokeDasharray?: string;
  }) => (
    <div
      data-testid={`line-${dataKey}`}
      data-name={name}
      data-peak={strokeDasharray ? 'true' : 'false'}
    />
  );
  const ReferenceLine = ({
    x,
    label,
  }: {
    x?: string;
    label?: { value?: string };
  }) => (
    <div data-testid="reset-marker" data-x={x}>
      {label?.value}
    </div>
  );

  return {
    ResponsiveContainer: Mock,
    LineChart: Mock,
    CartesianGrid: () => null,
    XAxis: () => null,
    YAxis: () => null,
    Line,
    ReferenceLine,
    Legend: () => null,
    Tooltip: () => null,
  };
});

const baseSource = { id: 's1', name: 'Primary SRT', schema: 'SRT' };

const basePoint = {
  timestamp: '2026-07-02T20:00:00Z',
  entity_type: 'source' as const,
  entity_id: 's1',
  rtt_ms: 12,
  packet_loss_percent: 0.25,
  negotiated_latency_ms: 120,
  bandwidth_mbps: 8,
  rate_mbps: 2,
  retransmitted_packets_per_sec: 3,
  dropped_packets_per_sec: 1,
  nack_packets_per_sec: 2,
};

describe('SrtHealthTab', () => {
  it('groups SRT endpoints and shows active source health', async () => {
    render(
      <SrtHealthTab
        sources={[{ id: 's1', name: 'Primary SRT', schema: 'SRT' }]}
        destinations={[
          { id: 'd1', name: 'SRT Output', schema: 'SRT' },
          { id: 'd2', name: 'UDP Output', schema: 'UDP' },
        ]}
        activeSourceId="s1"
        loading={false}
        error={null}
        points={[{
          timestamp: '2026-07-02T20:00:00Z',
          entity_type: 'source',
          entity_id: 's1',
          rtt_ms: 12,
          packet_loss_percent: 0.25,
          negotiated_latency_ms: 120,
          bandwidth_mbps: 8,
          rate_mbps: 2,
          retransmitted_packets_per_sec: 3,
          dropped_packets_per_sec: 1,
          nack_packets_per_sec: 2,
        }]}
      />,
    );

    expect(screen.getByText('Quality')).toBeInTheDocument();
    expect(screen.getByText('Recovery')).toBeInTheDocument();
    expect(screen.getByText('12')).toBeInTheDocument();
    expect(screen.getByText('Estimated bandwidth').closest('.ant-statistic')).toHaveTextContent(
      '8.00Mbps',
    );
    expect(screen.getByText('Receive rate and estimated bandwidth')).toBeInTheDocument();
    expect(screen.getByText('Rate left · bandwidth right (Mbps)')).toBeInTheDocument();

    fireEvent.mouseEnter(screen.getAllByLabelText('About RTT')[0]);
    expect(
      await screen.findByText(/Smoothed round-trip time \(SRTT\)/),
    ).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'More' })).toHaveAttribute(
      'href',
      'https://github.com/Haivision/srt/blob/master/docs/API/statistics.md#msrtt',
    );

    fireEvent.mouseDown(screen.getByRole('combobox', { name: 'SRT endpoint' }));
    expect(screen.getByText('Sources')).toBeInTheDocument();
    expect(screen.getByText('Destinations')).toBeInTheDocument();
    expect(screen.queryByText('UDP Output')).not.toBeInTheDocument();
  });

  it('hides current metrics when the route is stopped but keeps chart history', () => {
    render(
      <SrtHealthTab
        sources={[{ id: 's1', name: 'Primary SRT', schema: 'SRT' }]}
        destinations={[]}
        activeSourceId="s1"
        loading={false}
        error={null}
        routeActive={false}
        points={[{
          timestamp: '2026-07-02T20:00:00Z',
          entity_type: 'source',
          entity_id: 's1',
          rtt_ms: 12,
          packet_loss_percent: 0.25,
        }]}
      />,
    );

    expect(screen.getByText(/Route is stopped/)).toBeInTheDocument();
    expect(screen.getByText('Quality')).toBeInTheDocument();
    expect(screen.queryByText('12')).not.toBeInTheDocument();
  });

  it('shows an empty state when the route has no SRT endpoints', () => {
    render(
      <SrtHealthTab
        sources={[{ id: 's1', schema: 'RTMP' }]}
        destinations={[{ id: 'd1', schema: 'UDP' }]}
        loading={false}
        error={null}
        points={[]}
      />,
    );

    expect(screen.getByText('This route has no SRT endpoints')).toBeInTheDocument();
  });

  it('switches the link estimate to Gbps once it leaves stream range', () => {
    // SRT reports link capacity in Mbps; on a LAN that is thousands, which reads as a
    // broken axis next to a single-digit send rate.
    render(
      <SrtHealthTab
        sources={[{ id: 's1', name: 'Primary SRT', schema: 'SRT' }]}
        destinations={[]}
        activeSourceId="s1"
        loading={false}
        error={null}
        points={[{
          timestamp: '2026-07-02T20:00:00Z',
          entity_type: 'source',
          entity_id: 's1',
          bandwidth_mbps: 2285.72,
          rate_mbps: 4,
        }]}
      />,
    );

    // antd's Statistic truncates at the requested precision rather than rounding.
    expect(screen.getByText('Estimated bandwidth').closest('.ant-statistic')).toHaveTextContent(
      '2.28Gbps',
    );
    expect(screen.getByText('Rate left · bandwidth right (Gbps)')).toBeInTheDocument();
  });

  it('renders window totals for the selected endpoint', () => {
    render(
      <SrtHealthTab
        sources={[baseSource]}
        destinations={[]}
        activeSourceId="s1"
        loading={false}
        error={null}
        points={[basePoint]}
        totals={[{
          entity_type: 'source',
          entity_id: 's1',
          packets_total: 12500,
          packets_lost_total: 42,
          packets_retransmitted_total: 18,
          packets_dropped_total: 3,
          nack_total: 7,
          bytes_total: 1_500_000,
          loss_percent: 0.33,
        }]}
      />,
    );

    expect(screen.getByText('Totals for the selected window')).toBeInTheDocument();
    expect(screen.getByText('12,500')).toBeInTheDocument();
    expect(screen.getByText('42')).toBeInTheDocument();
    expect(screen.getByText('18')).toBeInTheDocument();
    expect(screen.getByText('3')).toBeInTheDocument();
    expect(screen.getByText('7')).toBeInTheDocument();
    expect(screen.getByText('1.50 MB')).toBeInTheDocument();
    const lossPercentCard = screen.getByText('Loss %').closest('.ant-card');
    expect(lossPercentCard).not.toBeNull();
    expect(lossPercentCard).toHaveTextContent('0.33%');
  });

  it('renders null totals as a dash, not zero', () => {
    render(
      <SrtHealthTab
        sources={[baseSource]}
        destinations={[]}
        activeSourceId="s1"
        loading={false}
        error={null}
        points={[basePoint]}
        totals={[{
          entity_type: 'source',
          entity_id: 's1',
          packets_total: 100,
          packets_lost_total: null,
          packets_retransmitted_total: null,
          packets_dropped_total: null,
          nack_total: null,
          bytes_total: null,
          loss_percent: null,
        }]}
      />,
    );

    const totalsSection = screen.getByText('Totals for the selected window').closest('div');
    expect(totalsSection).not.toBeNull();
    const lostCard = screen.getByText('Lost').closest('.ant-card');
    expect(lostCard).not.toBeNull();
    expect(within(lostCard as HTMLElement).getByText('-')).toBeInTheDocument();
    expect(screen.queryByText('0.00')).not.toBeInTheDocument();
  });

  it('omits the totals row when no entry matches the selected endpoint', () => {
    render(
      <SrtHealthTab
        sources={[baseSource]}
        destinations={[]}
        activeSourceId="s1"
        loading={false}
        error={null}
        points={[basePoint]}
        totals={[{
          entity_type: 'destination',
          entity_id: 'd1',
          packets_total: 500,
        }]}
      />,
    );

    expect(screen.queryByText('Totals for the selected window')).not.toBeInTheDocument();
  });

  it('renders peak series when max fields are present', () => {
    render(
      <SrtHealthTab
        sources={[baseSource]}
        destinations={[]}
        activeSourceId="s1"
        loading={false}
        error={null}
        points={[{
          ...basePoint,
          rtt_ms_max: 20,
          packet_loss_percent_max: 1.5,
          retransmitted_packets_per_sec_max: 9,
          dropped_packets_per_sec_max: 4,
          nack_packets_per_sec_max: 6,
        }]}
      />,
    );

    expect(screen.getByTestId('line-rtt_ms_max')).toHaveAttribute('data-peak', 'true');
    expect(screen.getByTestId('line-packet_loss_percent_max')).toHaveAttribute('data-peak', 'true');
    expect(screen.getByTestId('line-retransmitted_packets_per_sec_max')).toHaveAttribute('data-peak', 'true');
    expect(screen.getByTestId('line-dropped_packets_per_sec_max')).toHaveAttribute('data-peak', 'true');
    expect(screen.getByTestId('line-nack_packets_per_sec_max')).toHaveAttribute('data-peak', 'true');
    expect(screen.getByTestId('line-rtt_ms_max')).toHaveAttribute('data-name', 'RTT (peak)');
  });

  it('renders reset markers inside the chart range and skips those outside', () => {
    render(
      <SrtHealthTab
        sources={[baseSource]}
        destinations={[]}
        activeSourceId="s1"
        loading={false}
        error={null}
        points={[
          { ...basePoint, timestamp: '2026-07-02T20:00:00Z' },
          { ...basePoint, timestamp: '2026-07-02T20:01:00Z', rtt_ms: 14 },
        ]}
        resets={[
          { timestamp: '2026-07-02T20:00:00Z', reason: 'set' },
          { timestamp: '2026-07-02T19:00:00Z', reason: 'set' },
        ]}
      />,
    );

    const resetMarkers = screen.getAllByTestId('reset-marker');
    expect(resetMarkers.length).toBeGreaterThan(0);
    expect(resetMarkers.some((marker) => marker.textContent === 'R')).toBe(true);
    // One marker per chart (4 charts), all at the same matched timestamp
    expect(resetMarkers).toHaveLength(4);
  });
});
