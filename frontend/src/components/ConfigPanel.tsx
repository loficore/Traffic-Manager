// ── 配置表单组件 ──
// 覆盖后端 Config 的全部字段，提交时做单位换算与客户端校验。
import type { ComponentChildren } from 'preact';
import { useSignal } from '@preact/signals';
import { useEffect } from 'preact/hooks';
import { fetchConfig, updateConfig, type Config } from '../api';
import { parseSizeToBytes } from '../format';

// 表单字段类型（quota_limit_bytes 以文本形式编辑，便于输入 "100GB"）
interface FormState {
  interface: string;
  interval_sec: string;
  retention_days: string;
  quota_limit_text: string; // "100GB" 形式
  quota_warning: number; // 0..100 滑块
  quota_disconnect: number; // 0..100 滑块
  quota_reset_day: string;
  reset_day: string;
  webhook_url: string;
  smtp_server: string;
  smtp_port: string;
  smtp_user: string;
  smtp_pass: string;
  smtp_from: string;
  smtp_to: string;
}

// 将后端 Config 映射到表单状态
function toForm(cfg: Config): FormState {
  return {
    interface: cfg.interface ?? '',
    interval_sec: String(cfg.interval_sec),
    retention_days: String(cfg.retention_days),
    quota_limit_text: cfg.quota_limit_bytes > 0 ? String(cfg.quota_limit_bytes) : '',
    quota_warning: Math.round(cfg.quota_warning_threshold * 100),
    quota_disconnect: Math.round(cfg.quota_disconnect_threshold * 100),
    quota_reset_day: String(cfg.quota_reset_day),
    reset_day: String(cfg.reset_day),
    webhook_url: cfg.webhook_url ?? '',
    smtp_server: cfg.smtp_server ?? '',
    smtp_port: cfg.smtp_port ?? '',
    smtp_user: cfg.smtp_user ?? '',
    smtp_pass: cfg.smtp_pass ?? '',
    smtp_from: cfg.smtp_from ?? '',
    smtp_to: cfg.smtp_to ?? '',
  };
}

export default function ConfigPanel() {
  const form = useSignal<FormState | null>(null);
  const errors = useSignal<Record<string, string>>({});
  const message = useSignal<{ type: 'ok' | 'err'; text: string } | null>(null);
  const saving = useSignal<boolean>(false);

  // 初始化加载配置
  useEffect(() => {
    fetchConfig()
      .then((cfg) => {
        form.value = toForm(cfg);
      })
      .catch((e) => {
        message.value = { type: 'err', text: e instanceof Error ? e.message : '加载配置失败' };
      });
  }, []);

  // 更新单个字段
  function setField<K extends keyof FormState>(key: K, value: FormState[K]) {
    if (!form.value) return;
    form.value = { ...form.value, [key]: value };
    // 清除该字段已有错误
    if (errors.value[key]) {
      const next = { ...errors.value };
      delete next[key];
      errors.value = next;
    }
  }

  // 客户端校验：返回字段 -> 错误信息 映射
  function validate(f: FormState): Record<string, string> {
    const err: Record<string, string> = {};
    const interval = Number(f.interval_sec);
    if (!Number.isInteger(interval) || interval < 1 || interval > 86400) {
      err.interval_sec = '轮询间隔需为 1-86400 的整数（秒）';
    }
    const retention = Number(f.retention_days);
    if (!Number.isInteger(retention) || retention < 1 || retention > 3650) {
      err.retention_days = '保留天数需为 1-3650 的整数';
    }
    if (f.quota_limit_text.trim() !== '' && parseSizeToBytes(f.quota_limit_text) === null) {
      err.quota_limit_text = '配额格式无效，示例：100GB / 500MB';
    }
    const warn = f.quota_warning;
    const disc = f.quota_disconnect;
    if (warn < 0 || warn > 100) err.quota_warning = '警告阈值需在 0-100 之间';
    if (disc < 0 || disc > 100) err.quota_disconnect = '断开阈值需在 0-100 之间';
    if (disc < warn) err.quota_disconnect = '断开阈值不应低于警告阈值';
    const qday = Number(f.quota_reset_day);
    if (!Number.isInteger(qday) || qday < 1 || qday > 28) {
      err.quota_reset_day = '配额重置日需为 1-28 的整数';
    }
    const rday = Number(f.reset_day);
    if (!Number.isInteger(rday) || rday < 1 || rday > 28) {
      err.reset_day = '重置日需为 1-28 的整数';
    }
    return err;
  }

  // 提交保存
  async function handleSave() {
    if (!form.value) return;
    const f = form.value;
    const err = validate(f);
    errors.value = err;
    if (Object.keys(err).length > 0) {
      message.value = { type: 'err', text: '请修正表单中的错误后再保存' };
      return;
    }
    saving.value = true;
    message.value = null;
    try {
      const limitText = f.quota_limit_text.trim();
      const payload: Partial<Config> = {
        interface: f.interface.trim() === '' ? null : f.interface.trim(),
        interval_sec: Number(f.interval_sec),
        retention_days: Number(f.retention_days),
        quota_limit_bytes: limitText === '' ? 0 : (parseSizeToBytes(limitText) as number),
        quota_warning_threshold: f.quota_warning / 100,
        quota_disconnect_threshold: f.quota_disconnect / 100,
        quota_reset_day: Number(f.quota_reset_day),
        reset_day: Number(f.reset_day),
        webhook_url: f.webhook_url.trim() === '' ? null : f.webhook_url.trim(),
        smtp_server: f.smtp_server.trim() === '' ? null : f.smtp_server.trim(),
        smtp_port: f.smtp_port.trim() === '' ? null : f.smtp_port.trim(),
        smtp_user: f.smtp_user.trim() === '' ? null : f.smtp_user.trim(),
        smtp_pass: f.smtp_pass.trim() === '' ? null : f.smtp_pass.trim(),
        smtp_from: f.smtp_from.trim() === '' ? null : f.smtp_from.trim(),
        smtp_to: f.smtp_to.trim() === '' ? null : f.smtp_to.trim(),
      };
      const updated = await updateConfig(payload);
      // 用后端返回的最新配置回填表单，确保数值一致
      form.value = toForm(updated);
      message.value = { type: 'ok', text: '配置已保存' };
    } catch (e) {
      // 保存失败时保留已填写内容
      message.value = { type: 'err', text: e instanceof Error ? e.message : '保存失败' };
    } finally {
      saving.value = false;
    }
  }

  if (!form.value) {
    return <div class="p-6 text-gray-500">加载中…</div>;
  }

  const f = form.value;
  const e = errors.value;

  // 统一字段渲染辅助
  function Field({ label, children }: { label: string; children: ComponentChildren }) {
    return (
      <label class="block">
        <span class="mb-1 block text-sm font-medium text-gray-600">{label}</span>
        {children}
      </label>
    );
  }
  const inputCls = 'w-full rounded border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none';
  const errCls = 'mt-1 text-xs text-red-600';

  return (
    <div class="p-6">
      <div class="mx-auto max-w-3xl space-y-5 rounded-lg border border-gray-200 bg-white p-6">
        <h3 class="text-lg font-semibold text-gray-800">系统配置</h3>

        <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
          <Field label="网络接口">
            <input class={inputCls} value={f.interface} placeholder="留空=自动" onInput={(ev) => setField('interface', (ev.target as HTMLInputElement).value)} />
          </Field>
          <Field label="轮询间隔（秒）">
            <input class={inputCls} value={f.interval_sec} onInput={(ev) => setField('interval_sec', (ev.target as HTMLInputElement).value)} />
            {e.interval_sec && <div class={errCls}>{e.interval_sec}</div>}
          </Field>

          <Field label="保留天数">
            <input class={inputCls} value={f.retention_days} onInput={(ev) => setField('retention_days', (ev.target as HTMLInputElement).value)} />
            {e.retention_days && <div class={errCls}>{e.retention_days}</div>}
          </Field>
          <Field label="月度配额上限（如 100GB）">
            <input class={inputCls} value={f.quota_limit_text} placeholder="示例：100GB" onInput={(ev) => setField('quota_limit_text', (ev.target as HTMLInputElement).value)} />
            {e.quota_limit_text && <div class={errCls}>{e.quota_limit_text}</div>}
          </Field>

          <Field label={`警告阈值（${f.quota_warning}%）`}>
            <input type="range" min="0" max="100" value={f.quota_warning} class="w-full" onInput={(ev) => setField('quota_warning', Number((ev.target as HTMLInputElement).value))} />
            {e.quota_warning && <div class={errCls}>{e.quota_warning}</div>}
          </Field>
          <Field label={`断开阈值（${f.quota_disconnect}%）`}>
            <input type="range" min="0" max="100" value={f.quota_disconnect} class="w-full" onInput={(ev) => setField('quota_disconnect', Number((ev.target as HTMLInputElement).value))} />
            {e.quota_disconnect && <div class={errCls}>{e.quota_disconnect}</div>}
          </Field>

          <Field label="配额重置日（1-28）">
            <input class={inputCls} value={f.quota_reset_day} onInput={(ev) => setField('quota_reset_day', (ev.target as HTMLInputElement).value)} />
            {e.quota_reset_day && <div class={errCls}>{e.quota_reset_day}</div>}
          </Field>
          <Field label="重置日（1-28）">
            <input class={inputCls} value={f.reset_day} onInput={(ev) => setField('reset_day', (ev.target as HTMLInputElement).value)} />
            {e.reset_day && <div class={errCls}>{e.reset_day}</div>}
          </Field>

          <Field label="Webhook 地址">
            <input class={inputCls} value={f.webhook_url} placeholder="https://..." onInput={(ev) => setField('webhook_url', (ev.target as HTMLInputElement).value)} />
          </Field>
          <Field label="SMTP 服务器">
            <input class={inputCls} value={f.smtp_server} placeholder="smtp.example.com" onInput={(ev) => setField('smtp_server', (ev.target as HTMLInputElement).value)} />
          </Field>

          <Field label="SMTP 端口（字符串）">
            <input class={inputCls} value={f.smtp_port} placeholder="587" onInput={(ev) => setField('smtp_port', (ev.target as HTMLInputElement).value)} />
          </Field>
          <Field label="SMTP 用户名">
            <input class={inputCls} value={f.smtp_user} onInput={(ev) => setField('smtp_user', (ev.target as HTMLInputElement).value)} />
          </Field>

          <Field label="SMTP 密码">
            <input type="password" class={inputCls} value={f.smtp_pass} onInput={(ev) => setField('smtp_pass', (ev.target as HTMLInputElement).value)} />
          </Field>
          <Field label="SMTP 发件人">
            <input class={inputCls} value={f.smtp_from} placeholder="noreply@example.com" onInput={(ev) => setField('smtp_from', (ev.target as HTMLInputElement).value)} />
          </Field>

          <Field label="SMTP 收件人">
            <input class={inputCls} value={f.smtp_to} placeholder="admin@example.com" onInput={(ev) => setField('smtp_to', (ev.target as HTMLInputElement).value)} />
          </Field>
        </div>

        {message.value && (
          <div class={`rounded px-4 py-2 text-sm ${message.value.type === 'ok' ? 'border border-green-200 bg-green-50 text-green-700' : 'border border-red-200 bg-red-50 text-red-700'}`}>
            {message.value.text}
          </div>
        )}

        <button
          class="rounded bg-blue-600 px-5 py-2 text-white hover:bg-blue-700 disabled:opacity-50"
          onClick={handleSave}
          disabled={saving.value}
        >
          {saving.value ? '保存中…' : '保存配置'}
        </button>
      </div>
    </div>
  );
}
