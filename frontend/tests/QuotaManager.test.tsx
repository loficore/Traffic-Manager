// ── QuotaManager 组件测试 ──
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/preact';
import QuotaManager from '../src/components/QuotaManager';

const quotaSnap = {
  base_limit_bytes: 100,
  effective_limit_bytes: 120,
  monthly_usage_bytes: 50,
  remaining_bytes: 70,
  state: 'normal',
  warning_threshold: 0.9,
  disconnect_threshold: 1.0,
  reset_day: 1,
};

const adjustments = [
  { id: 1, amount_bytes: 524288000, reason: '补录', source: 'api', month_key: '2026-08', created_at: 1700000000000 },
];

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn().mockImplementation(async (url: string, init?: RequestInit) => {
    if (init && init.method === 'POST') {
      return { ok: true, status: 201, statusText: 'Created', json: async () => ({ id: 9, amount_bytes: 524288000, month_key: '2026-08' }) } as Response;
    }
    if (init && init.method === 'DELETE') {
      return { ok: true, status: 200, statusText: 'OK', json: async () => ({ ok: true }) } as Response;
    }
    if (url === '/api/quota') {
      return { ok: true, status: 200, statusText: 'OK', json: async () => quotaSnap } as Response;
    }
    if (url === '/api/quota/adjustments') {
      return { ok: true, status: 200, statusText: 'OK', json: async () => adjustments } as Response;
    }
    return { ok: true, status: 200, statusText: 'OK', json: async () => ({}) } as Response;
  });
  // @ts-expect-error 覆盖全局 fetch
  global.fetch = fetchMock;
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('QuotaManager', () => {
  it('展示配额概览', async () => {
    render(<QuotaManager />);
    await waitFor(() => {
      expect(screen.getByText('月度配额概览')).toBeTruthy();
    });
    expect(screen.getByText('生效额度')).toBeTruthy();
  });

  it('展示调整列表', async () => {
    render(<QuotaManager />);
    await waitFor(() => {
      expect(screen.getByText('补录', { exact: false })).toBeTruthy();
    });
  });

  it('新增调整调用 addAdjustment（POST）', async () => {
    render(<QuotaManager />);
    await waitFor(() => expect(screen.getByText('月度配额概览')).toBeTruthy());

    fireEvent.input(screen.getByPlaceholderText('500MB'), { target: { value: '500MB' } });
    fireEvent.click(screen.getByText('添加'));

    await waitFor(() => {
      const postCall = fetchMock.mock.calls.find((c) => (c[1] as RequestInit)?.method === 'POST');
      expect(postCall).toBeTruthy();
      const body = JSON.parse(postCall![1].body as string);
      expect(body.amount_bytes).toBe(524288000);
    });
  });

  it('删除调整调用 removeAdjustment（DELETE）', async () => {
    render(<QuotaManager />);
    await waitFor(() => expect(screen.getByText('补录', { exact: false })).toBeTruthy());

    fireEvent.click(screen.getByText('删除'));

    await waitFor(() => {
      const delCall = fetchMock.mock.calls.find((c) => (c[1] as RequestInit)?.method === 'DELETE');
      expect(delCall).toBeTruthy();
      expect(delCall![0]).toBe('/api/quota/adjustments/1');
    });
  });
});
