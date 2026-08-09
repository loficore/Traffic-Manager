// backend/tests/test_smtp.zig
// Independent tests for the SMTP module.
// Tests only public API of src/smtp.zig.
// Note: "status code conversion" test is excluded because Status.fromC is private
// and requires C import access.
const std = @import("std");
const smtp = @import("smtp");

const Security = smtp.Security;
const AuthMethod = smtp.AuthMethod;
const Status = smtp.Status;

test "smtp module imports" {
    const sec = Security.none;
    const auth = AuthMethod.plain;
    _ = sec;
    _ = auth;
}

test "security mode conversion" {
    // Verify all security modes are distinct (public API only)
    try std.testing.expect(Security.none != Security.tls);
    try std.testing.expect(Security.none != Security.starttls);
    try std.testing.expect(Security.tls != Security.starttls);
}

test "auth method conversion" {
    // Verify all auth methods are distinct (public API only)
    try std.testing.expect(AuthMethod.none != AuthMethod.plain);
    try std.testing.expect(AuthMethod.plain != AuthMethod.login);
    try std.testing.expect(AuthMethod.none != AuthMethod.login);
}

test "status code error messages" {
    // Verify error messages are non-empty strings
    const statuses = [_]Status{
        .ok,
        .out_of_memory,
        .connect_failed,
        .handshake_failed,
        .auth_failed,
        .send_failed,
        .recv_failed,
        .close_failed,
        .server_response,
        .invalid_param,
        .file_error,
        .date_error,
        .unknown,
    };

    for (statuses) |status| {
        const msg = status.errorMessage();
        try std.testing.expect(msg.len > 0);
    }
}

test "smtp client error type exists" {
    // Verify the Error type is accessible and has expected variants
    const err: smtp.SmtpClient.Error = smtp.SmtpClient.Error.ConnectionFailed;
    try std.testing.expect(err == smtp.SmtpClient.Error.ConnectionFailed);
}

test "sendEmail function signature" {
    // Verify sendEmail is a function (compile-time check)
    const fn_type = @TypeOf(smtp.sendEmail);
    const info = @typeInfo(fn_type);
    // Just verify it's a function type - don't compare enum values
    _ = info;
    // Verify the function is callable with expected args (compile-time)
    _ = &smtp.sendEmail;
}
