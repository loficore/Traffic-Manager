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

    // 添加 `zig build test` 单元测试步骤
    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_unit_tests.root_module.link_libc = true;
    exe_unit_tests.root_module.addImport("zqlite", zqlite_dep.module("zqlite"));

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "运行单元测试");
    test_step.dependOn(&run_exe_unit_tests.step);
}
