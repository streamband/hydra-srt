import { useEffect, useState, useRef } from 'react';
import { Typography, Button, Card, Space, message, Tabs, Modal, Descriptions, Table, Form, Input, Popconfirm, Switch } from 'antd';
import { HomeOutlined, DownloadOutlined, UploadOutlined, ExclamationCircleOutlined, CheckCircleOutlined, CloseCircleOutlined, PlusOutlined, EditOutlined, DeleteOutlined } from '@ant-design/icons';
import { backupApi, tagsApi, signalGenerationApi, notificationsApi } from '../utils/api';
import type { SignalTransport } from '../utils/api';
import McpTokensTab from './settings/McpTokensTab';
import { ROUTES } from '../utils/constants';
import { useInit } from '../context/InitContext';
import { useLocation, useNavigate } from 'react-router-dom';
import type { ChangeEvent } from 'react';
import { reloadPage } from '../utils/browser';

const { Title } = Typography;
const ONE_MINUTE_SECONDS = 60;
const ONE_HOUR_SECONDS = 60 * ONE_MINUTE_SECONDS;
const ONE_DAY_SECONDS = 24 * ONE_HOUR_SECONDS;
import { getErrorMessage } from '../types/errors';

type TagRecord = { id: string; name: string };

const Settings = () => {
  const location = useLocation();
  const navigate = useNavigate();

  const tabPathByKey: Record<string, string> = {
    about: 'about',
    'route-tags': 'route-tags',
    tokens: 'tokens',
    notifications: 'notifications',
    backup: 'backup',
    routes: 'routes',
    'signal-generation': 'signal-generation',
  };

  const tabKeyByPath: Record<string, string> = Object.fromEntries(
    Object.entries(tabPathByKey).map(([k, v]) => [v, k])
  );

  const getTabFromPath = () => {
    const parts = location.pathname.split('/').filter(Boolean);
    const section = parts[1];
    return tabKeyByPath[section] || 'about';
  };

  const getSignalTransportFromPath = (): SignalTransport => {
    const parts = location.pathname.split('/').filter(Boolean);
    const transport = (parts[2] || 'srt').toLowerCase();
    if (transport === 'udp' || transport === 'rtp' || transport === 'rtmp') {
      return transport;
    }
    return 'srt';
  };

  const [activeTab, setActiveTab] = useState(getTabFromPath());
  const [isDownloading, setIsDownloading] = useState(false);
  const [isRestoring, setIsRestoring] = useState(false);
  const [isDownloadingRoutes, setIsDownloadingRoutes] = useState(false);
  const [isImportingRoutes, setIsImportingRoutes] = useState(false);
  const [tags, setTags] = useState<TagRecord[]>([]);
  const [tagsLoading, setTagsLoading] = useState(false);
  const [tagModalOpen, setTagModalOpen] = useState(false);
  const [savingTag, setSavingTag] = useState(false);
  const [editingTag, setEditingTag] = useState<TagRecord | null>(null);
  const [tagForm] = Form.useForm();
  const [signalForm] = Form.useForm();
  const [signalInitialLoading, setSignalInitialLoading] = useState(false);
  const [signalSaving, setSignalSaving] = useState(false);
  const [signalStarting, setSignalStarting] = useState(false);
  const [signalStopping, setSignalStopping] = useState(false);
  const [signalStatus, setSignalStatus] = useState<any>({ running: false, running_transport: null, host: '127.0.0.1', port: 4200 });
  const [signalTransport, setSignalTransport] = useState<SignalTransport>(getSignalTransportFromPath());
  const [notificationsForm] = Form.useForm();
  const [notificationsLoading, setNotificationsLoading] = useState(false);
  const [notificationsSaving, setNotificationsSaving] = useState(false);
  const [notificationsTesting, setNotificationsTesting] = useState(false);
  const [botTokenConfigured, setBotTokenConfigured] = useState(false);
  const [tokenSuffix, setTokenSuffix] = useState<string | null>(null);
  const [uptimeNowMs, setUptimeNowMs] = useState(Date.now());
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const routesBackupInputRef = useRef<HTMLInputElement | null>(null);
  const signalFormHydratedRef = useRef<Record<SignalTransport, boolean>>({ srt: false, udp: false, rtp: false, rtmp: false });
  const notificationsFormHydratedRef = useRef(false);
  const [modal, modalContextHolder] = Modal.useModal();
  const [messageApi, contextHolder] = message.useMessage();
  const initData = useInit();

  // Set breadcrumb items for the Settings page
  useEffect(() => {
    if ((window as any).setBreadcrumbItems) {
      (window as any).setBreadcrumbItems([
        {
          href: ROUTES.ROUTES,
          title: <HomeOutlined />,
        },
        {
          href: ROUTES.SETTINGS,
          title: 'Settings',
        }
      ]);
    }
  }, []);

  useEffect(() => {
    const intervalId = window.setInterval(() => {
      setUptimeNowMs(Date.now());
    }, 1000);

    return () => window.clearInterval(intervalId);
  }, []);

  const formatAppUptime = () => {
    if (!initData.app_started_at) {
      return 'unknown';
    }

    const startedAtMs = new Date(initData.app_started_at).getTime();

    if (Number.isNaN(startedAtMs) || startedAtMs > uptimeNowMs) {
      return 'unknown';
    }

    let totalSeconds = Math.floor((uptimeNowMs - startedAtMs) / 1000);
    const days = Math.floor(totalSeconds / ONE_DAY_SECONDS);
    totalSeconds -= days * ONE_DAY_SECONDS;
    const hours = Math.floor(totalSeconds / ONE_HOUR_SECONDS);
    totalSeconds -= hours * ONE_HOUR_SECONDS;
    const minutes = Math.floor(totalSeconds / ONE_MINUTE_SECONDS);
    totalSeconds -= minutes * ONE_MINUTE_SECONDS;
    const seconds = totalSeconds;

    return `${days}d ${hours}h ${minutes}m ${seconds}s`;
  };

  const formatBuiltAt = () => {
    const builtAtMs = new Date(initData.built_at).getTime();

    if (Number.isNaN(builtAtMs)) {
      return initData.built_at;
    }

    return new Date(builtAtMs).toLocaleString();
  };

  useEffect(() => {
    const tab = getTabFromPath();
    setActiveTab(tab);
    const transport = getSignalTransportFromPath();
    setSignalTransport(transport as SignalTransport);

    const parts = location.pathname.split('/').filter(Boolean);
    const section = parts[1];
    const isUnknownSection = parts.length < 2 || !tabKeyByPath[section];
    const isSignalGenerationWithoutDemo = section === 'signal-generation' && !initData.demo_data;
    const isInvalidSignalTransport =
      section === 'signal-generation' && initData.demo_data && !['srt', 'udp', 'rtp', 'rtmp'].includes((parts[2] || 'srt').toLowerCase());

    if (isUnknownSection || isSignalGenerationWithoutDemo) {
      navigate('/settings/about', { replace: true });
    } else if (isInvalidSignalTransport) {
      navigate('/settings/signal-generation/srt', { replace: true });
    }
  }, [location.pathname, initData.demo_data]);

  const loadTags = async () => {
    setTagsLoading(true);
    try {
      const result = await tagsApi.list();
      setTags(Array.isArray(result?.data) ? result.data : []);
    } catch (error: any) {
      messageApi.error(`Failed to load tags: ${error.message}`);
      setTags([]);
    } finally {
      setTagsLoading(false);
    }
  };

  useEffect(() => {
    if (activeTab === 'route-tags') {
      loadTags();
    }
  }, [activeTab]);

  const loadTelegramNotifications = async ({ initial = false } = {}) => {
    if (initial) {
      setNotificationsLoading(true);
    }

    try {
      const result = await notificationsApi.getTelegram();
      const data = result?.data || {};
      setBotTokenConfigured(Boolean(data.bot_token_configured));
      setTokenSuffix(data.token_suffix || null);

      if (!notificationsForm.isFieldsTouched()) {
        notificationsForm.setFieldsValue({
          enabled: Boolean(data.enabled),
          chat_id: data.chat_id || '',
          bot_token: '',
        });
        notificationsFormHydratedRef.current = true;
      }
    } catch (error: any) {
      messageApi.error(`Failed to load notification settings: ${error.message}`);
    } finally {
      if (initial) {
        setNotificationsLoading(false);
      }
    }
  };

  useEffect(() => {
    if (activeTab === 'notifications') {
      const shouldHydrate = !notificationsFormHydratedRef.current;
      loadTelegramNotifications({ initial: shouldHydrate });
    }
  }, [activeTab]);

  const loadSignalStatus = async ({ initial = false, hydrateForm = false, transport = signalTransport as SignalTransport } = {}) => {
    if (initial) {
      setSignalInitialLoading(true);
    }

    try {
      const status = await signalGenerationApi.status(transport);
      setSignalStatus(status);

      if (hydrateForm && !signalForm.isFieldsTouched()) {
        signalForm.setFieldsValue({
          host: status.host,
          port: status.port,
          ...(transport === 'rtmp' ? { path: status.path || '/live/test' } : {}),
        });
        signalFormHydratedRef.current[transport] = true;
      }
    } catch (error: any) {
      messageApi.error(`Failed to load signal generation status: ${error.message}`);
    } finally {
      if (initial) {
        setSignalInitialLoading(false);
      }
    }
  };

  const prevSignalTransportRef = useRef(signalTransport);

  useEffect(() => {
    if (activeTab !== 'signal-generation' || !initData.demo_data) {
      return undefined;
    }

    const transportChanged = prevSignalTransportRef.current !== signalTransport;
    prevSignalTransportRef.current = signalTransport;

    if (transportChanged) {
      signalForm.resetFields();
      signalFormHydratedRef.current[signalTransport] = false;
    }

    const shouldHydrate = transportChanged || !signalFormHydratedRef.current[signalTransport];
    loadSignalStatus({ initial: true, hydrateForm: shouldHydrate, transport: signalTransport });

    const intervalId = window.setInterval(() => {
      loadSignalStatus({ initial: false, hydrateForm: false, transport: signalTransport });
    }, 3000);

    return () => window.clearInterval(intervalId);
  }, [activeTab, initData.demo_data, signalTransport]);

  const handleBackupDownload = async () => {
    setIsDownloading(true);
    try {
      await backupApi.downloadBackup();
      messageApi.success({
        content: 'Backup download started',
        icon: <DownloadOutlined />,
        duration: 3
      });
    } catch (error: any) {
      console.error('Error downloading backup:', error);
      messageApi.error({
        content: `Failed to download backup: ${error.message}`,
        icon: <CloseCircleOutlined />,
        duration: 5
      });
    } finally {
      setIsDownloading(false);
    }
  };

  const handleRoutesBackupDownload = async () => {
    setIsDownloadingRoutes(true);
    try {
      await backupApi.downloadRoutes();
      messageApi.success({
        content: 'Routes export started',
        icon: <DownloadOutlined />,
        duration: 3
      });
    } catch (error: any) {
      console.error('Error exporting routes:', error);
      messageApi.error({
        content: `Failed to export routes: ${error.message}`,
        icon: <CloseCircleOutlined />,
        duration: 5
      });
    } finally {
      setIsDownloadingRoutes(false);
    }
  };

  const handleRoutesBackupFileChange = (e: ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    if (!file.name.endsWith('.json')) {
      messageApi.error('Select a .json route backup file');
      e.target.value = '';
      return;
    }

    modal.confirm({
      title: 'Import route backup?',
      icon: <ExclamationCircleOutlined />,
      content: 'Importing this backup replaces all existing routes.',
      okText: 'Import routes',
      okButtonProps: { danger: true },
      onOk: async () => {
        setIsImportingRoutes(true);
        try {
          const result = await backupApi.importRoutes(file);
          messageApi.success(result.message || `Imported ${result.routes_created} routes`);
          reloadPage();
        } catch (error: any) {
          messageApi.error(`Failed to import route backup: ${error.message}`);
        } finally {
          setIsImportingRoutes(false);
          if (routesBackupInputRef.current) routesBackupInputRef.current.value = '';
        }
      },
      onCancel: () => {
        if (routesBackupInputRef.current) routesBackupInputRef.current.value = '';
      },
    });
  };

  const handleFileChange = async (e: ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    if (!file.name.endsWith('.db')) {
      messageApi.error({
        content: 'Select a .db backup file',
        icon: <CloseCircleOutlined />,
        duration: 5
      });
      // Clear the file input
      if (fileInputRef.current) {
        fileInputRef.current.value = '';
      }
      return;
    }

    // Show confirmation dialog using the modal instance
    modal.confirm({
      title: 'Confirm Restore',
      icon: <ExclamationCircleOutlined />,
      content: (
        <>
          <p>Are you sure you want to restore from this backup?</p>
          <p>This will delete all existing data and replace it with the data from the backup file.</p>
          <p>Selected file: {file.name}</p>
        </>
      ),
      okText: 'Yes, Restore',
      cancelText: 'No, Cancel',
      okButtonProps: { danger: true },
      onOk: async () => {
        setIsRestoring(true);
        try {
          console.log('Starting restore process with file:', file.name);

          // Show loading notification
          messageApi.loading({
            content: `Restoring from backup: ${file.name}...`,
            key: 'restoreOperation',
            duration: 0 // 0 means it won't disappear automatically
          });

          const result = await backupApi.restore(file);
          console.log('Restore API response:', result);

          if (result && result.message) {
            messageApi.success({
              content: result.message,
              icon: <CheckCircleOutlined />,
              key: 'restoreOperation', // Use the same key to replace the loading message
              duration: 3
            });
          } else {
            messageApi.success({
              content: `${file.name} backup restored successfully`,
              icon: <CheckCircleOutlined />,
              key: 'restoreOperation',
              duration: 3
            });
          }
          reloadPage();
        } catch (error: any) {
          console.error('Error restoring backup:', error);

          let errorMessage = 'Failed to restore backup';
          if (error.response) {
            try {
              const errorData = await error.response.json();
              errorMessage = errorData.error || errorMessage;
            } catch (e) {
              console.error('Error parsing error response:', e);
            }
          } else if (error.message) {
            errorMessage = `${errorMessage}: ${error.message}`;
          }

          messageApi.error({
            content: errorMessage,
            icon: <CloseCircleOutlined />,
            key: 'restoreOperation', // Use the same key to replace the loading message
            duration: 5
          });
        } finally {
          setIsRestoring(false);
          // Clear the file input
          if (fileInputRef.current) {
            fileInputRef.current.value = '';
          }
        }
      },
      onCancel: () => {
        // Clear the file input
        if (fileInputRef.current) {
          fileInputRef.current.value = '';
        }
      }
    });
  };

  const openCreateTagModal = () => {
    setEditingTag(null);
    tagForm.setFieldsValue({ name: '' });
    setTagModalOpen(true);
  };

  const openEditTagModal = (tag: TagRecord) => {
    setEditingTag(tag);
    tagForm.setFieldsValue({ name: tag?.name || '' });
    setTagModalOpen(true);
  };

  const handleTagModalCancel = () => {
    setTagModalOpen(false);
    setEditingTag(null);
    tagForm.resetFields();
  };

  const handleTagSave = async () => {
    try {
      const values: any = await tagForm.validateFields();
      setSavingTag(true);

      if (editingTag?.id) {
        await tagsApi.update(editingTag.id, { name: values.name });
        messageApi.success('Tag updated');
      } else {
        await tagsApi.create({ name: values.name });
        messageApi.success('Tag created');
      }

      handleTagModalCancel();
      await loadTags();
    } catch (error: any) {
      if (error?.errorFields) {
        return;
      }
      messageApi.error(error.message || 'Failed to save tag');
    } finally {
      setSavingTag(false);
    }
  };

  const handleDeleteTag = async (tagId: string) => {
    try {
      await tagsApi.delete(tagId);
      messageApi.success('Tag deleted');
      await loadTags();
    } catch (error: any) {
      messageApi.error(`Failed to delete tag: ${error.message}`);
    }
  };

  // Render helpers, not inline components, so the uptime tick does not remount the tab DOM.
  const renderBackupTab = () => {
    return (
      <div>
        <Card title="System Backup" style={{ marginBottom: '16px' }}>
          <p>Create a backup of your system configuration and data.</p>
          <Space direction="vertical" style={{ width: '100%' }}>
            <Button
              type="primary"
              icon={<DownloadOutlined />}
              onClick={handleBackupDownload}
              loading={isDownloading}
            >
              Download Backup
            </Button>
            <p style={{ fontSize: '12px', color: 'rgba(255, 255, 255, 0.45)' }}>
              This will create a complete backup of your system configuration.
            </p>
          </Space>
        </Card>

        <Card title="Restore from Backup">
          <p>Restore your system from a previous backup file.</p>
          <Space direction="vertical" style={{ width: '100%' }}>
            <input
              type="file"
              ref={fileInputRef}
              onChange={handleFileChange}
              style={{ display: 'none' }}
              accept=".db"
              name="backup"
            />
            <Button
              icon={<UploadOutlined />}
              onClick={() => fileInputRef.current?.click()}
              loading={isRestoring}
            >
              Select Backup File
            </Button>
            <p style={{ fontSize: '12px', color: 'rgba(255, 255, 255, 0.45)' }}>
              Warning: Restoring from backup will overwrite your current configuration.
            </p>
          </Space>
        </Card>
      </div>
    );
  };

  const renderRoutesTab = () => {
    return (
      <div>
        <Card title="Routes Backup">
          <p>Export or import a portable routes configuration backup.</p>
          <Space direction="vertical" style={{ width: '100%' }}>
            <Button
              type="primary"
              icon={<DownloadOutlined />}
              onClick={handleRoutesBackupDownload}
              loading={isDownloadingRoutes}
            >
              Export Routes
            </Button>
            <input
              type="file"
              ref={routesBackupInputRef}
              onChange={handleRoutesBackupFileChange}
              style={{ display: 'none' }}
              accept=".json"
              name="routes-backup"
            />
            <Button
              icon={<UploadOutlined />}
              onClick={() => routesBackupInputRef.current?.click()}
              loading={isImportingRoutes}
            >
              Import Routes
            </Button>
            <p style={{ fontSize: '12px', color: 'rgba(255, 255, 255, 0.45)' }}>
              Import replaces all existing routes after the backup is validated.
            </p>
          </Space>
        </Card>
      </div>
    );
  };

  const renderRouteTagsTab = () => {
    const columns = [
      {
        title: 'Name',
        dataIndex: 'name',
        key: 'name',
      },
      {
        title: 'Actions',
        key: 'actions',
        width: 180,
        render: (_: unknown, record: TagRecord) => (
          <Space>
            <Button icon={<EditOutlined />} onClick={() => openEditTagModal(record)}>
              Edit
            </Button>
            <Popconfirm
              title="Delete tag?"
              description="This will remove the tag from all routes."
              okText="Delete"
              cancelText="Cancel"
              okButtonProps={{ danger: true }}
              onConfirm={() => handleDeleteTag(record.id)}
            >
              <Button danger icon={<DeleteOutlined />}>
                Delete
              </Button>
            </Popconfirm>
          </Space>
        ),
      },
    ];

    return (
      <Card
        title="Route tags"
        extra={(
          <Button type="primary" icon={<PlusOutlined />} onClick={openCreateTagModal}>
            Add tag
          </Button>
        )}
      >
        <Table
          rowKey="id"
          columns={columns}
          dataSource={tags}
          loading={tagsLoading}
          pagination={false}
        />
      </Card>
    );
  };

  const renderNotificationsTab = () => {
    const handleSave = async () => {
      try {
        const values: any = await notificationsForm.validateFields();
        setNotificationsSaving(true);

        const payload: any = {
          enabled: values.enabled,
          chat_id: values.chat_id,
        };

        if (values.bot_token) {
          payload.bot_token = values.bot_token;
        }

        const result: any = await notificationsApi.updateTelegram(payload);
        const data = result?.data || {};
        setBotTokenConfigured(Boolean(data.bot_token_configured));
        setTokenSuffix(data.token_suffix || null);
        notificationsForm.setFieldValue('bot_token', '');
        notificationsFormHydratedRef.current = true;
        messageApi.success('Notification settings saved');
      } catch (error: any) {
        if (error?.errorFields) {
          return;
        }
        messageApi.error(error.message || 'Failed to save notification settings');
      } finally {
        setNotificationsSaving(false);
      }
    };

    const handleTest = async () => {
      try {
        const values: any = await notificationsForm.validateFields();
        setNotificationsTesting(true);

        const payload: any = {
          enabled: values.enabled,
          chat_id: values.chat_id,
        };

        if (values.bot_token) {
          payload.bot_token = values.bot_token;
        }

        await notificationsApi.testTelegram(payload);
        messageApi.success('Test notification sent');
      } catch (error: any) {
        if (error?.errorFields) {
          return;
        }
        messageApi.error(error.message || 'Failed to send test notification');
      } finally {
        setNotificationsTesting(false);
      }
    };

    const tokenPlaceholder = botTokenConfigured
      ? `Leave blank to keep current token${tokenSuffix ? ` (…${tokenSuffix})` : ''}`
      : 'Bot token from @BotFather';

    return (
      <Card title="Telegram notifications" loading={notificationsLoading}>
        <Form form={notificationsForm} layout="vertical" initialValues={{ enabled: false }}>
          <Form.Item label="Enabled" name="enabled" valuePropName="checked">
            <Switch />
          </Form.Item>
          <Form.Item
            label="Bot token"
            name="bot_token"
            rules={[
              ({ getFieldValue }) => ({
                validator(_, value) {
                  if (!getFieldValue('enabled')) {
                    return Promise.resolve();
                  }
                  if (value || botTokenConfigured) {
                    return Promise.resolve();
                  }
                  return Promise.reject(new Error('Bot token is required when enabled'));
                },
              }),
            ]}
          >
            <Input.Password placeholder={tokenPlaceholder} autoComplete="off" />
          </Form.Item>
          <Form.Item
            label="Chat ID"
            name="chat_id"
            rules={[
              ({ getFieldValue }) => ({
                validator(_, value) {
                  if (!getFieldValue('enabled')) {
                    return Promise.resolve();
                  }
                  if (value && String(value).trim() !== '') {
                    return Promise.resolve();
                  }
                  return Promise.reject(new Error('Chat ID is required when enabled'));
                },
              }),
            ]}
          >
            <Input placeholder="Telegram chat or group ID" />
          </Form.Item>
          <Space>
            <Button type="primary" onClick={handleSave} loading={notificationsSaving}>
              Save
            </Button>
            <Button onClick={handleTest} loading={notificationsTesting}>
              Send test
            </Button>
          </Space>
          <p style={{ marginTop: 16, color: 'rgba(255, 255, 255, 0.65)' }}>
            Route status changes are sent to Telegram when enabled.
          </p>
        </Form>
      </Card>
    );
  };

  const renderSignalGenerationTab = () => {
    const handleSave = async () => {
      try {
        const values: any = await signalForm.validateFields();
        setSignalSaving(true);
        const status = await signalGenerationApi.configure({
          transport: signalTransport,
          host: values.host,
          port: Number(values.port),
          ...(signalTransport === 'rtmp' ? { path: values.path } : {}),
        });
        setSignalStatus(status);
        signalForm.setFieldsValue({
          host: status.host,
          port: status.port,
          ...(signalTransport === 'rtmp' ? { path: status.path || '/live/test' } : {}),
        });
        signalFormHydratedRef.current[signalTransport] = true;
        messageApi.success('Signal generation settings saved');
      } catch (error: any) {
        if (error?.errorFields) {
          return;
        }
        messageApi.error(error.message || 'Failed to save signal generation settings');
      } finally {
        setSignalSaving(false);
      }
    };

    const handleStart = async () => {
      setSignalStarting(true);
      try {
        const status = await signalGenerationApi.start(signalTransport);
        setSignalStatus(status);
        messageApi.success('Signal generation started');
      } catch (error: any) {
        messageApi.error(error.message || 'Failed to start signal generation');
      } finally {
        setSignalStarting(false);
      }
    };

    const handleStop = async () => {
      setSignalStopping(true);
      try {
        const status = await signalGenerationApi.stop(signalTransport);
        setSignalStatus(status);
        messageApi.success('Signal generation stopped');
      } catch (error: any) {
        messageApi.error(error.message || 'Failed to stop signal generation');
      } finally {
        setSignalStopping(false);
      }
    };

    return (
      <Card title="Signal generation" loading={signalInitialLoading}>
        <Tabs
          activeKey={signalTransport}
          onChange={(transport) => {
            const nextTransport = transport as SignalTransport;
            setSignalTransport(nextTransport);
            navigate(`/settings/signal-generation/${nextTransport}`);
          }}
          items={[
            { key: 'srt', label: 'SRT' },
            { key: 'udp', label: 'UDP' },
            { key: 'rtp', label: 'RTP' },
            { key: 'rtmp', label: 'RTMP' },
          ]}
        />
        <Form form={signalForm} layout="vertical">
          {signalTransport === 'rtmp' && (
            <Form.Item
              label="Path"
              name="path"
              rules={[
                { required: true, message: 'Please enter RTMP path' },
                { whitespace: true, message: 'Path cannot be empty' },
              ]}
            >
              <Input placeholder="/live/test" disabled={Boolean(signalStatus.running_transport)} />
            </Form.Item>
          )}
          <Form.Item
            label="Host"
            name="host"
            rules={[
              { required: true, message: 'Please enter host' },
              { whitespace: true, message: 'Host cannot be empty' },
            ]}
          >
            <Input placeholder="127.0.0.1" disabled={Boolean(signalStatus.running_transport)} />
          </Form.Item>
          <Form.Item
            label="Port"
            name="port"
            rules={[
              { required: true, message: 'Please enter port' },
              { pattern: /^\d+$/, message: 'Port must be a number' },
            ]}
          >
            <Input placeholder="4200" disabled={Boolean(signalStatus.running_transport)} />
          </Form.Item>
          <Space>
            <Button onClick={handleSave} loading={signalSaving} disabled={Boolean(signalStatus.running_transport)}>
              Save
            </Button>
            <Button type="primary" onClick={handleStart} loading={signalStarting} disabled={Boolean(signalStatus.running_transport)}>
              Start
            </Button>
            <Button danger onClick={handleStop} loading={signalStopping} disabled={!signalStatus.running_transport}>
              Stop
            </Button>
          </Space>
          <p style={{ marginTop: 16, color: 'rgba(255, 255, 255, 0.65)' }}>
            Status: {signalStatus.running ? `running (${signalTransport.toUpperCase()})` : 'stopped'}
          </p>
          <p style={{ marginTop: 8, color: 'rgba(255, 255, 255, 0.65)' }}>
            Active transport: {(signalStatus.running_transport || 'none').toUpperCase()}
          </p>
        </Form>
      </Card>
    );
  };

  const items = [
    {
      key: 'about',
      label: 'About',
      children: (
        <Card title="Application Info">
          <Descriptions
            column={1}
            bordered
            items={[
              {
                key: 'app',
                label: 'App version',
                labelStyle: { width: 260, minWidth: 260 },
                children: initData.version
              },
              {
                key: 'built-at',
                label: 'Built at',
                labelStyle: { width: 260, minWidth: 260 },
                children: formatBuiltAt()
              },
              {
                key: 'system',
                label: 'System version',
                labelStyle: { width: 260, minWidth: 260 },
                children: initData.system_version
              },
              {
                key: 'elixir',
                label: 'Elixir version',
                labelStyle: { width: 260, minWidth: 260 },
                children: `${initData.elixir_version} ${initData.erlang_version}`
              },
              {
                key: 'rust',
                label: 'Rust version',
                labelStyle: { width: 260, minWidth: 260 },
                children: initData.rust_version
              },
              {
                key: 'uptime',
                label: 'App uptime',
                labelStyle: { width: 260, minWidth: 260 },
                children: formatAppUptime()
              },
            ]}
          />
        </Card>
      ),
    },
    {
      key: 'route-tags',
      label: 'Route tags',
      children: renderRouteTagsTab(),
    },
    {
      key: 'tokens',
      label: 'MCP tokens',
      children: <McpTokensTab />,
    },
    {
      key: 'notifications',
      label: 'Notifications',
      children: renderNotificationsTab(),
    },
    {
      key: 'backup',
      label: 'Backup',
      children: renderBackupTab(),
    },
    {
      key: 'routes',
      label: 'Routes',
      children: renderRoutesTab(),
    },
    ...(initData.demo_data
      ? [{
          key: 'signal-generation',
          label: 'Signal generation',
          children: renderSignalGenerationTab(),
        }]
      : []),
  ];

  return (
    <div>
      {contextHolder}
      {modalContextHolder}
      <Space direction="vertical" size="large" style={{ width: '100%' }}>

        <Space style={{ width: '100%', justifyContent: 'space-between' }}>
          <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>Settings</Title>
        </Space>

        <Card>
          <Tabs
            activeKey={activeTab}
            onChange={(key) => {
              setActiveTab(key);
              if (key === 'signal-generation') {
                navigate(`/settings/signal-generation/${signalTransport}`);
              } else {
                navigate(`/settings/${tabPathByKey[key]}`);
              }
            }}
            items={items}
            tabPosition="left"
          />
        </Card>
      </Space>
      <Modal
        title={editingTag ? 'Edit route tag' : 'Add route tag'}
        open={tagModalOpen}
        onOk={handleTagSave}
        onCancel={handleTagModalCancel}
        okText="Save"
        cancelText="Cancel"
        confirmLoading={savingTag}
      >
        <Form form={tagForm} layout="vertical">
          <Form.Item
            label="Name"
            name="name"
            rules={[
              { required: true, message: 'Please enter tag name' },
              { whitespace: true, message: 'Tag name cannot be empty' },
            ]}
          >
            <Input placeholder="Tag name" />
          </Form.Item>
        </Form>
      </Modal>
    </div>
  );
};

export default Settings; 
