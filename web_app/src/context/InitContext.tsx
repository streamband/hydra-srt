import { createContext, useContext, useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import { initApi } from '../utils/api';

type InitData = {
  version: string;
  built_at: string;
  system_version: string;
  elixir_version: string;
  erlang_version: string;
  rust_version: string;
  app_started_at: string | null;
  demo_data: boolean;
  sentry_dsn: string | null;
};

const INIT_FALLBACK: InitData = {
  version: 'unknown',
  built_at: 'unknown',
  system_version: 'unknown',
  elixir_version: 'unknown',
  erlang_version: 'unknown',
  rust_version: 'unknown',
  app_started_at: null,
  demo_data: false,
  sentry_dsn: null,
};
const InitContext = createContext<InitData>(INIT_FALLBACK);

let initPromise: Promise<InitData> | undefined;

const loadInitOnce = (): Promise<InitData> => {
  if (!initPromise) {
    initPromise = initApi.get().then((payload) => payload as InitData).catch((error: unknown) => {
      console.error('Failed to load init payload:', error);
      return INIT_FALLBACK;
    });
  }

  return initPromise;
};

export const InitProvider = ({ children }: { children: ReactNode }) => {
  const [initData, setInitData] = useState(INIT_FALLBACK);

  useEffect(() => {
    let active = true;

    loadInitOnce().then((payload) => {
      if (active) {
        setInitData(payload);
      }
    });

    return () => {
      active = false;
    };
  }, []);

  const value = useMemo(() => initData, [initData]);

  return <InitContext.Provider value={value}>{children}</InitContext.Provider>;
};

export const useInit = () => useContext(InitContext);
