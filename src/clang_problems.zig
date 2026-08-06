const std = @import("std");
const scanner = @import("scanner.zig");

pub const file_name = "clang_problems.json";

const JsonProblem = struct {
    severity: scanner.ClangProblemSeverity,
    message: []const u8,
    file: []const u8,
    line: u32,
    column: u32,
    occurrences: usize,
};

const GroupBuilder = struct {
    option: []const u8,
    warning_count: usize = 0,
    error_count: usize = 0,
    problems: std.ArrayList(JsonProblem) = .empty,

    fn deinit(self: *GroupBuilder, allocator: std.mem.Allocator) void {
        self.problems.deinit(allocator);
    }
};

const JsonGroup = struct {
    option: []const u8,
    warning_count: usize,
    error_count: usize,
    unique_problems: usize,
    problems: []const JsonProblem,
};

pub fn write(
    io: std.Io,
    allocator: std.mem.Allocator,
    project_root: []const u8,
    result: *const scanner.ScanResult,
) !void {
    var groups = try buildGroups(allocator, result.clang_problems.items);
    defer {
        for (groups.items) |*group| group.deinit(allocator);
        groups.deinit(allocator);
    }

    std.mem.sort(GroupBuilder, groups.items, {}, lessGroup);
    for (groups.items) |*group| std.mem.sort(JsonProblem, group.problems.items, {}, lessProblem);

    const output_groups = try allocator.alloc(JsonGroup, groups.items.len);
    defer allocator.free(output_groups);
    for (groups.items, output_groups) |group, *output| output.* = .{
        .option = group.option,
        .warning_count = group.warning_count,
        .error_count = group.error_count,
        .unique_problems = group.problems.items.len,
        .problems = group.problems.items,
    };

    const report = .{
        .summary = .{
            .warnings = result.clang_warnings,
            .errors = result.clang_errors,
            .unique_problems = result.clang_problems.items.len,
            .groups = output_groups.len,
        },
        .groups = output_groups,
    };

    const path = try std.fs.path.join(allocator, &.{ project_root, file_name });
    defer allocator.free(path);

    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);

    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(atomic.file, io, &buffer);
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, &file_writer.interface);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();
    try atomic.replace(io);
}

fn buildGroups(
    allocator: std.mem.Allocator,
    problems: []const scanner.ClangProblem,
) !std.ArrayList(GroupBuilder) {
    var groups: std.ArrayList(GroupBuilder) = .empty;
    errdefer {
        for (groups.items) |*group| group.deinit(allocator);
        groups.deinit(allocator);
    }

    for (problems) |problem| {
        var selected: ?*GroupBuilder = null;
        for (groups.items) |*group| {
            if (std.mem.eql(u8, group.option, problem.group)) {
                selected = group;
                break;
            }
        }
        if (selected == null) {
            try groups.append(allocator, .{ .option = problem.group });
            selected = &groups.items[groups.items.len - 1];
        }

        const group = selected.?;
        switch (problem.severity) {
            .warning => {
                group.warning_count += problem.occurrences;
            },
            .@"error", .fatal => {
                group.error_count += problem.occurrences;
            },
        }
        try group.problems.append(allocator, .{
            .severity = problem.severity,
            .message = problem.message,
            .file = problem.file,
            .line = problem.line,
            .column = problem.column,
            .occurrences = problem.occurrences,
        });
    }

    return groups;
}

fn lessGroup(_: void, left: GroupBuilder, right: GroupBuilder) bool {
    return std.mem.order(u8, left.option, right.option) == .lt;
}

fn lessProblem(_: void, left: JsonProblem, right: JsonProblem) bool {
    const file_order = std.mem.order(u8, left.file, right.file);
    if (file_order != .eq) return file_order == .lt;
    if (left.line != right.line) return left.line < right.line;
    if (left.column != right.column) return left.column < right.column;
    return std.mem.order(u8, left.message, right.message) == .lt;
}

test "groups warning occurrences by Clang option" {
    const allocator = std.testing.allocator;
    const problems = [_]scanner.ClangProblem{
        .{
            .group = "-Wsign-conversion",
            .severity = .warning,
            .message = "changes signedness",
            .file = "/project/a.cpp",
            .line = 7,
            .column = 9,
            .occurrences = 3,
        },
        .{
            .group = "unclassified",
            .severity = .@"error",
            .message = "unknown type name",
            .file = "/project/b.cpp",
            .line = 2,
            .column = 1,
        },
    };

    var groups = try buildGroups(allocator, &problems);
    defer {
        for (groups.items) |*group| group.deinit(allocator);
        groups.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), groups.items.len);
    try std.testing.expectEqual(@as(usize, 3), groups.items[0].warning_count);
    try std.testing.expectEqual(@as(usize, 1), groups.items[1].error_count);
}
