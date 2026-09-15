import ReactDOM from 'react-dom/client';
import { ConfigProvider, theme } from 'antd';
import { StrictMode, useEffect, useState } from 'react';
import type { ReactNode } from 'react';
import { HashRouter, Routes, Route, Navigate, useLocation } from 'react-router-dom';
import MainLayout from './components/MainLayout';
import Dashboard from './pages/Dashboard';
import R from './pages/routes/Routes';
import Settings from './pages/Settings';
import RouteItem from './pages/routes/RouteItem';
import RouteSourceEdit from './pages/routes/RouteSourceEdit';
import RouteDestEdit from './pages/routes/RouteDestEdit';
import RouteSourceEndpointEdit from './pages/routes/RouteSourceEndpointEdit';
import Interfaces from './pages/interfaces/Interfaces';
import InterfaceEdit from './pages/interfaces/InterfaceEdit';
import SystemPipelines from './pages/system/SystemPipelines';
import SystemNodes from './pages/system/SystemNodes';
import SystemNodeMetrics from './pages/system/SystemNodeMetrics';
import Login from './pages/Login';
import { isAuthenticated } from './utils/auth';
import { ROUTES } from './utils/constants';
import { connectRealtime, disconnectRealtime } from './utils/realtime';
import { InitProvider } from './context/InitContext';
import { TelemetryErrorBoundary } from './components/TelemetryErrorBoundary';
import './index.css';

const config = {
  algorithm: [theme.darkAlgorithm],
  token: {
    colorPrimary: '#1677ff',
    borderRadius: 6,
    colorBgContainer: '#121212',
    colorBgElevated: '#1a1a1a',
    colorBgLayout: '#000000',
    colorText: 'rgba(255, 255, 255, 0.85)',
    colorTextSecondary: 'rgba(255, 255, 255, 0.45)',
    controlHeight: 36,
    boxShadow: '0 1px 2px rgba(0, 0, 0, 0.3)',
  },
  components: {
    Menu: {
      itemBg: 'transparent',
      itemColor: 'rgba(255, 255, 255, 0.65)',
      itemSelectedColor: '#fff',
      itemSelectedBg: '#1677ff',
      itemHoverColor: '#fff',
      itemHoverBg: 'rgba(255, 255, 255, 0.08)',
      itemMarginInline: 8,
      itemBorderRadius: 4,
    },
    Button: {
      controlHeight: 36,
      borderRadius: 4,
    },
    Card: {
      colorBgContainer: '#1a1a1a',
    },
    Layout: {
      headerBg: '#000000',
      siderBg: '#000000',
    },
    Table: {
      colorBgContainer: '#121212',
      headerBg: '#121212',
      headerColor: 'rgba(255, 255, 255, 0.85)',
      headerSortActiveBg: '#1a1a1a',
      rowHoverBg: '#1a1a1a',
      borderColor: '#303030',
    }
  }
};

// Protected route component
const ProtectedRoute = ({ children }: { children: ReactNode }) => {
  const location = useLocation();

  if (!isAuthenticated()) {
    // Redirect to login if not authenticated
    return <Navigate to={ROUTES.LOGIN} state={{ from: location }} replace />;
  }

  return children;
};

const RealtimeConnection = () => {
  const location = useLocation();

  useEffect(() => {
    if (isAuthenticated()) {
      connectRealtime();
    } else {
      disconnectRealtime();
    }
  }, [location.pathname]);

  return null;
};

// App component with authentication logic
const App = () => {
  const [isLoading, setIsLoading] = useState(true);
  const noop = () => {};

  if (
    import.meta.env.MODE === 'test' &&
    new URLSearchParams(window.location.search).get('hydra_test_error') === '1'
  ) {
    throw new Error('HydraSRT test render failure');
  }

  useEffect(() => {
    // Check if user is authenticated
    setIsLoading(false);
  }, []);

  if (isLoading) {
    return null; // Or a loading spinner
  }

  return (
    <HashRouter>
      <RealtimeConnection />
      <Routes>
        <Route path={ROUTES.LOGIN} element={<Login />} />

        <Route path={ROUTES.HOME} element={
          <ProtectedRoute>
            <Navigate to={ROUTES.DASHBOARD} replace />
          </ProtectedRoute>
        } />

        <Route path={ROUTES.DASHBOARD} element={
          <ProtectedRoute>
            <MainLayout>
              <Dashboard />
            </MainLayout>
          </ProtectedRoute>
        } />

        <Route path={ROUTES.ROUTES} element={
          <ProtectedRoute>
            <MainLayout>
              <R />
            </MainLayout>
          </ProtectedRoute>
        } />

        <Route path={ROUTES.INTERFACES} element={
          <ProtectedRoute>
            <MainLayout>
              <Interfaces />
            </MainLayout>
          </ProtectedRoute>
        } />

        <Route path="/interfaces/:id/edit" element={
          <ProtectedRoute>
            <MainLayout>
              <InterfaceEdit />
            </MainLayout>
          </ProtectedRoute>
        } />

        <Route path="/routes/:id" element={
          <ProtectedRoute>
            <MainLayout>
              <RouteItem />
            </MainLayout>
          </ProtectedRoute>
        } />

        <Route path="/routes/:id/edit" element={
          <ProtectedRoute>
            <MainLayout>
              <RouteSourceEdit />
            </MainLayout>
          </ProtectedRoute>
        } />

        <Route path="/routes/:routeId/destinations/:destId/edit" element={
          <ProtectedRoute>
            <MainLayout>
              <RouteDestEdit initialValues={{}} onChange={noop} />
            </MainLayout>
          </ProtectedRoute>
        } />

        <Route path="/routes/:routeId/sources/:sourceId/edit" element={
          <ProtectedRoute>
            <MainLayout>
              <RouteSourceEndpointEdit initialValues={{}} onChange={noop} />
            </MainLayout>
          </ProtectedRoute>
        } />

        <Route path="/settings/*" element={
          <ProtectedRoute>
            <MainLayout>
              <Settings />
            </MainLayout>
          </ProtectedRoute>
        } />

        <Route path={ROUTES.SYSTEM_PIPELINES} element={
          <ProtectedRoute>
            <MainLayout>
              <SystemPipelines />
            </MainLayout>
          </ProtectedRoute>
        } />

        <Route path={ROUTES.SYSTEM_NODES} element={
          <ProtectedRoute>
            <MainLayout>
              <SystemNodes />
            </MainLayout>
          </ProtectedRoute>
        } />

        <Route path="/system/nodes/:id" element={
          <ProtectedRoute>
            <MainLayout>
              <SystemNodeMetrics />
            </MainLayout>
          </ProtectedRoute>
        } />

        <Route path="/system/nodes/:id/metrics" element={
          <ProtectedRoute>
            <MainLayout>
              <SystemNodeMetrics />
            </MainLayout>
          </ProtectedRoute>
        } />
      </Routes>
    </HashRouter>
  );
};

const rootEl = document.getElementById('root');

if (!rootEl) {
  throw new Error('Root element not found');
}

ReactDOM.createRoot(rootEl).render(
  <StrictMode>
    <InitProvider>
      <TelemetryErrorBoundary>
        <ConfigProvider theme={config}>
          <App />
        </ConfigProvider>
      </TelemetryErrorBoundary>
    </InitProvider>
  </StrictMode>,
);
