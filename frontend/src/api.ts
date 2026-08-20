// ── API 客户端 ──
// 封装后端 REST 接口，所有请求基于 /api 前缀。
// 请求失败时抛出错误（非 2xx 状态码）。

/// 统一请求封装：向 /api${path} 发起请求，非 ok 时抛错
async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`/api${path}`, init);
  if (!res.ok) {
    throw new Error(`请求失败: ${res.status} ${res.statusText}`);
  }
  return (await res.json()) as T;
}

// ── 类型定义（与 backend/src/http_server.zig 严格对应）──

/// GET /status 响应
export interface StatusResponse {
  state: string; // running / stopped 等
  interface: string; // 当前监控网卡名
  uptime_seconds: number;
  quota_state: "disabled" | "normal" | "warned" | "exceeded";
}

/// GET /traffic/current 响应
export interface CurrentTraffic {
  rx_speed_bps: number;
  tx_speed_bps: number;
  rx_pps: number;
  tx_pps: number;
  total_rx_bytes: number;
  total_tx_bytes: number;
}

/// GET /traffic/daily 单条记录
export interface DailyRecord {
  date: string; // YYYY-MM-DD
  rx_bytes: number;
  tx_bytes: number;
}

/// GET /config 完整配置（字段与 backend/src/config.zig 一致）
export interface Config {
  interface: string | null;
  interval_sec: number;
  retention_days: number;
  day_count: number;
  quota_limit_bytes: number; // 原始字节数
  quota_warning_threshold: number; // 0..1 比例
  quota_disconnect_threshold: number; // 0..1 比例
  quota_reset_day: number;
  reset_day: number;
  webhook_url: string | null;
  smtp_server: string | null;
  smtp_port: string | null; // 注意：以字符串传输
  smtp_user: string | null;
  smtp_pass: string | null;
  smtp_from: string | null;
  smtp_to: string | null;
}

/// GET /quota 配额快照
export interface QuotaSnapshot {
  base_limit_bytes: number;
  effective_limit_bytes: number;
  monthly_usage_bytes: number;
  remaining_bytes: number;
  state: "normal" | "warned" | "exceeded" | "disabled";
  warning_threshold: number;
  disconnect_threshold: number;
  reset_day: number;
}

/// GET /quota/adjustments 单条调整记录
export interface QuotaAdjustment {
  id: number;
  amount_bytes: number;
  reason: string;
  source: string;
  month_key: string; // YYYY-MM
  created_at: number; // 毫秒时间戳
}

/// POST /quota/adjustments 入参（amount_bytes 与 amount 二选一）
export interface AdjustmentInput {
  amount_bytes?: number;
  amount?: string;
  reason?: string;
  source?: string;
}

// ── API 函数 ──

/// 获取运行状态（网卡名、运行时长、配额状态）
export function fetchStatus(): Promise<StatusResponse> {
  return request<StatusResponse>("/status");
}

/// 获取实时速率与累计流量
export function fetchCurrentTraffic(): Promise<CurrentTraffic> {
  return request<CurrentTraffic>("/traffic/current");
}

/// 获取最近 days 天的每日流量（date 降序）
export function fetchDailyTraffic(days: number): Promise<DailyRecord[]> {
  return request<DailyRecord[]>(`/traffic/daily?days=${days}`);
}

/// 获取完整配置
export function fetchConfig(): Promise<Config> {
  return request<Config>("/config");
}

/// 部分更新配置，返回更新后的完整配置
export function updateConfig(cfg: Partial<Config>): Promise<Config> {
  return request<Config>("/config", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(cfg),
  });
}

/// 获取配额快照
export function fetchQuota(): Promise<QuotaSnapshot> {
  return request<QuotaSnapshot>("/quota");
}

/// 获取当月配额调整列表
export function fetchAdjustments(): Promise<QuotaAdjustment[]> {
  return request<QuotaAdjustment[]>("/quota/adjustments");
}

/// 新增配额调整，返回新建记录的关键信息
export function addAdjustment(
  input: AdjustmentInput,
): Promise<{ id: number; amount_bytes: number; month_key: string }> {
  return request<{ id: number; amount_bytes: number; month_key: string }>(
    "/quota/adjustments",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(input),
    },
  );
}

/// 删除指定 id 的配额调整
export function removeAdjustment(id: number): Promise<{ ok: boolean }> {
  return request<{ ok: boolean }>(`/quota/adjustments/${id}`, {
    method: "DELETE",
  });
}
