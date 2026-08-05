const std = @import("std");
const config_mod = @import("config.zig");
const compilation_db = @import("compilation_db.zig");
const scanner = @import("scanner.zig");
const fixer = @import("fixer.zig");
const idents = @import("idents.zig");

const OutputFormat = enum { text, json };

const Options = struct {
    database_path: []const u8 = "build",
    config_path: ?[]const u8 = null,
    project_root: []const u8 = ".",
    format: OutputFormat = .text,
    show_unmapped: bool = true,
    fix: bool = false,
};

const FixStatus = enum {
    not_requested,
    no_changes,
    applied,
    blocked,
    rolled_back,
    rollback_failed,
    failed,
    baseline_errors,
    no_selected,
};

const FixOutcome = struct {
    status: FixStatus = .not_requested,
    files: usize = 0,
    replacements: usize = 0,
    blocked_symbols: usize = 0,
};

const ProgressDisplay = struct {
    interactive: bool,
    rendered: bool = false,

    fn init(io: std.Io) ProgressDisplay {
        return .{ .interactive = std.Io.File.stderr().isTty(io) catch false };
    }

    fn update(self: *ProgressDisplay, io: std.Io, stats: scanner.ProgressStats) !void {
        if (!self.interactive) return;
        try self.render(io, stats, self.rendered);
        self.rendered = true;
    }

    fn finish(self: *ProgressDisplay, io: std.Io, stats: scanner.ProgressStats) !void {
        if (self.interactive and self.rendered) return;
        try self.render(io, stats, false);
        self.rendered = true;
    }

    fn render(_: *ProgressDisplay, io: std.Io, stats: scanner.ProgressStats, redraw: bool) !void {
        var buffer: [256]u8 = undefined;
        var file_writer: std.Io.File.Writer = .init(.stderr(), io, &buffer);
        const out = &file_writer.interface;

        if (redraw) try out.writeAll("\x1b[3A");
        const clear = if (redraw) "\r\x1b[2K" else "";
        try out.print("{s}Warnings: {d}\n{s}Errors: {d}\n{s}Names: {d}\n", .{
            clear,
            stats.warnings,
            clear,
            stats.errors,
            clear,
            stats.names,
        });
        try out.flush();
    }
};

const ScanUi = struct {
    idents_writer: ?*idents.StreamingWriter,
    progress_display: *ProgressDisplay,
};

fn updateScanUi(
    context: *anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    diagnostics: []const scanner.Diagnostic,
    stats: scanner.ProgressStats,
) !void {
    const ui: *ScanUi = @ptrCast(@alignCast(context));
    if (ui.idents_writer) |writer| try writer.append(io, allocator, diagnostics);
    try ui.progress_display.update(io, stats);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    const options = parseArgs(args) catch |err| {
        if (err == error.HelpRequested) {
            try out.writeAll(usage);
            try out.flush();
            return;
        }
        std.log.err("invalid command line; run 'cpp-ident-renamer --help' for usage", .{});
        return err;
    };

    const exit_code = try run(init.io, allocator, out, options);
    try out.flush();
    if (exit_code != 0) std.process.exit(exit_code);
}

fn run(io: std.Io, allocator: std.mem.Allocator, out: *std.Io.Writer, options: Options) !u8 {
    var config = try config_mod.load(io, allocator, options.config_path);
    defer config.deinit(allocator);

    var database = try compilation_db.load(io, allocator, options.database_path);
    defer database.deinit();

    var idents_writer: ?idents.StreamingWriter = if (options.fix)
        null
    else
        try idents.StreamingWriter.init(io, options.project_root);
    defer if (idents_writer) |*writer| writer.deinit(io);

    var progress_display = ProgressDisplay.init(io);
    const initial_stats = scanner.ProgressStats{
        .completed = 0,
        .total = database.entries.len,
        .warnings = 0,
        .errors = 0,
        .names = 0,
    };
    try progress_display.update(io, initial_stats);

    var scan_ui = ScanUi{
        .idents_writer = if (idents_writer) |*writer| writer else null,
        .progress_display = &progress_display,
    };
    const progress = scanner.ScanProgress{
        .context = &scan_ui,
        .translation_unit_finished = updateScanUi,
    };

    var result = try scanner.scan(io, allocator, &database, &config, options.project_root, progress);
    defer result.deinit(allocator);
    try progress_display.finish(io, .{
        .completed = database.entries.len,
        .total = database.entries.len,
        .warnings = result.clang_warnings,
        .errors = result.clang_errors,
        .names = result.violationCount(),
    });

    var selection = if (options.fix)
        try idents.load(io, allocator, options.project_root)
    else
        null;
    defer if (selection) |*value| value.deinit(allocator);

    const fix_outcome = if (selection) |*approved|
        performFix(io, allocator, &database, &config, options.project_root, &result, approved) catch |err| outcome: {
            std.log.err("fix failed safely: {t}", .{err});
            break :outcome FixOutcome{ .status = .failed };
        }
    else
        FixOutcome{};

    switch (options.format) {
        .text => {
            try writeText(out, &result, options.show_unmapped);
            if (options.fix) try writeFixText(out, fix_outcome);
        },
        .json => try writeJson(out, &result, if (options.fix) fix_outcome else null),
    }

    if (options.fix) return switch (fix_outcome.status) {
        .applied, .no_changes => 0,
        .no_selected => if (result.violationCount() > 0) 1 else 0,
        .baseline_errors => 2,
        .blocked, .rolled_back, .failed => 3,
        .rollback_failed => 4,
        .not_requested => unreachable,
    };
    if (result.parse_failures > 0) return 2;
    if (result.violationCount() > 0) return 1;
    return 0;
}

fn performFix(
    io: std.Io,
    allocator: std.mem.Allocator,
    database: *const compilation_db.Database,
    config: *const config_mod.Config,
    project_root: []const u8,
    baseline: *const scanner.ScanResult,
    approved: *const idents.Selection,
) !FixOutcome {
    if (baseline.parse_failures > 0) return .{ .status = .baseline_errors };
    if (baseline.violationCount() == 0) return .{ .status = .no_changes };

    var selected: std.ArrayList(scanner.Diagnostic) = .empty;
    defer selected.deinit(allocator);
    for (baseline.diagnostics.items) |diagnostic| if (approved.contains(diagnostic)) {
        try selected.append(allocator, diagnostic);
    };
    if (selected.items.len == 0) return .{ .status = .no_selected };

    var plan = try scanner.collectReplacements(
        io,
        allocator,
        database,
        project_root,
        selected.items,
    );
    defer plan.deinit(allocator);

    if (plan.blocked.items.len > 0 or plan.replacements.items.len == 0) {
        for (plan.blocked.items) |blocked| std.log.err(
            "refusing to rename '{s}': {s}",
            .{ blocked.old_name, @tagName(blocked.reason) },
        );
        return .{
            .status = .blocked,
            .blocked_symbols = if (plan.blocked.items.len > 0) plan.blocked.items.len else selected.items.len,
        };
    }

    var transaction = try fixer.apply(io, allocator, plan.replacements.items);
    defer transaction.deinit(allocator);

    var verification = scanner.scan(io, allocator, database, config, project_root, null) catch |err| {
        transaction.rollback(io, allocator) catch |rollback_err| {
            std.log.err("verification failed ({t}) and rollback also failed ({t})", .{ err, rollback_err });
            return .{
                .status = .rollback_failed,
                .files = transaction.files.items.len,
                .replacements = transaction.replacement_count,
            };
        };
        std.log.err("verification failed; all edited files were restored: {t}", .{err});
        return .{
            .status = .rolled_back,
            .files = transaction.files.items.len,
            .replacements = transaction.replacement_count,
        };
    };
    defer verification.deinit(allocator);

    const selected_remaining = approved.countSelected(verification.diagnostics.items);
    if (verification.parse_failures > 0 or selected_remaining > 0) {
        transaction.rollback(io, allocator) catch |rollback_err| {
            std.log.err("post-fix verification failed and rollback also failed: {t}", .{rollback_err});
            return .{
                .status = .rollback_failed,
                .files = transaction.files.items.len,
                .replacements = transaction.replacement_count,
            };
        };
        std.log.err(
            "post-fix verification found {d} parse failure(s) and {d} selected violation(s) still present; all edited files were restored",
            .{ verification.parse_failures, selected_remaining },
        );
        return .{
            .status = .rolled_back,
            .files = transaction.files.items.len,
            .replacements = transaction.replacement_count,
        };
    }

    return .{
        .status = .applied,
        .files = transaction.files.items.len,
        .replacements = transaction.replacement_count,
    };
}

fn parseArgs(args: []const []const u8) !Options {
    var options = Options{};
    var i: usize = 1;
    if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
        if (!std.mem.eql(u8, args[i], "check")) return error.InvalidArguments;
        i += 1;
    }

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return error.HelpRequested;
        if (std.mem.eql(u8, arg, "--no-unmapped")) {
            options.show_unmapped = false;
            continue;
        }

        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--fix")) {
            options.fix = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--database")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.database_path = args[i];
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.config_path = args[i];
        } else if (std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.project_root = args[i];
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.format = if (std.mem.eql(u8, args[i], "text")) .text else if (std.mem.eql(u8, args[i], "json")) .json else return error.InvalidArguments;
        } else {
            return error.InvalidArguments;
        }
    }

    return options;
}

fn writeText(out: *std.Io.Writer, result: *const scanner.ScanResult, show_unmapped: bool) !void {
    var unmapped_count: usize = 0;
    for (result.diagnostics.items) |diagnostic| {
        switch (diagnostic.kind) {
            .variable => try out.print(
                "{s}:{d}:{d}: warning: variable '{s}' should be named '{s}' (type: {s}) [cpp-ident-renamer-variable]\n",
                .{ diagnostic.file, diagnostic.line, diagnostic.column, diagnostic.old_name, diagnostic.suggested_name.?, diagnostic.type_spelling.? },
            ),
            .function => try out.print(
                "{s}:{d}:{d}: warning: function '{s}' should be named '{s}' [cpp-ident-renamer-function]\n",
                .{ diagnostic.file, diagnostic.line, diagnostic.column, diagnostic.old_name, diagnostic.suggested_name.? },
            ),
            .unmapped_type => {
                unmapped_count += 1;
                if (show_unmapped) try out.print(
                    "{s}:{d}:{d}: note: no type prefix configured for '{s}' (variable: '{s}') [cpp-ident-renamer-unmapped-type]\n",
                    .{ diagnostic.file, diagnostic.line, diagnostic.column, diagnostic.type_spelling.?, diagnostic.old_name },
                );
            },
        }
    }
    try out.print(
        "checked {d} translation unit(s): {d} naming violation(s), {d} unmapped type(s), {d} Clang warning(s), {d} Clang error(s), {d} parse failure(s)\n",
        .{ result.translation_units, result.violationCount(), unmapped_count, result.clang_warnings, result.clang_errors, result.parse_failures },
    );
}

fn writeFixText(out: *std.Io.Writer, outcome: FixOutcome) !void {
    switch (outcome.status) {
        .no_changes => try out.writeAll("fix: nothing to change\n"),
        .applied => try out.print(
            "fix: applied {d} replacement(s) in {d} file(s); all translation units verified successfully\n",
            .{ outcome.replacements, outcome.files },
        ),
        .blocked => try out.print(
            "fix: refused before writing because {d} symbol(s) could not be renamed safely\n",
            .{outcome.blocked_symbols},
        ),
        .rolled_back => try out.print(
            "fix: verification failed after {d} replacement(s) in {d} file(s); all changes were rolled back\n",
            .{ outcome.replacements, outcome.files },
        ),
        .rollback_failed => try out.writeAll("fix: CRITICAL: verification and rollback both failed; inspect the reported files before continuing\n"),
        .failed => try out.writeAll("fix: failed before a verified transaction completed; inspect diagnostics before retrying\n"),
        .baseline_errors => try out.writeAll("fix: refused because the original translation units contain Clang errors\n"),
        .no_selected => try out.writeAll("fix: no identifiers were selected by idents.tsv; source files were not changed\n"),
        .not_requested => {},
    }
}

fn writeJson(out: *std.Io.Writer, result: *const scanner.ScanResult, fix_outcome: ?FixOutcome) !void {
    const Summary = struct {
        translation_units: usize,
        violations: usize,
        unmapped_types: usize,
        clang_warnings: usize,
        clang_errors: usize,
        parse_failures: usize,
    };
    var unmapped_count: usize = 0;
    for (result.diagnostics.items) |diagnostic| if (diagnostic.kind == .unmapped_type) {
        unmapped_count += 1;
    };
    const report = .{
        .diagnostics = result.diagnostics.items,
        .summary = Summary{
            .translation_units = result.translation_units,
            .violations = result.violationCount(),
            .unmapped_types = unmapped_count,
            .clang_warnings = result.clang_warnings,
            .clang_errors = result.clang_errors,
            .parse_failures = result.parse_failures,
        },
        .fix = fix_outcome,
    };
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, out);
    try out.writeByte('\n');
}

const usage =
    \\cpp-ident-renamer - semantic C++ identifier naming checker and refactoring tool
    \\
    \\Usage:
    \\  cpp-ident-renamer check [options]
    \\  cpp-ident-renamer [options]
    \\
    \\Options:
    \\  -p, --database <path>  compile_commands.json or its directory (default: build)
    \\  -c, --config <path>    TOML configuration (default: cpp-ident-renamer.toml if present)
    \\      --root <path>      only report declarations beneath this directory (default: .)
    \\      --format <format>  text or json (default: text)
    \\      --no-unmapped      hide notes for types without a configured prefix
    \\  -f, --fix              fix only identifiers selected in the existing idents.tsv file
    \\  -h, --help             show this help
    \\
    \\Exit status: 0 clean/fixed, 1 naming violations, 2 parse failures, 3 fix refused/rolled back, 4 rollback failed.
    \\
;

test {
    _ = @import("naming.zig");
    _ = @import("compilation_db.zig");
    _ = @import("idents.zig");
}
