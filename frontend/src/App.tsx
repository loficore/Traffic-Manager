// ── 主应用：四标签页仪表盘外壳 ──
import { useSignal, signal } from '@preact/signals';
import { useEffect } from 'preact/hooks';
import {
  fetchStatus,
  fetchCurrentTraffic,
  type StatusResponse,
  type CurrentTraffic,
} from './api';
import { formatBytes, formatUptime } from './format';
import TrafficChart from './components/TrafficChart';
import ConfigPanel from './components/ConfigPanel';
import QuotaManager from './components/QuotaManager';

// 标签页类型
type TabKey = 'dashboard' | 'history' | 'config' | 'quota';

// 模块级信号：当前激活标签页
const activeTab = signal<TabKey>('dashboard');

// 配额状态对应的中文标签与配色
const QUOTA_LABEL: Record<string, { text: string; cls: string }> = {
  disabled: { text: '已禁用', cls: 'bg-gray-100 text-gray-600' },
  normal: { text: '正常', cls: 'bg-green-100 text-green-700' },
  warned: { text: '警告', cls: 'bg-yellow-100 text-yellow-700' },
  exceeded: { text: '超出', cls: 'bg-red-100 text-red-700' },
};

// 单个指标卡片
function MetricCard({ title, value, color }: { title: string; value: string; color: string }) {
  const colorMap: Record<string, string> = {
    blue: 'border-blue-200 bg-blue-50 text-blue-800',
    green: 'border-green-200 bg-green-50 text-green-800',
    purple: 'border-purple-200 bg-purple-50 text-purple-800',
    orange: 'border-orange-200 bg-orange-50 text-orange-800',
  };
  return (
    <div class={`rounded-xl border-2 p-5 shadow-sm ${colorMap[color] ?? 'border-gray-200 bg-gray-50'}`}>
      <div class="text-sm font-medium opacity-75">{title}</div>
      <div class="mt-2 text-2xl font-bold">{value}</div>
    </div>
  );
}

// 仪表盘标签页：实时速率 + 网卡信息
function DashboardPanel({
  status,
  traffic,
}: {
  status: StatusResponse | null;
  traffic: CurrentTraffic | null;
}) {
  return (
    <div class="space-y-6 p-6">
      <div class="grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-4">
        <MetricCard title="接收速率" value={formatBytes(traffic?.rx_speed_bps ?? 0) + '/s'} color="blue" />
        <MetricCard title="发送速率" value={formatBytes(traffic?.tx_speed_bps ?? 0) + '/s'} color="green" />
        <MetricCard title="总接收" value={formatBytes(traffic?.total_rx_bytes ?? 0)} color="purple" />
        <MetricCard title="总发送" value={formatBytes(traffic?.total_tx_bytes ?? 0)} color="orange" />
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <MetricCard title="接收包速率" value={`${(traffic?.rx_pps ?? 0).toLocaleString()} 包/s`} color="blue" />
        <MetricCard title="发送包速率" value={`${(traffic?.tx_pps ?? 0).toLocaleString()} 包/s`} color="green" />
        <MetricCard title="监控网卡" value={status?.interface || '—'} color="purple" />
        <MetricCard title="运行时长" value={formatUptime(status?.uptime_seconds ?? 0)} color="orange" />
      </div>

      {status && (
        <div class="flex items-center gap-3 rounded-lg border border-gray-200 bg-white p-4">
          <span class="text-sm text-gray-500">配额状态：</span>
          <span class={`rounded-full px-3 py-1 text-sm font-medium ${(QUOTA_LABEL[status.quota_state] ?? QUOTA_LABEL.normal).cls}`}>
            {(QUOTA_LABEL[status.quota_state] ?? QUOTA_LABEL.normal).text}
          </span>
          <span class="text-sm text-gray-400">服务状态：{status.state}</span>
        </div>
      )}
    </div>
  );
}

// 标签页按钮
function TabButton({ tab, label }: { tab: TabKey; label: string }) {
  const active = tab === activeTab.value;
  return (
    <button
      class={`border-b-2 px-4 py-2 text-sm font-medium transition-colors ${
        active
          ? 'border-blue-600 text-blue-600'
          : 'border-transparent text-gray-500 hover:border-gray-300 hover:text-gray-700'
      }`}
      onClick={() => (activeTab.value = tab)}
    >
      {label}
    </button>
  );
}

// ── 根组件 ──
export function App() {
  const status = useSignal<StatusResponse | null>(null);
  const traffic = useSignal<CurrentTraffic | null>(null);
  const error = useSignal<string | null>(null);

  // 拉取仪表盘数据
  async function refresh() {
    try {
      const [s, t] = await Promise.all([fetchStatus(), fetchCurrentTraffic()]);
      status.value = s;
      traffic.value = t;
      error.value = null;
    } catch (e) {
      error.value = e instanceof Error ? e.message : '数据获取失败';
    }
  }

  // 每 2 秒自动刷新仪表盘
  useEffect(() => {
    refresh();
    const id = setInterval(refresh, 2000);
    return () => clearInterval(id);
  }, []);

  const tabs: { key: TabKey; label: string }[] = [
    { key: 'dashboard', label: '仪表盘' },
    { key: 'history', label: '流量历史' },
    { key: 'config', label: '配置' },
    { key: 'quota', label: '配额' },
  ];

  return (
    <div class="min-h-screen bg-gray-100">
      {/* 顶部导航栏 */}
      <header class="border-b bg-white shadow-sm">
        <div class="mx-auto flex max-w-6xl items-center justify-between px-4 py-3">
          <h1 class="text-xl font-bold text-gray-800">Traffic Manager</h1>
          <span class="text-sm text-gray-500">
            网卡：<span class="font-medium text-gray-700">{status.value?.interface ?? '加载中…'}</span>
          </span>
        </div>
      </header>

      {/* 全局错误提示 */}
      {error.value && (
        <div class="mx-auto mt-4 max-w-6xl px-4">
          <div class="flex items-center justify-between rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-red-700">
            <span>{error.value}</span>
            <button class="ml-2 text-red-500 hover:text-red-700" onClick={() => (error.value = null)}>
              ✕
            </button>
          </div>
        </div>
      )}

      {/* 标签页导航 */}
      <nav class="mx-auto mt-4 max-w-6xl px-4">
        <div class="flex border-b border-gray-200">
          {tabs.map((t) => (
            <TabButton key={t.key} tab={t.key} label={t.label} />
          ))}
        </div>
      </nav>

      {/* 标签页内容 */}
      <main class="mx-auto mt-4 max-w-6xl">
        {activeTab.value === 'dashboard' && <DashboardPanel status={status.value} traffic={traffic.value} />}
        {activeTab.value === 'history' && <TrafficChart />}
        {activeTab.value === 'config' && <ConfigPanel />}
        {activeTab.value === 'quota' && <QuotaManager />}
      </main>
    </div>
  );
}
