# TrafficManager 构建脚本
# 构建流程：构建前端 → 复制产物到 backend 包内（满足 @embedFile 包路径限制）→ 编译后端
build:
    cd frontend && pnpm build
    cp frontend/dist/index.html backend/src/dashboard.html
    cd backend && zig build

# 运行后端测试
test:
    cd frontend && pnpm build
    cp frontend/dist/index.html backend/src/dashboard.html
    cd backend && zig build test
