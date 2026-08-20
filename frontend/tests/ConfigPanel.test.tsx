// ── ConfigPanel 组件测试 ──
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/preact';
import ConfigPanel from '../src/components/ConfigPanel';
import type { Config } from '../src/api';

const sampleConfig: Config = {
  interface: null,
  interval_sec: 2,
  retention_days: 30,
  day_count: 7,
  quota_limit_bytes: 0,
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

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn().mockImplementation(async (url: string, init?: RequestInit) => {
    if (init && init.method === 'PUT') {
      const body = JSON.parse(init.body as string);
      return {
        ok: true,
        status: 200,
        statusText: 'OK',
        json: async () => ({ ...sampleConfig, ...body }),
      } as Response;
    }
    return { ok: true, status: 200, statusText: 'OK', json: async () => sampleConfig } as Response;
  });
  // @ts-expect-error 覆盖全局 fetch
  global.fetch = fetchMock;
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('ConfigPanel', () => {
  it('加载后字段被配置值填充', async () => {
    render(<ConfigPanel />);
    await waitFor(() => {
      expect(screen.getByDisplayValue('2')).toBeTruthy();
    });
    // 轮询间隔输入框应显示 2（秒）
    expect((screen.getByDisplayValue('2') as HTMLInputElement).value).toBe('2');
  });

  it('非法间隔被校验拦截且不调用 updateConfig', async () => {
    render(<ConfigPanel />);
    await waitFor(() => expect(screen.getByDisplayValue('2')).toBeTruthy());

    const interval = screen.getByDisplayValue('2');
    fireEvent.input(interval, { target: { value: '0' } });

    fireEvent.click(screen.getByText('保存配置'));

    await waitFor(() => {
      expect(screen.getByText('轮询间隔需为 1-86400 的整数（秒）')).toBeTruthy();
    });
    // 仅挂载时 GET 了一次配置，保存被拦截
    expect(fetchMock.mock.calls.length).toBe(1);
  });

  it('保存时提交换算后的值（字节、阈值÷100、smtp_port 字符串）', async () => {
    const { container } = render(<ConfigPanel />);
    await waitFor(() => expect(screen.getByDisplayValue('2')).toBeTruthy());

    // 设置配额上限为 100GB
    fireEvent.input(screen.getByPlaceholderText('示例：100GB'), { target: { value: '100GB' } });
    // 设置两个阈值滑块（第一个为警告，第二个为断开）
    const ranges = container.querySelectorAll('input[type="range"]');
    expect(ranges.length).toBe(2);
    fireEvent.input(ranges[0], { target: { value: '80' } });
    fireEvent.input(ranges[1], { target: { value: '90' } });
    // 设置 smtp 端口字符串
    fireEvent.input(screen.getByPlaceholderText('587'), { target: { value: '587' } });

    fireEvent.click(screen.getByText('保存配置'));

    await waitFor(() => {
      const putCall = fetchMock.mock.calls.find((c) => (c[1] as RequestInit)?.method === 'PUT');
      expect(putCall).toBeTruthy();
    });

    const putCall = fetchMock.mock.calls.find((c) => (c[1] as RequestInit)?.method === 'PUT')!;
    const body = JSON.parse(putCall[1].body as string);
    expect(body.quota_limit_bytes).toBe(100 * 1024 * 1024 * 1024);
    expect(body.quota_warning_threshold).toBe(0.8);
    expect(body.quota_disconnect_threshold).toBe(0.9);
    expect(body.smtp_port).toBe('587');
  });
});
