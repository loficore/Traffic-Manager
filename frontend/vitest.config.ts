// ── Vitest 测试配置 ──
import { defineConfig } from 'vitest/config';
import preact from '@preact/preset-vite';

// 使用 jsdom 模拟浏览器环境，Preact 预设支持 JSX
export default defineConfig({
  plugins: [preact()],
  test: {
    environment: 'jsdom',
    globals: true,
  },
});
