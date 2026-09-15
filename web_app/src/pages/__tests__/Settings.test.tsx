import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import Settings from '../Settings';

const { importRoutes, reloadPage } = vi.hoisted(() => ({
  importRoutes: vi.fn(),
  reloadPage: vi.fn(),
}));

vi.mock('../../utils/api', () => ({
  backupApi: {
    downloadBackup: vi.fn(),
    downloadRoutes: vi.fn(),
    importRoutes,
    restore: vi.fn(),
  },
  notificationsApi: {},
  signalGenerationApi: {},
  tagsApi: {},
}));

vi.mock('../../utils/browser', () => ({ reloadPage }));

vi.mock('../../context/InitContext', () => ({
  useInit: () => ({
    app_started_at: null,
    built_at: '',
    demo_data: false,
    version: '',
  }),
}));

vi.mock('../settings/McpTokensTab', () => ({ default: () => null }));

describe('Settings route backup', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    importRoutes.mockResolvedValue({ routes_created: 2 });
  });

  it('reloads the application after a successful route import', async () => {
    const { container } = render(
      <MemoryRouter initialEntries={['/settings/routes']}>
        <Settings />
      </MemoryRouter>,
    );

    const input = container.querySelector<HTMLInputElement>('input[name="routes-backup"]');
    expect(input).not.toBeNull();

    const file = new File(['{"backup_version":"1.0","routes":[]}'], 'routes.json', {
      type: 'application/json',
    });
    fireEvent.change(input!, { target: { files: [file] } });

    fireEvent.click(await screen.findByRole('button', { name: 'Import routes' }));

    await waitFor(() => {
      expect(importRoutes).toHaveBeenCalledWith(file);
      expect(reloadPage).toHaveBeenCalledOnce();
    });
  });
});

describe('Settings file inputs across uptime ticks', () => {
  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.clearAllMocks();
    importRoutes.mockResolvedValue({ routes_created: 2 });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('keeps the routes backup file input mounted across uptime ticks', async () => {
    const { container } = render(
      <MemoryRouter initialEntries={['/settings/routes']}>
        <Settings />
      </MemoryRouter>,
    );

    const input = container.querySelector<HTMLInputElement>('input[name="routes-backup"]');
    expect(input).not.toBeNull();

    await act(async () => {
      vi.advanceTimersByTime(3000);
    });

    expect(container.querySelector('input[name="routes-backup"]')).toBe(input);
    expect(input!.isConnected).toBe(true);

    const file = new File(['{"backup_version":"1.0","routes":[]}'], 'routes.json', {
      type: 'application/json',
    });
    fireEvent.change(input!, { target: { files: [file] } });

    fireEvent.click(await screen.findByRole('button', { name: 'Import routes' }));

    await waitFor(() => {
      expect(importRoutes).toHaveBeenCalledWith(file);
    });
  });

  it('keeps the database restore file input mounted across uptime ticks', async () => {
    const { container } = render(
      <MemoryRouter initialEntries={['/settings/backup']}>
        <Settings />
      </MemoryRouter>,
    );

    const input = container.querySelector<HTMLInputElement>('input[name="backup"]');
    expect(input).not.toBeNull();

    await act(async () => {
      vi.advanceTimersByTime(3000);
    });

    expect(container.querySelector('input[name="backup"]')).toBe(input);
    expect(input!.isConnected).toBe(true);

    const file = new File(['sqlite'], 'backup.db', { type: 'application/octet-stream' });
    fireEvent.change(input!, { target: { files: [file] } });

    expect(await screen.findByText('Confirm Restore')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Yes, Restore' })).toBeInTheDocument();
  });
});
