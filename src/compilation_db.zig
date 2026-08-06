const std = @import("std");

const RawEntry = struct {
    directory: []const u8,
    file: []const u8,
    arguments: ?[]const []const u8 = null,
    command: ?[]const u8 = null,
};

pub const Entry = struct {
    directory: []const u8,
    file: []const u8,
    arguments: []const []const u8,
};

pub const Database = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,

    pub fn deinit(self: *Database) void {
        self.arena.deinit();
    }
};

pub fn load(io: std.Io, parent_allocator: std.mem.Allocator, path_arg: []const u8) !Database {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    errdefer arena.deinit();

    const allocator = arena.allocator();
    const path = if (std.mem.endsWith(u8, path_arg, ".json"))
        try allocator.dupe(u8, path_arg)
    else
        try std.fs.path.join(allocator, &.{ path_arg, "compile_commands.json" });

    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));

    const raw = try std.json.parseFromSliceLeaky([]const RawEntry, allocator, contents, .{
        .ignore_unknown_fields = true,
    });

    const current_directory = try std.process.currentPathAlloc(io, allocator);
    const entries = try allocator.alloc(Entry, raw.len);

    for (raw, entries) |item, *entry| {
        const directory = if (std.fs.path.isAbsolute(item.directory))
            item.directory
        else
            try std.fs.path.resolve(allocator, &.{ current_directory, item.directory });

        const file = if (std.fs.path.isAbsolute(item.file))
            item.file
        else
            try std.fs.path.resolve(allocator, &.{ directory, item.file });

        const arguments = if (item.arguments) |args|
            args
        else if (item.command) |command|
            try tokenizeCommand(allocator, command)
        else {
            std.log.err("compile command for {s} has neither 'arguments' nor 'command'", .{item.file});
            return error.InvalidCompilationDatabase;
        };

        if (arguments.len == 0) return error.InvalidCompilationDatabase;

        entry.* = .{
            .directory = directory,
            .file = file,
            .arguments = arguments,
        };
    }

    return .{ .arena = arena, .entries = entries };
}

fn tokenizeCommand(allocator: std.mem.Allocator, command: []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    var quote: ?u8 = null;
    var escaped = false;
    var has_token = false;

    for (command) |ch| {
        if (escaped) {
            try current.append(allocator, ch);
            escaped = false;
            has_token = true;
            continue;
        }
        if (ch == '\\' and quote != '\'') {
            escaped = true;
            has_token = true;
            continue;
        }

        if (quote) |q| {
            if (ch == q) quote = null else try current.append(allocator, ch);
            has_token = true;
            continue;
        }

        if (ch == '\'' or ch == '"') {
            quote = ch;
            has_token = true;
        } else if (std.ascii.isWhitespace(ch)) {
            if (has_token) {
                try args.append(allocator, try current.toOwnedSlice(allocator));
                current = .empty;
                has_token = false;
            }
        } else {
            try current.append(allocator, ch);
            has_token = true;
        }
    }

    if (escaped or quote != null) return error.InvalidCompilationDatabase;
    if (has_token) try args.append(allocator, try current.toOwnedSlice(allocator));

    return args.toOwnedSlice(allocator);
}

test "tokenizes shell-style command fields" {
    const allocator = std.testing.allocator;
    const args = try tokenizeCommand(allocator, "clang++ -I'path with spaces' -DNAME=\\\"value\\\" file.cpp");

    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    try std.testing.expectEqual(@as(usize, 4), args.len);
    try std.testing.expectEqualStrings("-Ipath with spaces", args[1]);
    try std.testing.expectEqualStrings("-DNAME=\"value\"", args[2]);
}
