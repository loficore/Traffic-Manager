// ── 通用格式化与单位换算工具 ──

// 字节单位基数（1024 进制）
const UNIT_STEP = 1024;
const BYTE_UNITS = ["B", "KB", "MB", "GB", "TB", "PB"] as const;

/// 将字节数格式化为带合适单位的字符串（如 1536 -> "1.50 KB"）
export function formatBytes(bytes: number): string {
  if (!isFinite(bytes) || bytes <= 0) return "0 B";
  const exp = Math.min(
    Math.floor(Math.log(bytes) / Math.log(UNIT_STEP)),
    BYTE_UNITS.length - 1,
  );
  const value = bytes / Math.pow(UNIT_STEP, exp);
  // 大于 100 字节时不保留小数，避免冗余
  const fixed = exp === 0 ? String(value) : value.toFixed(2);
  return `${fixed} ${BYTE_UNITS[exp]}`;
}

/// 将人类可读大小（如 "100GB"、5MB、2tb）转换为字节数，非法输入返回 null
export function parseSizeToBytes(input: string): number | null {
  const trimmed = input.trim();
  if (trimmed.length === 0) return null;

  // 分离数字部分与单位部分
  let digitEnd = 0;
  while (digitEnd < trimmed.length && trimmed[digitEnd] >= "0" && trimmed[digitEnd] <= "9") {
    digitEnd += 1;
  }
  if (digitEnd === 0) return null;

  const numStr = trimmed.slice(0, digitEnd);
  const unit = trimmed.slice(digitEnd).toUpperCase();
  const num = Number(numStr);
  if (!Number.isFinite(num)) return null;

  const multiplier = unitToMultiplier(unit);
  if (multiplier === null) return null;
  return Math.round(num * multiplier);
}

// 将单位后缀映射到字节乘数，支持 B/KB/MB/GB/TB（不区分大小写）
function unitToMultiplier(unit: string): number | null {
  switch (unit) {
    case "":
    case "B":
      return 1;
    case "KB":
    case "K":
      return 1024;
    case "MB":
    case "M":
      return 1024 * 1024;
    case "GB":
    case "G":
      return 1024 * 1024 * 1024;
    case "TB":
    case "T":
      return 1024 * 1024 * 1024 * 1024;
    case "PB":
    case "P":
      return 1024 * 1024 * 1024 * 1024 * 1024;
    default:
      return null;
  }
}

/// 将秒数格式化为可读运行时长（如 123 -> "2分3秒"）
export function formatUptime(seconds: number): string {
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  const parts: string[] = [];
  if (d > 0) parts.push(`${d}天`);
  if (h > 0) parts.push(`${h}时`);
  if (m > 0) parts.push(`${m}分`);
  parts.push(`${s}秒`);
  return parts.join("");
}
