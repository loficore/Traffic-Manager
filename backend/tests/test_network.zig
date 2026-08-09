// backend/tests/test_network.zig
// Independent tests for the network module.
// Tests only public API of src/network.zig.
// Note: "Ifreq struct layout" test is excluded because Ifreq is a private type.
const std = @import("std");
const network = @import("network");

const NetworkError = network.NetworkError;

test "queryInterfaceStatus on Linux" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const status = try network.queryInterfaceStatus("lo");
    try std.testing.expect(status);
}

test "queryInterfaceStatus with invalid name" {
    const result = network.queryInterfaceStatus("");
    try std.testing.expectError(NetworkError.InterfaceNotFound, result);

    const long_name = "this_interface_name_is_definitely_way_too_long_for_ifreq_struct";
    const result2 = network.queryInterfaceStatus(long_name);
    try std.testing.expectError(NetworkError.InterfaceNotFound, result2);
}

test "queryInterfaceStatus nonexistent interface" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    // Name must be < IFNAMSIZ (16) to pass fillIfreqName, but still nonexistent
    const result = network.queryInterfaceStatus("nonexist99");
    try std.testing.expectError(NetworkError.IoctlFailed, result);
}

test "disconnect and restore lo (requires root)" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;

    try network.disconnectInterface("lo");
    try std.testing.expect(!try network.queryInterfaceStatus("lo"));

    try network.restoreInterface("lo");
    try std.testing.expect(try network.queryInterfaceStatus("lo"));
}
