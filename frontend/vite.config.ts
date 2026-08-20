import { defineConfig } from 'vite';
import preact from '@preact/preset-vite';
import tailwindcss from '@tailwindcss/vite';
import { viteSingleFile } from 'vite-plugin-singlefile';

// Vite 构建配置：Preact + Tailwind CSS v4 + 单文件产物
// 单文件 HTML 便于后期通过 @embedFile 嵌入 Zig 二进制
export default defineConfig({
  plugins: [preact(), tailwindcss(), viteSingleFile()],
  build: {
    outDir: 'dist',
    rollupOptions: {
      output: {
        // 禁用代码分割，确保所有 JS 合并为单一块以便内联
        inlineDynamicImports: true,
      },
    },
  },
  server: {
    proxy: {
      // 开发环境代理：/api 请求转发到 Zig 后端
      '/api': {
        target: 'http://localhost:8080',
        changeOrigin: true,
      },
    },
  },
});
