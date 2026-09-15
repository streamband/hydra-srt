import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { configDefaults } from 'vitest/config';
import type { CoverageOptions } from 'vitest/node';

const toBoolean = (value: string | undefined | null, defaultValue: boolean): boolean => {
  if (value === undefined || value === null || value === '') {
    return defaultValue;
  }

  const normalized = String(value).trim().toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(normalized)) return true;
  if (['0', 'false', 'no', 'off'].includes(normalized)) return false;
  return defaultValue;
};

const devHost = process.env.VITE_DEV_HOST || 'localhost';
const devPort = Number(process.env.VITE_DEV_PORT || 5173);
const devStrictPort = toBoolean(process.env.VITE_DEV_STRICT_PORT, true);
const buildSourcemap = toBoolean(process.env.VITE_BUILD_SOURCEMAP, false);

const proxy = {
  // Web UI often uses page origin (e.g. http://LAN:5173) with API_BASE_URL matching
  // that origin so /api is proxied to Phoenix. Phoenix Channels must use the same
  // pattern: proxy /socket with WS upgrades, otherwise the browser hangs on
  // ws://...:5173/socket/websocket waiting for a Phoenix handshake that never comes.
  '^/(api|backup|socket)': {
    target: 'http://127.0.0.1:4000',
    changeOrigin: true,
    ws: true,
  },
};

// Keep the requested all-files behavior explicit even though Vitest 4's public type omits it.
const coverage: CoverageOptions & { all: boolean } = {
  provider: 'v8',
  reporter: ['text', 'lcov'],
  reportsDirectory: './coverage',
  include: ['src/**/*.{ts,tsx}'],
  exclude: [
    'src/**/*.{test,spec}.{js,jsx,ts,tsx}',
    'src/test/**',
    'src/**/__tests__/**',
    'playwright/**',
    '**/*.d.ts',
    '**/*.generated.{ts,tsx}',
  ],
  all: true,
};

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  build: {
    // Hidden writes maps without a sourceMappingURL comment so JS bytes match a no-map build.
    sourcemap: buildSourcemap ? 'hidden' : false,
  },
  server: {
    host: devHost,
    port: Number.isFinite(devPort) ? devPort : 5173,
    strictPort: devStrictPort,
    proxy,
  },
  test: {
    environment: 'jsdom',
    setupFiles: './src/test/setup.ts',
    globals: true,
    exclude: [...configDefaults.exclude, 'playwright/**'],
    coverage,
  },
});
