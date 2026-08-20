// ── TrafficChart 组件测试 ──
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/preact';
import TrafficChart from '../src/components/TrafficChart';

// 构造每日数据
function daily(n: number) {
  return Array.from({ length: n }, (_, i) => ({
    date: `2026-08-${String(20 + i).padStart(2, '0')}`,
    rx_bytes: 1000 * (i + 1),
    tx_bytes: 500 * (i + 1),
  }));
}

function mockFetch(body: unknown) {
  return vi.fn().mockResolvedValue({
    ok: true,
    status: 200,
    statusText: 'OK',
    json: async () => body,
  } as Response);
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

describe('TrafficChart', () => {
  it('渲染柱状图（RX/TX 双柱 + 悬停）', async () => {
    fetchMock.mockImplementation(mockFetch(daily(3)));
    const { container } = render(<TrafficChart />);
    await waitFor(() => {
      // 3 天 * 2 条柱 = 6 个 rect
      expect(container.querySelectorAll('rect').length).toBe(6);
    });
  });

  it('空数据显示空状态', async () => {
    fetchMock.mockImplementation(mockFetch([]));
    render(<TrafficChart />);
    await waitFor(() => {
      expect(screen.getByText('暂无历史数据')).toBeTruthy();
    });
  });

  it('切换天数触发重新拉取', async () => {
    fetchMock.mockImplementation(mockFetch(daily(7)));
    render(<TrafficChart />);
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));

    const btn14 = screen.getByText('14天');
    fireEvent.click(btn14);

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledTimes(2);
      const [url] = fetchMock.mock.calls[1];
      expect(url).toBe('/api/traffic/daily?days=14');
    });
  });
});
