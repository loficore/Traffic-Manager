// ── API 客户端单元测试 ──
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  fetchStatus,
  fetchCurrentTraffic,
  fetchDailyTraffic,
  fetchConfig,
  updateConfig,
  fetchQuota,
  fetchAdjustments,
  addAdjustment,
  removeAdjustment,
} from '../src/api';

// 模拟 fetch 的辅助：返回指定状态码与 JSON 体
function mockFetch(body: unknown, status = 200, ok = true) {
  const res = {
    ok,
    status,
    statusText: ok ? 'OK' : 'Error',
    json: async () => body,
  } as Response;
  return vi.fn().mockResolvedValue(res);
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn();
  // @ts-expect-error 覆盖全局 fetch
  global.fetch = fetchMock;
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('fetchStatus', () => {
  it('请求 /status 并解析状态', async () => {
    const data = { state: 'running', interface: 'eth0', uptime_seconds: 123, quota_state: 'normal' };
    fetchMock.mockImplementation(mockFetch(data));
    const r = await fetchStatus();
    expect(fetchMock).toHaveBeenCalledWith('/api/status', undefined);
    expect(r.interface).toBe('eth0');
    expect(r.quota_state).toBe('normal');
  });
});

describe('fetchCurrentTraffic', () => {
  it('请求 /traffic/current 并解析字段', async () => {
    const data = { rx_speed_bps: 10, tx_speed_bps: 20, rx_pps: 1, tx_pps: 2, total_rx_bytes: 100, total_tx_bytes: 200 };
    fetchMock.mockImplementation(mockFetch(data));
    const r = await fetchCurrentTraffic();
    expect(fetchMock).toHaveBeenCalledWith('/api/traffic/current', undefined);
    expect(r.total_rx_bytes).toBe(100);
  });
});

describe('fetchDailyTraffic', () => {
  it('按天数拼接查询参数', async () => {
    const data = [{ date: '2026-08-24', rx_bytes: 1, tx_bytes: 2 }];
    fetchMock.mockImplementation(mockFetch(data));
    const r = await fetchDailyTraffic(14);
    expect(fetchMock).toHaveBeenCalledWith('/api/traffic/daily?days=14', undefined);
    expect(r[0].date).toBe('2026-08-24');
  });
});

describe('fetchConfig', () => {
  it('请求 /config 返回完整配置', async () => {
    const data = {
      interface: null,
      interval_sec: 2,
      retention_days: 30,
      day_count: 7,
      quota_limit_bytes: 107374182400,
      quota_warning_threshold: 0.9,
      quota_disconnect_threshold: 1.0,
      quota_reset_day: 1,
      reset_day: 1,
      webhook_url: null,
      smtp_server: null,
      smtp_port: null,
      smtp_user: null,
      smtp_pass: null,
      smtp_from: null,
      smtp_to: null,
    };
    fetchMock.mockImplementation(mockFetch(data));
    const r = await fetchConfig();
    expect(fetchMock).toHaveBeenCalledWith('/api/config', undefined);
    expect(r.quota_limit_bytes).toBe(107374182400);
    expect(r.smtp_port).toBeNull();
  });
});

describe('updateConfig', () => {
  it('PUT /config 并发送转换后的 JSON', async () => {
    const sent = { quota_limit_bytes: 100, quota_warning_threshold: 0.5 };
    fetchMock.mockImplementation(mockFetch(sent));
    const r = await updateConfig({ quota_limit_bytes: 100, quota_warning_threshold: 0.5 });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe('/api/config');
    expect(init.method).toBe('PUT');
    expect(init.headers).toEqual({ 'Content-Type': 'application/json' });
    expect(JSON.parse(init.body as string)).toEqual({ quota_limit_bytes: 100, quota_warning_threshold: 0.5 });
    expect(r.quota_limit_bytes).toBe(100);
  });
});

describe('fetchQuota', () => {
  it('请求 /quota 并解析快照', async () => {
    const data = {
      base_limit_bytes: 100,
      effective_limit_bytes: 120,
      monthly_usage_bytes: 50,
      remaining_bytes: 70,
      state: 'normal',
      warning_threshold: 0.9,
      disconnect_threshold: 1.0,
      reset_day: 1,
    };
    fetchMock.mockImplementation(mockFetch(data));
    const r = await fetchQuota();
    expect(fetchMock).toHaveBeenCalledWith('/api/quota', undefined);
    expect(r.effective_limit_bytes).toBe(120);
  });
});

describe('fetchAdjustments', () => {
  it('请求 /quota/adjustments 返回数组', async () => {
    const data = [{ id: 1, amount_bytes: 524288000, reason: '补录', source: 'api', month_key: '2026-08', created_at: 1700000000000 }];
    fetchMock.mockImplementation(mockFetch(data));
    const r = await fetchAdjustments();
    expect(fetchMock).toHaveBeenCalledWith('/api/quota/adjustments', undefined);
    expect(r[0].id).toBe(1);
  });
});

describe('addAdjustment', () => {
  it('POST /quota/adjustments 并解析返回', async () => {
    fetchMock.mockImplementation(mockFetch({ id: 2, amount_bytes: 500, month_key: '2026-08' }, 201));
    const r = await addAdjustment({ amount: '500MB', reason: '测试' });
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe('/api/quota/adjustments');
    expect(init.method).toBe('POST');
    expect(JSON.parse(init.body as string)).toEqual({ amount: '500MB', reason: '测试' });
    expect(r.id).toBe(2);
  });
});

describe('removeAdjustment', () => {
  it('DELETE /quota/adjustments/:id', async () => {
    fetchMock.mockImplementation(mockFetch({ ok: true }));
    const r = await removeAdjustment(5);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe('/api/quota/adjustments/5');
    expect(init.method).toBe('DELETE');
    expect(r.ok).toBe(true);
  });
});

describe('错误处理', () => {
  it('非 2xx 响应时抛出错误', async () => {
    fetchMock.mockImplementation(mockFetch({ error: 'bad' }, 400, false));
    await expect(fetchStatus()).rejects.toThrow();
  });
});
