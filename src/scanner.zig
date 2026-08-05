const std = @import("std");
const config_mod = @import("config.zig");
const compilation_db = @import("compilation_db.zig");
const naming = @import("naming.zig");
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("clang-c/Index.h");
});

pub const DiagnosticKind = enum { variable, function, unmapped_type };

pub const Diagnostic = struct {
    file: []const u8,
    line: u32,
    column: u32,
    offset: u32,
    kind: DiagnosticKind,
    usr: []const u8,
    old_name: []const u8,
    suggested_name: ?[]const u8,
    type_spelling: ?[]const u8,
};

pub const ScanResult = struct {
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    translation_units: usize = 0,
    parse_failures: usize = 0,
    clang_warnings: usize = 0,
    clang_errors: usize = 0,
    names: usize = 0,

    pub fn deinit(self: *ScanResult, allocator: std.mem.Allocator) void {
        for (self.diagnostics.items) |diagnostic| {
            allocator.free(diagnostic.file);
            allocator.free(diagnostic.usr);
            allocator.free(diagnostic.old_name);
            if (diagnostic.suggested_name) |value| allocator.free(value);
            if (diagnostic.type_spelling) |value| allocator.free(value);
        }
        self.diagnostics.deinit(allocator);
    }

    pub fn violationCount(self: *const ScanResult) usize {
        return self.names;
    }
};

pub const ProgressStats = struct {
    completed: usize,
    total: usize,
    warnings: usize,
    errors: usize,
    names: usize,
};

pub const ScanProgress = struct {
    context: *anyopaque,
    translation_unit_finished: *const fn (
        context: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        diagnostics: []const Diagnostic,
        stats: ProgressStats,
    ) anyerror!void,
};

pub const Replacement = struct {
    file: []const u8,
    offset: u32,
    old_name: []const u8,
    new_name: []const u8,
};

pub const BlockedReason = enum {
    macro_expansion,
    outside_project,
    invalid_location,
    conflicting_replacement,
};

pub const BlockedSymbol = struct {
    old_name: []const u8,
    reason: BlockedReason,
};

pub const ReplacementPlan = struct {
    replacements: std.ArrayList(Replacement) = .empty,
    blocked: std.ArrayList(BlockedSymbol) = .empty,

    pub fn deinit(self: *ReplacementPlan, allocator: std.mem.Allocator) void {
        for (self.replacements.items) |replacement| {
            allocator.free(replacement.file);
            allocator.free(replacement.old_name);
            allocator.free(replacement.new_name);
        }

        self.replacements.deinit(allocator);

        for (self.blocked.items) |blocked| allocator.free(blocked.old_name);
        self.blocked.deinit(allocator);
    }
};

const Context = struct {
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    project_root: []const u8,
    working_directory: []const u8,
    result: *ScanResult,
    seen: *std.StringHashMap(void),
    callback_error: ?anyerror = null,
};

pub fn scan(
    io: std.Io,
    allocator: std.mem.Allocator,
    database: *const compilation_db.Database,
    config: *const config_mod.Config,
    project_root_arg: []const u8,
    progress: ?ScanProgress,
) !ScanResult {
    var result = ScanResult{};
    errdefer result.deinit(allocator);

    const project_root = try std.Io.Dir.cwd().realPathFileAlloc(io, project_root_arg, allocator);
    defer allocator.free(project_root);

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit();
    }

    const index = c.clang_createIndex(0, 0) orelse return error.CannotCreateClangIndex;
    defer c.clang_disposeIndex(index);

    for (database.entries, 0..) |entry, entry_index| {
        const diagnostics_start = result.diagnostics.items.len;
        var tu: c.CXTranslationUnit = null;
        var owned_args: std.ArrayList([:0]u8) = .empty;
        defer {
            for (owned_args.items) |arg| allocator.free(arg);
            owned_args.deinit(allocator);
        }

        try prepareArguments(allocator, entry, &owned_args);

        var arg_ptrs: std.ArrayList([*c]const u8) = .empty;
        defer arg_ptrs.deinit(allocator);
        for (owned_args.items) |arg| try arg_ptrs.append(allocator, arg.ptr);

        const source = try allocator.dupeZ(u8, entry.file);
        defer allocator.free(source);

        const parse_result = c.clang_parseTranslationUnit2FullArgv(
            index,
            source.ptr,
            if (arg_ptrs.items.len == 0) null else arg_ptrs.items.ptr,
            @intCast(arg_ptrs.items.len),
            null,
            0,
            c.CXTranslationUnit_DetailedPreprocessingRecord,
            &tu,
        );
        if (parse_result != c.CXError_Success or tu == null) {
            result.parse_failures += 1;
            result.clang_errors += 1;
            if (progress) |observer| try notifyProgress(
                observer,
                io,
                allocator,
                result.diagnostics.items[diagnostics_start..],
                &result,
                entry_index + 1,
                database.entries.len,
            );
            continue;
        }
        defer c.clang_disposeTranslationUnit(tu);
        result.translation_units += 1;
        const clang_diagnostics = countClangDiagnostics(tu);
        result.clang_warnings += clang_diagnostics.warnings;
        result.clang_errors += clang_diagnostics.errors;
        if (clang_diagnostics.errors > 0) result.parse_failures += 1;

        var context = Context{
            .allocator = allocator,
            .config = config,
            .project_root = project_root,
            .working_directory = entry.directory,
            .result = &result,
            .seen = &seen,
        };

        const root = c.clang_getTranslationUnitCursor(tu);
        _ = c.clang_visitChildren(root, visit, &context);
        if (context.callback_error) |err| return err;
        if (progress) |observer| try notifyProgress(
            observer,
            io,
            allocator,
            result.diagnostics.items[diagnostics_start..],
            &result,
            entry_index + 1,
            database.entries.len,
        );
    }

    std.mem.sort(Diagnostic, result.diagnostics.items, {}, lessThan);
    return result;
}

fn notifyProgress(
    observer: ScanProgress,
    io: std.Io,
    allocator: std.mem.Allocator,
    diagnostics: []const Diagnostic,
    result: *const ScanResult,
    completed: usize,
    total: usize,
) !void {
    try observer.translation_unit_finished(
        observer.context,
        io,
        allocator,
        diagnostics,
        .{
            .completed = completed,
            .total = total,
            .warnings = result.clang_warnings,
            .errors = result.clang_errors,
            .names = result.names,
        },
    );
}

const FixContext = struct {
    allocator: std.mem.Allocator,
    project_root: []const u8,
    working_directory: []const u8,
    candidates: *const std.StringHashMap(usize),
    diagnostics: []const Diagnostic,
    plan: *ReplacementPlan,
    positions: *std.StringHashMap(usize),
    owners: *std.ArrayList(usize),
    blocked: []?BlockedReason,
    occurrence_counts: []usize,
    callback_error: ?anyerror = null,
};

pub fn collectReplacements(
    io: std.Io,
    allocator: std.mem.Allocator,
    database: *const compilation_db.Database,
    project_root_arg: []const u8,
    diagnostics: []const Diagnostic,
) !ReplacementPlan {
    var plan = ReplacementPlan{};
    errdefer plan.deinit(allocator);

    const project_root = try std.Io.Dir.cwd().realPathFileAlloc(io, project_root_arg, allocator);
    defer allocator.free(project_root);

    var candidates = std.StringHashMap(usize).init(allocator);
    defer candidates.deinit();
    for (diagnostics, 0..) |diagnostic, i| {
        if (diagnostic.kind == .unmapped_type or diagnostic.suggested_name == null or diagnostic.usr.len == 0) continue;
        try candidates.put(diagnostic.usr, i);
    }

    const blocked = try allocator.alloc(?BlockedReason, diagnostics.len);
    defer allocator.free(blocked);
    @memset(blocked, null);

    const occurrence_counts = try allocator.alloc(usize, diagnostics.len);
    defer allocator.free(occurrence_counts);
    @memset(occurrence_counts, 0);
    for (diagnostics, 0..) |diagnostic, i| {
        if (diagnostic.kind != .unmapped_type and diagnostic.suggested_name != null and diagnostic.usr.len == 0)
            blocked[i] = .invalid_location;
    }

    var positions = std.StringHashMap(usize).init(allocator);
    defer {
        var keys = positions.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        positions.deinit();
    }
    var owners: std.ArrayList(usize) = .empty;
    defer owners.deinit(allocator);

    const index = c.clang_createIndex(0, 0) orelse return error.CannotCreateClangIndex;
    defer c.clang_disposeIndex(index);

    for (database.entries) |entry| {
        var tu: c.CXTranslationUnit = null;
        var owned_args: std.ArrayList([:0]u8) = .empty;
        defer {
            for (owned_args.items) |arg| allocator.free(arg);
            owned_args.deinit(allocator);
        }

        try prepareArguments(allocator, entry, &owned_args);

        var arg_ptrs: std.ArrayList([*c]const u8) = .empty;
        defer arg_ptrs.deinit(allocator);
        for (owned_args.items) |arg| try arg_ptrs.append(allocator, arg.ptr);

        const source = try allocator.dupeZ(u8, entry.file);
        defer allocator.free(source);

        const parse_result = c.clang_parseTranslationUnit2FullArgv(
            index,
            source.ptr,
            if (arg_ptrs.items.len == 0) null else arg_ptrs.items.ptr,
            @intCast(arg_ptrs.items.len),
            null,
            0,
            c.CXTranslationUnit_DetailedPreprocessingRecord,
            &tu,
        );
        if (parse_result != c.CXError_Success or tu == null) return error.TranslationUnitParseFailed;
        defer c.clang_disposeTranslationUnit(tu);

        var context = FixContext{
            .allocator = allocator,
            .project_root = project_root,
            .working_directory = entry.directory,
            .candidates = &candidates,
            .diagnostics = diagnostics,
            .plan = &plan,
            .positions = &positions,
            .owners = &owners,
            .blocked = blocked,
            .occurrence_counts = occurrence_counts,
        };
        _ = c.clang_visitChildren(c.clang_getTranslationUnitCursor(tu), visitForReplacements, &context);
        if (context.callback_error) |err| return err;
    }

    for (diagnostics, 0..) |diagnostic, i| {
        if (diagnostic.kind != .unmapped_type and diagnostic.suggested_name != null and occurrence_counts[i] == 0 and blocked[i] == null)
            blocked[i] = .invalid_location;
    }
    for (blocked, 0..) |reason, i| if (reason) |value| {
        if (diagnostics[i].kind == .unmapped_type or diagnostics[i].suggested_name == null) continue;
        try plan.blocked.append(allocator, .{
            .old_name = try allocator.dupe(u8, diagnostics[i].old_name),
            .reason = value,
        });
    };
    std.mem.sort(Replacement, plan.replacements.items, {}, replacementLessThan);
    return plan;
}

fn visitForReplacements(cursor: c.CXCursor, parent: c.CXCursor, client_data: c.CXClientData) callconv(.c) c.CXChildVisitResult {
    _ = parent;
    const context: *FixContext = @ptrCast(@alignCast(client_data));
    if (context.callback_error != null) return c.CXChildVisit_Break;
    if (c.clang_Location_isInSystemHeader(c.clang_getCursorLocation(cursor)) != 0)
        return c.CXChildVisit_Continue;
    inspectReplacementCursor(context, cursor) catch |err| {
        context.callback_error = err;
        return c.CXChildVisit_Break;
    };
    return c.CXChildVisit_Recurse;
}

fn inspectReplacementCursor(context: *FixContext, cursor: c.CXCursor) !void {
    const kind = c.clang_getCursorKind(cursor);
    const symbol = if (c.clang_isDeclaration(kind) != 0)
        cursor
    else
        c.clang_getCursorReferenced(cursor);
    if (c.clang_Cursor_isNull(symbol) != 0) return;
    const usr = try cursorString(context.allocator, c.clang_getCursorUSR(symbol));
    defer context.allocator.free(usr);
    const candidate_index = context.candidates.get(usr) orelse return;
    context.occurrence_counts[candidate_index] += 1;
    const diagnostic = context.diagnostics[candidate_index];

    const location_result = try getReplacementLocation(context, c.clang_getCursorLocation(cursor));
    switch (location_result) {
        .macro_expansion => {
            if (context.blocked[candidate_index] == null) context.blocked[candidate_index] = .macro_expansion;
            return;
        },
        .outside_project => {
            if (context.blocked[candidate_index] == null) context.blocked[candidate_index] = .outside_project;
            return;
        },
        .invalid => {
            if (context.blocked[candidate_index] == null) context.blocked[candidate_index] = .invalid_location;
            return;
        },
        .usable => |location| {
            defer context.allocator.free(location.file);
            const key = try std.fmt.allocPrint(context.allocator, "{s}:{d}", .{ location.file, location.offset });
            if (context.positions.get(key)) |replacement_index| {
                context.allocator.free(key);
                const existing = context.plan.replacements.items[replacement_index];
                if (!std.mem.eql(u8, existing.old_name, diagnostic.old_name) or
                    !std.mem.eql(u8, existing.new_name, diagnostic.suggested_name.?))
                {
                    context.blocked[candidate_index] = .conflicting_replacement;
                    context.blocked[context.owners.items[replacement_index]] = .conflicting_replacement;
                }
                return;
            }
            const replacement_index = context.plan.replacements.items.len;
            try context.positions.put(key, replacement_index);
            try context.plan.replacements.append(context.allocator, .{
                .file = try context.allocator.dupe(u8, location.file),
                .offset = location.offset,
                .old_name = try context.allocator.dupe(u8, diagnostic.old_name),
                .new_name = try context.allocator.dupe(u8, diagnostic.suggested_name.?),
            });
            try context.owners.append(context.allocator, candidate_index);
        },
    }
}

const ReplacementLocationResult = union(enum) {
    usable: Location,
    macro_expansion,
    outside_project,
    invalid,
};

fn getReplacementLocation(context: *FixContext, location: c.CXSourceLocation) !ReplacementLocationResult {
    var spelling_file: c.CXFile = null;
    var spelling_line: c_uint = 0;
    var spelling_column: c_uint = 0;
    var spelling_offset: c_uint = 0;
    c.clang_getSpellingLocation(location, &spelling_file, &spelling_line, &spelling_column, &spelling_offset);
    if (spelling_file == null) return .invalid;

    var expansion_file: c.CXFile = null;
    var expansion_offset: c_uint = 0;
    c.clang_getExpansionLocation(location, &expansion_file, null, null, &expansion_offset);
    if (expansion_file != spelling_file or expansion_offset != spelling_offset) return .macro_expansion;

    const raw_path = try cursorString(context.allocator, c.clang_getFileName(spelling_file));
    defer context.allocator.free(raw_path);
    const path = if (std.fs.path.isAbsolute(raw_path))
        try context.allocator.dupe(u8, raw_path)
    else
        try std.fs.path.resolve(context.allocator, &.{ context.working_directory, raw_path });
    if (!isWithin(context.project_root, path)) {
        context.allocator.free(path);
        return .outside_project;
    }
    return .{ .usable = .{
        .file = path,
        .line = spelling_line,
        .column = spelling_column,
        .offset = spelling_offset,
    } };
}

fn replacementLessThan(_: void, a: Replacement, b: Replacement) bool {
    const order = std.mem.order(u8, a.file, b.file);
    if (order == .lt) return true;
    if (order == .gt) return false;
    return a.offset < b.offset;
}

fn visit(cursor: c.CXCursor, parent: c.CXCursor, client_data: c.CXClientData) callconv(.c) c.CXChildVisitResult {
    _ = parent;
    const context: *Context = @ptrCast(@alignCast(client_data));
    if (context.callback_error != null) return c.CXChildVisit_Break;
    if (c.clang_Location_isInSystemHeader(c.clang_getCursorLocation(cursor)) != 0)
        return c.CXChildVisit_Continue;
    inspectCursor(context, cursor) catch |err| {
        context.callback_error = err;
        return c.CXChildVisit_Break;
    };
    return c.CXChildVisit_Recurse;
}

fn inspectCursor(context: *Context, cursor: c.CXCursor) !void {
    const kind = c.clang_getCursorKind(cursor);
    if (kind == c.CXCursor_FieldDecl) {
        try inspectVariable(context, cursor, .member);
    } else if (kind == c.CXCursor_VarDecl) {
        const parent = c.clang_getCursorSemanticParent(cursor);
        const parent_kind = c.clang_getCursorKind(parent);
        if (isRecord(parent_kind)) {
            try inspectVariable(context, cursor, .static_member);
        } else if (parent_kind == c.CXCursor_TranslationUnit or parent_kind == c.CXCursor_Namespace) {
            try inspectVariable(context, cursor, .global);
        }
    } else if (kind == c.CXCursor_CXXMethod) {
        try inspectFunction(context, cursor, context.config.member_function_case);
    } else if (kind == c.CXCursor_FunctionTemplate) {
        const semantic_parent = c.clang_getCursorSemanticParent(cursor);
        const function_case = if (isRecord(c.clang_getCursorKind(semantic_parent)))
            context.config.member_function_case
        else
            context.config.free_function_case;
        try inspectFunction(context, cursor, function_case);
    } else if (kind == c.CXCursor_FunctionDecl) {
        try inspectFunction(context, cursor, context.config.free_function_case);
    }
}

fn inspectVariable(context: *Context, cursor: c.CXCursor, scope: naming.VariableScope) !void {
    const location = getLocation(context, cursor) orelse return;
    defer context.allocator.free(location.file);
    const old_name = try cursorString(context.allocator, c.clang_getCursorSpelling(cursor));
    defer context.allocator.free(old_name);
    if (old_name.len == 0) return;
    const usr = try cursorString(context.allocator, c.clang_getCursorUSR(cursor));
    defer context.allocator.free(usr);
    const raw_type = c.clang_getCursorType(cursor);
    const selected_type = if (context.config.use_canonical_type) c.clang_getCanonicalType(raw_type) else raw_type;
    const type_spelling = try cursorString(context.allocator, c.clang_getTypeSpelling(selected_type));
    defer context.allocator.free(type_spelling);
    const pointer_info = peelPointers(selected_type);
    const base_type_spelling = try cursorString(context.allocator, c.clang_getTypeSpelling(pointer_info.base_type));
    defer context.allocator.free(base_type_spelling);
    const suggested = try naming.variableName(
        context.allocator,
        context.config,
        scope,
        base_type_spelling,
        pointer_info.depth,
        old_name,
    );
    if (suggested) |new_name| {
        if (std.mem.eql(u8, old_name, new_name)) {
            context.allocator.free(new_name);
            return;
        }
        try appendDiagnostic(context, location, usr, .variable, old_name, new_name, type_spelling);
    } else {
        try appendDiagnostic(context, location, usr, .unmapped_type, old_name, null, type_spelling);
    }
}

const PointerInfo = struct {
    base_type: c.CXType,
    depth: usize,
};

fn peelPointers(selected_type: c.CXType) PointerInfo {
    var current = selected_type;
    var depth: usize = 0;
    while (current.kind == c.CXType_Pointer) {
        depth += 1;
        current = c.clang_getPointeeType(current);
    }
    return .{ .base_type = current, .depth = depth };
}

fn inspectFunction(context: *Context, cursor: c.CXCursor, function_case: config_mod.FunctionCase) !void {
    if (function_case == .unchanged) return;
    const location = getLocation(context, cursor) orelse return;
    defer context.allocator.free(location.file);
    const old_name = try cursorString(context.allocator, c.clang_getCursorSpelling(cursor));
    defer context.allocator.free(old_name);
    if (old_name.len == 0 or std.mem.startsWith(u8, old_name, "operator")) return;
    const usr = try cursorString(context.allocator, c.clang_getCursorUSR(cursor));
    defer context.allocator.free(usr);
    const new_name = try naming.functionName(context.allocator, function_case, old_name);
    if (std.mem.eql(u8, old_name, new_name)) {
        context.allocator.free(new_name);
        return;
    }
    try appendDiagnostic(context, location, usr, .function, old_name, new_name, null);
}

const Location = struct { file: []u8, line: u32, column: u32, offset: u32 };

fn getLocation(context: *Context, cursor: c.CXCursor) ?Location {
    const location = c.clang_getCursorLocation(cursor);
    if (c.clang_Location_isInSystemHeader(location) != 0) return null;
    var file: c.CXFile = null;
    var line: c_uint = 0;
    var column: c_uint = 0;
    var offset: c_uint = 0;
    c.clang_getSpellingLocation(location, &file, &line, &column, &offset);
    if (file == null) return null;
    const raw_path = cursorString(context.allocator, c.clang_getFileName(file)) catch |err| {
        context.callback_error = err;
        return null;
    };
    defer context.allocator.free(raw_path);
    const path = if (std.fs.path.isAbsolute(raw_path))
        context.allocator.dupe(u8, raw_path)
    else
        std.fs.path.resolve(context.allocator, &.{ context.working_directory, raw_path });
    const resolved_path = path catch |err| {
        context.callback_error = err;
        return null;
    };
    if (!isWithin(context.project_root, resolved_path)) {
        context.allocator.free(resolved_path);
        return null;
    }
    return .{ .file = resolved_path, .line = line, .column = column, .offset = offset };
}

fn appendDiagnostic(
    context: *Context,
    location: Location,
    usr: []const u8,
    kind: DiagnosticKind,
    old_name: []const u8,
    suggested_name_owned: ?[]u8,
    type_spelling: ?[]const u8,
) !void {
    errdefer if (suggested_name_owned) |value| context.allocator.free(value);
    const key = if (usr.len > 0)
        try std.fmt.allocPrint(context.allocator, "{s}:{s}", .{ usr, @tagName(kind) })
    else
        try std.fmt.allocPrint(context.allocator, "{s}:{d}:{s}", .{ location.file, location.offset, @tagName(kind) });
    if (context.seen.contains(key)) {
        context.allocator.free(key);
        if (suggested_name_owned) |value| context.allocator.free(value);
        return;
    }
    try context.seen.put(key, {});
    try context.result.diagnostics.append(context.allocator, .{
        .file = try context.allocator.dupe(u8, location.file),
        .line = location.line,
        .column = location.column,
        .offset = location.offset,
        .kind = kind,
        .usr = try context.allocator.dupe(u8, usr),
        .old_name = try context.allocator.dupe(u8, old_name),
        .suggested_name = suggested_name_owned,
        .type_spelling = if (type_spelling) |value| try context.allocator.dupe(u8, value) else null,
    });
    if (kind != .unmapped_type) context.result.names += 1;
}

fn cursorString(allocator: std.mem.Allocator, value: c.CXString) ![]u8 {
    defer c.clang_disposeString(value);
    const ptr = c.clang_getCString(value) orelse return allocator.alloc(u8, 0);
    return allocator.dupe(u8, std.mem.span(ptr));
}

fn isRecord(kind: c.CXCursorKind) bool {
    return kind == c.CXCursor_ClassDecl or kind == c.CXCursor_StructDecl or
        kind == c.CXCursor_UnionDecl or kind == c.CXCursor_ClassTemplate;
}

fn isWithin(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or path[root.len] == std.fs.path.sep;
}

fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
    const order = std.mem.order(u8, a.file, b.file);
    if (order == .lt) return true;
    if (order == .gt) return false;
    if (a.line != b.line) return a.line < b.line;
    return a.column < b.column;
}

fn prepareArguments(allocator: std.mem.Allocator, entry: compilation_db.Entry, output: *std.ArrayList([:0]u8)) !void {
    const compiler_index: usize = if (entry.arguments.len > 1 and isCompilerWrapper(entry.arguments[0])) 1 else 0;
    try output.append(allocator, try allocator.dupeZ(u8, entry.arguments[compiler_index]));
    try output.append(allocator, try std.fmt.allocPrintSentinel(allocator, "-working-directory={s}", .{entry.directory}, 0));
    if (build_options.clang_resource_dir.len > 0 and !hasResourceDirArgument(entry.arguments, compiler_index + 1)) {
        try output.append(
            allocator,
            try std.fmt.allocPrintSentinel(allocator, "-resource-dir={s}", .{build_options.clang_resource_dir}, 0),
        );
    }

    var i: usize = compiler_index + 1;
    while (i < entry.arguments.len) : (i += 1) {
        const arg = entry.arguments[i];
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "-MD") or std.mem.eql(u8, arg, "-MMD")) continue;
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "-MF") or
            std.mem.eql(u8, arg, "-MT") or std.mem.eql(u8, arg, "-MQ"))
        {
            i += 1;
            continue;
        }
        if (!std.mem.startsWith(u8, arg, "-")) {
            const resolved = try std.fs.path.resolve(allocator, &.{ entry.directory, arg });
            defer allocator.free(resolved);
            if (std.mem.eql(u8, resolved, entry.file)) continue;
        }
        try output.append(allocator, try allocator.dupeZ(u8, arg));
    }
}

fn hasResourceDirArgument(arguments: []const []const u8, start: usize) bool {
    if (start >= arguments.len) return false;

    for (arguments[start..]) |arg| {
        if (std.mem.eql(u8, arg, "-resource-dir") or std.mem.eql(u8, arg, "--resource-dir") or
            std.mem.startsWith(u8, arg, "-resource-dir=") or std.mem.startsWith(u8, arg, "--resource-dir="))
        {
            return true;
        }
    }

    return false;
}

fn isCompilerWrapper(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    return std.mem.eql(u8, name, "ccache") or std.mem.eql(u8, name, "sccache") or
        std.mem.eql(u8, name, "distcc");
}

const ClangDiagnosticCounts = struct {
    warnings: usize = 0,
    errors: usize = 0,
};

fn countClangDiagnostics(tu: c.CXTranslationUnit) ClangDiagnosticCounts {
    const count = c.clang_getNumDiagnostics(tu);
    var result = ClangDiagnosticCounts{};
    var i: c_uint = 0;
    while (i < count) : (i += 1) {
        const diagnostic = c.clang_getDiagnostic(tu, i) orelse continue;
        defer c.clang_disposeDiagnostic(diagnostic);
        switch (c.clang_getDiagnosticSeverity(diagnostic)) {
            c.CXDiagnostic_Warning => result.warnings += 1,
            c.CXDiagnostic_Error, c.CXDiagnostic_Fatal => result.errors += 1,
            else => {},
        }
    }
    return result;
}

test "detects explicit Clang resource directory arguments" {
    try std.testing.expect(hasResourceDirArgument(&.{ "clang++", "-resource-dir", "/opt/llvm/lib/clang/18" }, 1));
    try std.testing.expect(hasResourceDirArgument(&.{ "clang++", "--resource-dir=/opt/llvm/lib/clang/18" }, 1));
    try std.testing.expect(!hasResourceDirArgument(&.{ "clang++", "-std=c++17" }, 1));
}
