const std = @import("std");

const dergdrive = @import("dergdrive");
const znetw = @import("znetw");

pub const std_options: std.Options = .{
    .logFn = struct {
        var decorate: ?bool = null;

        pub fn logFn(comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime fmt: []const u8, args: anytype) void {
            if (decorate == null)
                decorate = std.fs.File.stderr().getOrEnableAnsiEscapeSupport();

            if (decorate.?) {
                var buf: [128]u8 = undefined;
                const level_txt = switch (level) {
                    .debug => "",
                    .err => "\x1b[31m",
                    .info => "\x1b[34m",
                    .warn => "\x1b[33m",
                } ++ comptime level.asText() ++ "\x1b[0m";
                const prefix2 = "\x1b[2m" ++ if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): " ++ "\x1b[0m";

                const w = std.debug.lockStderrWriter(&buf);
                defer std.debug.unlockStderrWriter();
                w.print(level_txt ++ prefix2 ++ fmt ++ "\n", args) catch return;
            } else std.log.defaultLog(level, scope, fmt, args);
        }
    }.logFn,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    dergdrive.cli.command_exec.exec(args[1..], allocator) catch |err| switch (err) {
        error.ReturnStatusFailure => std.process.exit(1),
        else => |e| {
            var w = std.fs.File.stderr().writerStreaming(&.{});
            w.interface.writeByte('\n') catch return w.err.?;

            switch (e) {
                error.UnknownCommand => std.log.err("unknown command: {s}", .{args[1]}),
                error.NoArgsProvided => std.log.err("expected command argument", .{}),
                error.InvalidSyntax => std.log.err("invalid syntax", .{}),
            }

            std.process.exit(64);
        },
    };
}
