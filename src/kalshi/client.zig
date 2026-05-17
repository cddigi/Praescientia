//! HTTP transport for the Kalshi trade API. Wraps `std.http.Client` and signs
//! every request with RSA-PSS (via Stage 1 `auth.signRequest`) when credentials
//! are provided. Public endpoints work without credentials.
//!
//! Allocation model: every `request()` call takes a caller-owned arena. The
//! returned `Response.body` is allocated in that arena and lives as long as
//! the arena does. Endpoint modules typically:
//!
//!     var arena: std.heap.ArenaAllocator = .init(gpa);
//!     defer arena.deinit();
//!     const a = arena.allocator();
//!     const resp = try client.request(a, .{ .path = "/exchange/status" });
//!     const parsed = try std.json.parseFromSliceLeaky(StatusBody, a, resp.body, .{});
//!
//! Per the plan, `ArenaAllocator` is lock-free thread-safe in Zig 0.16, so no
//! extra wrapping is needed.

const std = @import("std");
const auth = @import("auth.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Env = enum {
    demo,
    live,

    pub fn baseUrl(env: Env) []const u8 {
        return switch (env) {
            .demo => "https://demo-api.kalshi.co/trade-api/v2",
            .live => "https://api.elections.kalshi.com/trade-api/v2",
        };
    }
};

/// Kalshi prepends `/trade-api/v2` in URLs but the auth signature must be over
/// that same full path. Centralized here so request() and signing agree.
pub const signing_path_prefix = "/trade-api/v2";

pub const Options = struct {
    env: Env = .demo,
    /// API Key ID — null disables authentication.
    key_id: ?[]const u8 = null,
    /// PEM-encoded RSA private key — null disables authentication.
    private_key_pem: ?[]const u8 = null,
};

pub const QueryParam = struct {
    key: []const u8,
    value: []const u8,
};

pub const RequestOptions = struct {
    /// Path *after* `/trade-api/v2`, e.g. `"/exchange/status"`.
    path: []const u8,
    method: std.http.Method = .GET,
    /// JSON body for POST/PUT/DELETE. Caller owns; must outlive the request.
    body: ?[]const u8 = null,
    /// Optional `?k=v&k=v` parameters. Percent-encoded by `request()`.
    query: []const QueryParam = &.{},
    /// Extra headers the caller wants to add (e.g. idempotency keys for orders).
    extra_headers: []const std.http.Header = &.{},
};

pub const Response = struct {
    status: u16,
    body: []const u8,

    pub fn isSuccess(self: Response) bool {
        return self.status >= 200 and self.status < 300;
    }

    /// Parse the body as JSON into `T`. Uses the same allocator the body was
    /// allocated from is expected from the caller. `ignore_unknown_fields`
    /// is enabled because Kalshi adds fields without notice.
    pub fn parseInto(self: Response, comptime T: type, arena: Allocator) !T {
        return std.json.parseFromSliceLeaky(T, arena, self.body, .{ .ignore_unknown_fields = true });
    }
};

pub const Client = struct {
    allocator: Allocator,
    io: Io,
    http: std.http.Client,
    env: Env,
    key_id: ?[]const u8,
    private_key_pem: ?[]const u8,

    pub fn init(allocator: Allocator, io: Io, options: Options) Client {
        return .{
            .allocator = allocator,
            .io = io,
            .http = .{ .allocator = allocator, .io = io },
            .env = options.env,
            .key_id = options.key_id,
            .private_key_pem = options.private_key_pem,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    pub fn hasCredentials(self: *const Client) bool {
        return self.key_id != null and self.private_key_pem != null;
    }

    /// Issue an HTTP request. `arena` provides storage for the URL, headers,
    /// and response body; the caller must keep it alive until done parsing.
    pub fn request(self: *Client, arena: Allocator, opts: RequestOptions) !Response {
        // 1. Build the URL (base + path + ?query).
        var url_buf: std.array_list.Managed(u8) = .init(arena);
        try url_buf.appendSlice(self.env.baseUrl());
        try url_buf.appendSlice(opts.path);
        if (opts.query.len > 0) {
            try url_buf.append('?');
            for (opts.query, 0..) |q, i| {
                if (i > 0) try url_buf.append('&');
                try appendPercentEncoded(&url_buf, q.key);
                try url_buf.append('=');
                try appendPercentEncoded(&url_buf, q.value);
            }
        }

        // 2. Build extra headers: auth (if creds) + caller-supplied.
        var auth_buf: [3]std.http.Header = undefined;
        var auth_count: usize = 0;
        if (self.hasCredentials()) {
            const timestamp_ms = millisSinceEpoch();
            const method_name = @tagName(opts.method);
            const signing_path = try std.mem.concat(arena, u8, &.{ signing_path_prefix, opts.path });
            const sig = try auth.signRequest(arena, self.private_key_pem.?, @intCast(timestamp_ms), method_name, signing_path);
            const ts_str = try std.fmt.allocPrint(arena, "{d}", .{timestamp_ms});
            auth_buf[0] = .{ .name = auth.access_key_header, .value = self.key_id.? };
            auth_buf[1] = .{ .name = auth.access_timestamp_header, .value = ts_str };
            auth_buf[2] = .{ .name = auth.access_signature_header, .value = sig };
            auth_count = 3;
        }
        const all_headers = try arena.alloc(std.http.Header, auth_count + opts.extra_headers.len);
        @memcpy(all_headers[0..auth_count], auth_buf[0..auth_count]);
        @memcpy(all_headers[auth_count..], opts.extra_headers);

        // 3. Issue the HTTP request, collecting the body into the arena.
        var body: std.Io.Writer.Allocating = .init(arena);
        const result = try self.http.fetch(.{
            .location = .{ .url = url_buf.items },
            .method = opts.method,
            .payload = opts.body,
            .extra_headers = all_headers,
            .response_writer = &body.writer,
            .headers = .{
                .accept_encoding = .{ .override = "application/json" },
                .content_type = if (opts.body != null) .{ .override = "application/json" } else .default,
            },
        });

        return .{
            .status = @intFromEnum(result.status),
            .body = body.written(),
        };
    }
};

fn appendPercentEncoded(out: *std.array_list.Managed(u8), s: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (s) |b| {
        const safe = switch (b) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
            else => false,
        };
        if (safe) {
            try out.append(b);
        } else {
            try out.append('%');
            try out.append(hex[b >> 4]);
            try out.append(hex[b & 0x0f]);
        }
    }
}

fn millisSinceEpoch() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const sec: i128 = ts.sec;
    const nsec: i128 = ts.nsec;
    const ms: i128 = sec * 1000 + @divTrunc(nsec, 1_000_000);
    return if (ms < 0) 0 else @intCast(ms);
}

test "percent-encoding leaves safe chars alone, escapes the rest" {
    const a = std.testing.allocator;
    var buf: std.array_list.Managed(u8) = .init(a);
    defer buf.deinit();
    try appendPercentEncoded(&buf, "abc-_.~XYZ012");
    try std.testing.expectEqualStrings("abc-_.~XYZ012", buf.items);

    buf.clearRetainingCapacity();
    try appendPercentEncoded(&buf, "a b/c?d&e=f");
    try std.testing.expectEqualStrings("a%20b%2Fc%3Fd%26e%3Df", buf.items);
}

test "Env.baseUrl matches Kalshi's documented hosts" {
    try std.testing.expectEqualStrings(
        "https://demo-api.kalshi.co/trade-api/v2",
        Env.demo.baseUrl(),
    );
    try std.testing.expectEqualStrings(
        "https://api.elections.kalshi.com/trade-api/v2",
        Env.live.baseUrl(),
    );
}
