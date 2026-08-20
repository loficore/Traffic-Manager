// ── 纯 SVG 每日流量柱状图组件 ──
// 不依赖任何图表库，使用 SVG 绘制 RX/TX 双色柱，并支持悬停提示与天数切换。
import { useSignal, useComputed } from '@preact/signals';
import { useEffect } from 'preact/hooks';
import { fetchDailyTraffic, type DailyRecord } from '../api';
import { formatBytes } from '../format';

// 可选天数
const DAY_OPTIONS = [7, 14, 30];

// 图表几何参数
const CHART_W = 720;
const CHART_H = 320;
const PAD = { top: 20, right: 20, bottom: 40, left: 64 };
const PLOT_W = CHART_W - PAD.left - PAD.right;
const PLOT_H = CHART_H - PAD.top - PAD.bottom;

// 单位 -> 1024 指数
function unitExp(unit: string): number {
  switch (unit) {
    case 'B':
      return 0;
    case 'KB':
      return 1;
    case 'MB':
      return 2;
    case 'GB':
      return 3;
    case 'TB':
      return 4;
    default:
      return 0;
  }
}

// 自动将字节数折算为合适单位，返回 { value, unit }
function autoScale(bytes: number): { value: number; unit: string } {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = bytes;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i += 1;
  }
  return { value: v, unit: units[i] };
}

// 单条柱的几何信息（用于渲染与命中检测）
interface BarRect {
  x: number;
  y: number;
  w: number;
  h: number;
  label: string;
  rx: number;
  tx: number;
  txH: number;
}

export default function TrafficChart() {
  const days = useSignal<number>(7);
  const data = useSignal<DailyRecord[]>([]);
  const loading = useSignal<boolean>(false);
  const error = useSignal<string | null>(null);
  const hover = useSignal<BarRect | null>(null);

  // 拉取指定天数的每日流量
  async function load() {
    loading.value = true;
    error.value = null;
    try {
      data.value = await fetchDailyTraffic(days.value);
    } catch (e) {
      error.value = e instanceof Error ? e.message : '获取历史流量失败';
      data.value = [];
    } finally {
      loading.value = false;
    }
  }

  useEffect(() => {
    load();
  }, []);

  // 按日期升序排列（便于从左向右绘制）
  const ordered = useComputed(() => [...data.value].reverse());

  // Y 轴最大值（取 RX+TX 的最大值，并留 10% 余量）
  const maxTotal = useComputed(() => {
    const max = data.value.reduce((m, d) => Math.max(m, d.rx_bytes + d.tx_bytes), 0);
    return max === 0 ? 1 : max * 1.1;
  });

  const scale = useComputed(() => autoScale(maxTotal.value));
  const yMax = scale.value.value;
  const divisor = Math.pow(1024, unitExp(scale.value.unit));

  // 计算每条柱的几何信息
  const bars = useComputed<BarRect[]>(() => {
    const list = ordered.value;
    if (list.length === 0) return [];
    const groupW = PLOT_W / list.length;
    const barW = Math.min(24, (groupW - 8) / 2);
    const gap = 4;
    return list.map((d, idx) => {
      const rxVal = d.rx_bytes / divisor;
      const txVal = d.tx_bytes / divisor;
      const rxH = (rxVal / yMax) * PLOT_H;
      const txH = (txVal / yMax) * PLOT_H;
      const cx = PAD.left + groupW * idx + groupW / 2;
      return {
        x: cx - barW - gap / 2,
        y: PAD.top + PLOT_H - rxH,
        w: barW,
        h: rxH,
        label: d.date,
        rx: d.rx_bytes,
        tx: d.tx_bytes,
        txH,
      } as BarRect;
    });
  });

  // Y 轴刻度（5 等分）
  const yTicks = useComputed(() =>
    Array.from({ length: 6 }, (_, i) => {
      const val = (yMax / 5) * i;
      const y = PAD.top + PLOT_H - (val / yMax) * PLOT_H;
      return { val, y };
    }),
  );

  // 切换天数后重新拉取
  function changeDays(d: number) {
    days.value = d;
    load();
  }

  if (loading.value && data.value.length === 0) {
    return <div class="p-6 text-gray-500">加载中…</div>;
  }
  if (error.value && data.value.length === 0) {
    return (
      <div class="p-6">
        <div class="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-red-700">{error.value}</div>
        <button class="mt-3 rounded bg-blue-600 px-4 py-2 text-white hover:bg-blue-700" onClick={load}>
          重试
        </button>
      </div>
    );
  }
  if (data.value.length === 0) {
    return <div class="p-6 text-gray-500">暂无历史数据</div>;
  }

  return (
    <div class="p-6">
      {/* 天数选择 */}
      <div class="mb-4 flex flex-wrap items-center gap-3">
        <span class="text-sm text-gray-600">显示天数：</span>
        <div class="flex gap-2">
          {DAY_OPTIONS.map((d) => (
            <button
              key={d}
              class={`rounded border px-3 py-1 text-sm ${
                days.value === d
                  ? 'border-blue-600 bg-blue-600 text-white'
                  : 'border-gray-300 text-gray-600 hover:border-blue-400'
              }`}
              onClick={() => changeDays(d)}
            >
              {d}天
            </button>
          ))}
        </div>
        <div class="ml-2 flex items-center gap-4 text-sm">
          <span class="flex items-center gap-1">
            <span class="inline-block h-3 w-3 rounded-sm bg-blue-500" />接收
          </span>
          <span class="flex items-center gap-1">
            <span class="inline-block h-3 w-3 rounded-sm bg-orange-500" />发送
          </span>
        </div>
      </div>

      {/* SVG 图表 */}
      <div class="overflow-x-auto rounded-lg border border-gray-200 bg-white p-4">
        <svg viewBox={`0 0 ${CHART_W} ${CHART_H}`} width="100%" role="img" aria-label="每日流量柱状图">
          {/* Y 轴网格与刻度 */}
          {yTicks.value.map((t, i) => (
            <g key={i}>
              <line x1={PAD.left} y1={t.y} x2={CHART_W - PAD.right} y2={t.y} stroke="#eee" />
              <text x={PAD.left - 8} y={t.y + 4} text-anchor="end" font-size="11" fill="#888">
                {t.val >= 100 ? t.val.toFixed(0) : t.val.toFixed(1)}
              </text>
            </g>
          ))}
          <text
            x={14}
            y={PAD.top + PLOT_H / 2}
            text-anchor="middle"
            font-size="11"
            fill="#888"
            transform={`rotate(-90 14 ${PAD.top + PLOT_H / 2})`}
          >
            {scale.value.unit}
          </text>

          {/* 柱体 */}
          {bars.value.map((b, i) => {
            const groupW = PLOT_W / ordered.value.length;
            const cx = PAD.left + groupW * i + groupW / 2;
            const txX = cx + 4;
            return (
              <g key={i}>
                {/* 接收柱 */}
                <rect
                  x={b.x}
                  y={b.y}
                  width={b.w}
                  height={Math.max(0, b.h)}
                  fill="#3b82f6"
                  onMouseEnter={() => (hover.value = b)}
                  onMouseLeave={() => (hover.value = null)}
                />
                {/* 发送柱 */}
                <rect
                  x={txX}
                  y={PAD.top + PLOT_H - b.txH}
                  width={b.w}
                  height={Math.max(0, b.txH)}
                  fill="#f97316"
                  onMouseEnter={() => (hover.value = { ...b, h: b.txH })}
                  onMouseLeave={() => (hover.value = null)}
                />
                {/* X 轴日期（数据多时间隔显示，避免拥挤） */}
                {(ordered.value.length <= 14 || i % 2 === 0) && (
                  <text x={cx} y={CHART_H - PAD.bottom + 16} text-anchor="middle" font-size="10" fill="#888">
                    {b.label.slice(5)}
                  </text>
                )}
              </g>
            );
          })}
        </svg>
      </div>

      {/* 悬停提示 */}
      {hover.value && (
        <div class="mt-3 rounded-lg border border-gray-200 bg-gray-50 p-3 text-sm">
          <div class="font-medium">{hover.value.label}</div>
          <div class="text-blue-600">接收：{formatBytes(hover.value.rx)}</div>
          <div class="text-orange-600">发送：{formatBytes(hover.value.tx)}</div>
        </div>
      )}
    </div>
  );
}
