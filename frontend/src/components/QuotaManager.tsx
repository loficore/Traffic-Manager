// ── 配额管理组件 ──
// 展示配额快照、调整列表，并支持新增 / 删除调整。
import { useSignal } from '@preact/signals';
import { useEffect } from 'preact/hooks';
import {
  fetchQuota,
  fetchAdjustments,
  addAdjustment,
  removeAdjustment,
  type QuotaSnapshot,
  type QuotaAdjustment,
} from '../api';
import { formatBytes, parseSizeToBytes } from '../format';

// 配额状态对应的中文标签与配色
const STATE_LABEL: Record<string, { text: string; cls: string }> = {
  normal: { text: '正常', cls: 'bg-green-100 text-green-700' },
  warned: { text: '警告', cls: 'bg-yellow-100 text-yellow-700' },
  exceeded: { text: '超出', cls: 'bg-red-100 text-red-700' },
  disabled: { text: '已禁用', cls: 'bg-gray-100 text-gray-600' },
};

export default function QuotaManager() {
  const quota = useSignal<QuotaSnapshot | null>(null);
  const adjustments = useSignal<QuotaAdjustment[]>([]);
  const loading = useSignal<boolean>(false);
  const error = useSignal<string | null>(null);

  // 新增表单状态
  const amountText = useSignal<string>('');
  const reason = useSignal<string>('');
  const source = useSignal<string>('api');
  const addError = useSignal<string | null>(null);
  const addMsg = useSignal<string | null>(null);

  // 拉取配额与调整列表
  async function refresh() {
    loading.value = true;
    error.value = null;
    try {
      const [q, list] = await Promise.all([fetchQuota(), fetchAdjustments()]);
      quota.value = q;
      adjustments.value = list;
    } catch (e) {
      error.value = e instanceof Error ? e.message : '获取配额失败';
    } finally {
      loading.value = false;
    }
  }

  useEffect(() => {
    refresh();
  }, []);

  // 新增调整
  async function handleAdd() {
    addError.value = null;
    addMsg.value = null;
    const raw = amountText.value.trim();
    if (raw === '') {
      addError.value = '请输入调整额度（如 500MB）';
      return;
    }
    // 优先以字符串形式提交，交由后端统一解析单位
    const payload: { amount?: string; reason?: string; source?: string } = {
      reason: reason.value.trim() || undefined,
      source: source.value.trim() || 'api',
    };
    // 若可解析为纯数字则按字节发送，否则发送单位字符串
    const asBytes = parseSizeToBytes(raw);
    if (asBytes !== null) {
      payload.amount_bytes = asBytes;
    } else {
      payload.amount = raw;
    }
    try {
      await addAdjustment(payload);
      amountText.value = '';
      reason.value = '';
      addMsg.value = '调整已添加';
      await refresh();
    } catch (e) {
      addError.value = e instanceof Error ? e.message : '添加失败';
    }
  }

  // 删除调整
  async function handleDelete(id: number) {
    try {
      await removeAdjustment(id);
      await refresh();
    } catch (e) {
      error.value = e instanceof Error ? e.message : '删除失败';
    }
  }

  const q = quota.value;

  return (
    <div class="space-y-6 p-6">
      {/* 配额概览卡片 */}
      {q ? (
        <div class="rounded-lg border border-gray-200 bg-white p-5">
          <div class="mb-4 flex items-center justify-between">
            <h3 class="text-lg font-semibold text-gray-800">月度配额概览</h3>
            <span class={`rounded-full px-3 py-1 text-sm font-medium ${(STATE_LABEL[q.state] ?? STATE_LABEL.normal).cls}`}>
              {(STATE_LABEL[q.state] ?? STATE_LABEL.normal).text}
            </span>
          </div>

          <div class="grid grid-cols-2 gap-4 md:grid-cols-3">
            <div>
              <div class="text-sm text-gray-500">基础额度</div>
              <div class="text-xl font-bold">{formatBytes(q.base_limit_bytes)}</div>
            </div>
            <div>
              <div class="text-sm text-gray-500">调整累计</div>
              <div class="text-xl font-bold">{formatBytes(Math.max(0, q.effective_limit_bytes - q.base_limit_bytes))}</div>
            </div>
            <div>
              <div class="text-sm text-gray-500">生效额度</div>
              <div class="text-xl font-bold">{formatBytes(q.effective_limit_bytes)}</div>
            </div>
            <div>
              <div class="text-sm text-gray-500">已用</div>
              <div class="text-xl font-bold text-blue-600">{formatBytes(q.monthly_usage_bytes)}</div>
            </div>
            <div>
              <div class="text-sm text-gray-500">剩余</div>
              <div class="text-xl font-bold text-green-600">{formatBytes(q.remaining_bytes)}</div>
            </div>
            <div>
              <div class="text-sm text-gray-500">重置日</div>
              <div class="text-xl font-bold">{q.reset_day} 日</div>
            </div>
          </div>

          {/* 使用进度条（已用 / 生效额度） */}
          <div class="mt-4">
            <div class="mb-1 flex justify-between text-xs text-gray-500">
              <span>使用进度</span>
              <span>
                {q.effective_limit_bytes > 0
                  ? `${((q.monthly_usage_bytes / q.effective_limit_bytes) * 100).toFixed(1)}%`
                  : '—'}
              </span>
            </div>
            <div class="h-3 w-full overflow-hidden rounded-full bg-gray-200">
              <div
                class={`h-full ${q.state === 'exceeded' ? 'bg-red-500' : q.state === 'warned' ? 'bg-yellow-500' : 'bg-blue-500'}`}
                style={{ width: `${q.effective_limit_bytes > 0 ? Math.min(100, (q.monthly_usage_bytes / q.effective_limit_bytes) * 100) : 0}%` }}
              />
            </div>
          </div>
        </div>
      ) : (
        !loading.value && <div class="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-red-700">{error.value ?? '暂无配额数据'}</div>
      )}

      {loading.value && <div class="text-gray-500">加载中…</div>}

      {/* 新增调整 */}
      <div class="rounded-lg border border-gray-200 bg-white p-5">
        <h3 class="mb-3 text-lg font-semibold text-gray-800">新增额度调整</h3>
        <div class="flex flex-wrap items-end gap-3">
          <label class="block">
            <span class="mb-1 block text-sm text-gray-500">额度（如 500MB）</span>
            <input
              class="w-40 rounded border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none"
              value={amountText.value}
              placeholder="500MB"
              onInput={(ev) => (amountText.value = (ev.target as HTMLInputElement).value)}
            />
          </label>
          <label class="block">
            <span class="mb-1 block text-sm text-gray-500">原因（可选）</span>
            <input
              class="w-48 rounded border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none"
              value={reason.value}
              onInput={(ev) => (reason.value = (ev.target as HTMLInputElement).value)}
            />
          </label>
          <label class="block">
            <span class="mb-1 block text-sm text-gray-500">来源（可选）</span>
            <input
              class="w-32 rounded border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none"
              value={source.value}
              onInput={(ev) => (source.value = (ev.target as HTMLInputElement).value)}
            />
          </label>
          <button class="rounded bg-blue-600 px-4 py-2 text-white hover:bg-blue-700" onClick={handleAdd}>
            添加
          </button>
        </div>
        {addError.value && <div class="mt-2 text-sm text-red-600">{addError.value}</div>}
        {addMsg.value && <div class="mt-2 text-sm text-green-600">{addMsg.value}</div>}
      </div>

      {/* 调整列表 */}
      <div class="rounded-lg border border-gray-200 bg-white p-5">
        <h3 class="mb-3 text-lg font-semibold text-gray-800">调整记录</h3>
        {adjustments.value.length === 0 ? (
          <div class="text-sm text-gray-500">本月暂无调整记录</div>
        ) : (
          <ul class="divide-y divide-gray-100">
            {adjustments.value.map((a) => (
              <li key={a.id} class="flex items-center justify-between py-3">
                <div>
                  <div class="font-medium">{formatBytes(a.amount_bytes)}</div>
                  <div class="text-xs text-gray-500">
                    {a.reason || '（无原因）'} · 来源：{a.source} · {new Date(a.created_at).toLocaleString('zh-CN')}
                  </div>
                </div>
                <button
                  class="rounded border border-red-200 px-3 py-1 text-sm text-red-600 hover:bg-red-50"
                  onClick={() => handleDelete(a.id)}
                >
                  删除
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
