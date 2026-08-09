// backend/src/smtp.zig
// SMTP notification module using somnisoft/smtp-client C library.
//
// Provides a high-level Zig interface for sending emails via SMTP.
// Requires OpenSSL for TLS support.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("smtp.h");
});

/// SMTP connection security mode.
pub const Security = enum {
    none,
    tls,
    starttls,

    fn toC(self: Security) c.enum_smtp_connection_security {
        return switch (self) {
            .none => c.SMTP_SECURITY_NOTSET,
            .tls => c.SMTP_SECURITY_TLS,
            .starttls => c.SMTP_SECURITY_STARTTLS,
        };
    }
};

/// SMTP authentication method.
pub const AuthMethod = enum {
    none,
    plain,
    login,

    fn toC(self: AuthMethod) c.enum_smtp_authentication_method {
        return switch (self) {
            .none => c.SMTP_AUTH_NONE,
            .plain => c.SMTP_AUTH_PLAIN,
            .login => c.SMTP_AUTH_LOGIN,
        };
    }
};

/// SMTP status code.
pub const Status = enum {
    ok,
    out_of_memory,
    connect_failed,
    handshake_failed,
    auth_failed,
    send_failed,
    recv_failed,
    close_failed,
    server_response,
    invalid_param,
    file_error,
    date_error,
    unknown,

    fn fromC(code: c.enum_smtp_status_code) Status {
        return switch (code) {
            c.SMTP_STATUS_OK => .ok,
            c.SMTP_STATUS_NOMEM => .out_of_memory,
            c.SMTP_STATUS_CONNECT => .connect_failed,
            c.SMTP_STATUS_HANDSHAKE => .handshake_failed,
            c.SMTP_STATUS_AUTH => .auth_failed,
            c.SMTP_STATUS_SEND => .send_failed,
            c.SMTP_STATUS_RECV => .recv_failed,
            c.SMTP_STATUS_CLOSE => .close_failed,
            c.SMTP_STATUS_SERVER_RESPONSE => .server_response,
            c.SMTP_STATUS_PARAM => .invalid_param,
            c.SMTP_STATUS_FILE => .file_error,
            c.SMTP_STATUS_DATE => .date_error,
            else => .unknown,
        };
    }

    pub fn errorMessage(self: Status) []const u8 {
        return switch (self) {
            .ok => "Success",
            .out_of_memory => "Memory allocation failed",
            .connect_failed => "Failed to connect to mail server",
            .handshake_failed => "Failed to handshake or negotiate TLS",
            .auth_failed => "Failed to authenticate",
            .send_failed => "Failed to send data to server",
            .recv_failed => "Failed to receive data from server",
            .close_failed => "Failed to close connection",
            .server_response => "Server sent unexpected response",
            .invalid_param => "Invalid parameter",
            .file_error => "Failed to read or open file",
            .date_error => "Failed to get local date and time",
            .unknown => "Unknown error",
        };
    }
};

/// SMTP client wrapper.
pub const SmtpClient = struct {
    ptr: *c.struct_smtp,
    allocator: Allocator,

    /// Error type for SMTP operations.
    pub const Error = error{
        ConnectionFailed,
        HandshakeFailed,
        AuthFailed,
        SendFailed,
        ServerResponse,
        InvalidParam,
        OutOfMemory,
        Unknown,
    };

    /// Open a connection to an SMTP server.
    pub fn open(
        allocator: Allocator,
        server: [*:0]const u8,
        port: [*:0]const u8,
        security: Security,
        cafile: ?[*:0]const u8,
    ) Error!SmtpClient {
        var smtp_ptr: ?*c.struct_smtp = null;
        const status = c.smtp_open(server, port, security.toC(), c.SMTP_FLAG_NONE, cafile, &smtp_ptr);

        if (status != c.SMTP_STATUS_OK) {
            return switch (status) {
                c.SMTP_STATUS_CONNECT => Error.ConnectionFailed,
                c.SMTP_STATUS_HANDSHAKE => Error.HandshakeFailed,
                c.SMTP_STATUS_NOMEM => Error.OutOfMemory,
                else => Error.Unknown,
            };
        }

        return SmtpClient{
            .ptr = smtp_ptr.?,
            .allocator = allocator,
        };
    }

    /// Authenticate with the SMTP server.
    pub fn authenticate(
        self: SmtpClient,
        method: AuthMethod,
        user: [*:0]const u8,
        pass: [*:0]const u8,
    ) Error!void {
        const status = c.smtp_auth(self.ptr, method.toC(), user, pass);
        if (status != c.SMTP_STATUS_OK) {
            return switch (status) {
                c.SMTP_STATUS_AUTH => Error.AuthFailed,
                c.SMTP_STATUS_NOMEM => Error.OutOfMemory,
                else => Error.Unknown,
            };
        }
    }

    /// Add a FROM address.
    pub fn addFrom(self: SmtpClient, email: [*:0]const u8, name: ?[*:0]const u8) Error!void {
        const status = c.smtp_address_add(self.ptr, c.SMTP_ADDRESS_FROM, email, name);
        if (status != c.SMTP_STATUS_OK) {
            return switch (status) {
                c.SMTP_STATUS_PARAM => Error.InvalidParam,
                c.SMTP_STATUS_NOMEM => Error.OutOfMemory,
                else => Error.Unknown,
            };
        }
    }

    /// Add a TO address.
    pub fn addTo(self: SmtpClient, email: [*:0]const u8, name: ?[*:0]const u8) Error!void {
        const status = c.smtp_address_add(self.ptr, c.SMTP_ADDRESS_TO, email, name);
        if (status != c.SMTP_STATUS_OK) {
            return switch (status) {
                c.SMTP_STATUS_PARAM => Error.InvalidParam,
                c.SMTP_STATUS_NOMEM => Error.OutOfMemory,
                else => Error.Unknown,
            };
        }
    }

    /// Add a CC address.
    pub fn addCc(self: SmtpClient, email: [*:0]const u8, name: ?[*:0]const u8) Error!void {
        const status = c.smtp_address_add(self.ptr, c.SMTP_ADDRESS_CC, email, name);
        if (status != c.SMTP_STATUS_OK) {
            return switch (status) {
                c.SMTP_STATUS_PARAM => Error.InvalidParam,
                c.SMTP_STATUS_NOMEM => Error.OutOfMemory,
                else => Error.Unknown,
            };
        }
    }

    /// Add a BCC address.
    pub fn addBcc(self: SmtpClient, email: [*:0]const u8, name: ?[*:0]const u8) Error!void {
        const status = c.smtp_address_add(self.ptr, c.SMTP_ADDRESS_BCC, email, name);
        if (status != c.SMTP_STATUS_OK) {
            return switch (status) {
                c.SMTP_STATUS_PARAM => Error.InvalidParam,
                c.SMTP_STATUS_NOMEM => Error.OutOfMemory,
                else => Error.Unknown,
            };
        }
    }

    /// Add a custom header.
    pub fn addHeader(self: SmtpClient, key: [*:0]const u8, value: [*:0]const u8) Error!void {
        const status = c.smtp_header_add(self.ptr, key, value);
        if (status != c.SMTP_STATUS_OK) {
            return switch (status) {
                c.SMTP_STATUS_PARAM => Error.InvalidParam,
                c.SMTP_STATUS_NOMEM => Error.OutOfMemory,
                else => Error.Unknown,
            };
        }
    }

    /// Send the email with the given body.
    pub fn send(self: SmtpClient, body: [*:0]const u8) Error!void {
        const status = c.smtp_mail(self.ptr, body);
        if (status != c.SMTP_STATUS_OK) {
            return switch (status) {
                c.SMTP_STATUS_SEND => Error.SendFailed,
                c.SMTP_STATUS_SERVER_RESPONSE => Error.ServerResponse,
                c.SMTP_STATUS_NOMEM => Error.OutOfMemory,
                else => Error.Unknown,
            };
        }
    }

    /// Close the connection and free resources.
    pub fn close(self: SmtpClient) void {
        _ = c.smtp_close(self.ptr);
    }
};

/// High-level function to send a simple email.
pub fn sendEmail(
    allocator: Allocator,
    server: [*:0]const u8,
    port: [*:0]const u8,
    security: Security,
    auth_method: AuthMethod,
    user: [*:0]const u8,
    pass: [*:0]const u8,
    from: [*:0]const u8,
    to: [*:0]const u8,
    subject: [*:0]const u8,
    body: [*:0]const u8,
) SmtpClient.Error!void {
    // Open connection
    var client = try SmtpClient.open(allocator, server, port, security, null);
    errdefer client.close();

    // Authenticate
    if (auth_method != .none) {
        try client.authenticate(auth_method, user, pass);
    }

    // Set addresses
    try client.addFrom(from, null);
    try client.addTo(to, null);

    // Add Subject header
    try client.addHeader("Subject", subject);

    // Send
    try client.send(body);

    // Close
    client.close();
}

test "smtp module imports" {
    // Verify the module compiles and enums are accessible
    const sec = Security.none;
    const auth = AuthMethod.plain;
    _ = sec;
    _ = auth;
}

test "status code conversion" {
    const status = Status.fromC(c.SMTP_STATUS_OK);
    try std.testing.expectEqual(Status.ok, status);
    try std.testing.expectEqualStrings("Success", status.errorMessage());
}
