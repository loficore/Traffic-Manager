const std = @import("std");

pub fn build(b: *std.Build) void {
    // 获取命令行传入的 target 与 optimize 选项（如 -Dtarget=mips-linux-musl -Doptimize=ReleaseFast）
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 添加 zqlite 依赖
    const zqlite_dep = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });

    // 创建后端可执行文件配置
    const exe = b.addExecutable(.{
        .name = "traffic-backend",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.link_libc = true;

    // 添加 zqlite 模块依赖（对所有源文件可见）
    exe.root_module.addImport("zqlite", zqlite_dep.module("zqlite"));

    // 添加 SMTP C 库的 include 路径和源文件
    exe.root_module.addIncludePath(b.path("vendor/smtp"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("vendor/smtp/smtp.c"),
        .flags = &.{},
    });

    // 将产物安装到 zig-out/bin/
    b.installArtifact(exe);

    // 添加 `zig build run` 步骤
    const run_cmd = b.addRunArtifact(exe);
    // 确保在运行前先完成安装步骤
    run_cmd.step.dependOn(b.getInstallStep());

    // 允许透传命令行参数，例如：zig build run -- --port 8080
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "运行后端服务");
    run_step.dependOn(&run_cmd.step);

    // ── Original inline tests (refAllDecls in main.zig) ──
    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_unit_tests.root_module.link_libc = true;
    exe_unit_tests.root_module.addImport("zqlite", zqlite_dep.module("zqlite"));
    exe_unit_tests.root_module.addIncludePath(b.path("vendor/smtp"));
    exe_unit_tests.root_module.addCSourceFile(.{
        .file = b.path("vendor/smtp/smtp.c"),
        .flags = &.{},
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "运行单元测试");
    test_step.dependOn(&run_exe_unit_tests.step);

    // ── Independent test files (tests/) ──
    // Each test file imports its source module by name (e.g. @import("quota")).
    // The build system wires the source module as a named dependency.

    // Source module: quota (depends on zqlite)
    const quota_src = b.createModule(.{
        .root_source_file = b.path("src/quota.zig"),
        .target = target,
        .optimize = optimize,
    });
    quota_src.addImport("zqlite", zqlite_dep.module("zqlite"));

    // Source module: config
    const config_src = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Source module: config_store (depends on zqlite + config)
    const config_store_src = b.createModule(.{
        .root_source_file = b.path("src/config_store.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_store_src.addImport("zqlite", zqlite_dep.module("zqlite"));
    config_store_src.addImport("config", config_src);

    // Source module: log
    const log_src = b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Source module: network (needs libc for @cImport)
    const network_src = b.createModule(.{
        .root_source_file = b.path("src/network.zig"),
        .target = target,
        .optimize = optimize,
    });
    network_src.link_libc = true;

    // Source module: notify_template
    const notify_src = b.createModule(.{
        .root_source_file = b.path("src/notify_template.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Source module: smtp (needs libc for @cImport)
    const smtp_src = b.createModule(.{
        .root_source_file = b.path("src/smtp.zig"),
        .target = target,
        .optimize = optimize,
    });
    smtp_src.link_libc = true;
    smtp_src.addIncludePath(b.path("vendor/smtp"));
    smtp_src.addCSourceFile(.{
        .file = b.path("vendor/smtp/smtp.c"),
        .flags = &.{},
    });

    // Source module: webhook
    const webhook_src = b.createModule(.{
        .root_source_file = b.path("src/webhook.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Source module: http_server (depends on zqlite + config + quota + config_store + log)
    const http_server_src = b.createModule(.{
        .root_source_file = b.path("src/http_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    http_server_src.addImport("zqlite", zqlite_dep.module("zqlite"));
    http_server_src.addImport("config", config_src);
    http_server_src.addImport("quota", quota_src);
    http_server_src.addImport("config_store", config_store_src);
    http_server_src.addImport("log", log_src);

    // Test file definitions: (test_file, source_module_name, source_module)
    const test_defs = [_]struct {
        file: []const u8,
        src_name: []const u8,
        src_mod: *std.Build.Module,
    }{
        .{ .file = "tests/test_quota.zig", .src_name = "quota", .src_mod = quota_src },
        .{ .file = "tests/test_config.zig", .src_name = "cfg", .src_mod = config_src },
        .{ .file = "tests/test_log.zig", .src_name = "log_mod", .src_mod = log_src },
        .{ .file = "tests/test_network.zig", .src_name = "network", .src_mod = network_src },
        .{ .file = "tests/test_notify.zig", .src_name = "notify", .src_mod = notify_src },
        .{ .file = "tests/test_smtp.zig", .src_name = "smtp", .src_mod = smtp_src },
        .{ .file = "tests/test_webhook.zig", .src_name = "webhook", .src_mod = webhook_src },
        .{ .file = "tests/test_config_store.zig", .src_name = "config_store", .src_mod = config_store_src },
        .{ .file = "tests/test_http_server.zig", .src_name = "http_server", .src_mod = http_server_src },
        .{ .file = "tests/test_integration.zig", .src_name = "config_store", .src_mod = config_store_src },
    };

    for (test_defs) |td| {
        const test_mod = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(td.file),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_mod.root_module.addImport(td.src_name, td.src_mod);
        // 需要 zqlite 访问的测试模块
        if (std.mem.eql(u8, td.src_name, "config_store") or std.mem.eql(u8, td.src_name, "quota") or std.mem.eql(u8, td.src_name, "http_server")) {
            test_mod.root_module.addImport("zqlite", zqlite_dep.module("zqlite"));
        }
        // 集成测试额外依赖 quota（config 已通过 config_store 内部的 config 模块间接可用）
        if (std.mem.eql(u8, td.file, "tests/test_integration.zig")) {
            test_mod.root_module.addImport("quota", quota_src);
        }

        const run_test_mod = b.addRunArtifact(test_mod);
        test_step.dependOn(&run_test_mod.step);
    }
}
