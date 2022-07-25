const Options = @This();

const std = @import("std");
const builtin = @import("builtin");
const io = std.io;
const mem = std.mem;
const process = std.process;

const Allocator = mem.Allocator;
const CrossTarget = std.zig.CrossTarget;
const MachO = @import("../MachO.zig");
const Zld = @import("../Zld.zig");

pub const SearchStrategy = enum {
    paths_first,
    dylibs_first,
};

const usage =
    \\Usage: ld64.zld [files...]
    \\
    \\Commands:
    \\  <empty> [files...] (default)  Generate final executable artifact 'a.out' from input '.o' files
    \\
    \\General Options:
    \\-current_version [value]        Specifies the current version number of the library
    \\-compatibility_version [value]  Specifies the compatibility version number of the library
    \\-dead_strip                     Remove functions and data that are unreachable by the entry point or exported symbols
    \\-dead_strip_dylibs              Remove dylibs that were unreachable by the entry point or exported symbols
    \\-dylib                          Create dynamic library
    \\-dynamic                        Perform dynamic linking
    \\-e [name]                       Specifies the entry point of main executable
    \\-force_load [path]              Loads all members of the specified static archive library
    \\-framework [name]               Link against framework
    \\-F[path]                        Add search path for frameworks
    \\-headerpad [value]              Set minimum space for future expansion of the load commands in hexadecimal notation
    \\-headerpad_max_install_names    Set enough space as if all paths were MAXPATHLEN
    \\-install_name                   Add dylib's install name
    \\-l[name]                        Link against library
    \\-L[path]                        Add search path for libraries
    \\-needed_framework [name]        Link against framework (even if unused)
    \\-needed-l[name]                 Alias of -needed_library
    \\-needed_library [name]          Link against library (even if unused)
    \\-rpath [path]                   Specify runtime path
    \\-pagezero_size [value]          Size of the __PAGEZERO segment in hexademical notation
    \\-S                              Do not put debug information (STABS or DWARF) in the output file
    \\-search_paths_first             Search each dir in library search paths for `libx.dylib` then `libx.a`
    \\-search_dylibs_first            Search `libx.dylib` in each dir in library search paths, then `libx.a`
    \\-stack_size [value]             Size of the default stack in hexadecimal notation
    \\-syslibroot [path]              Specify the syslibroot
    \\-weak_framework [name]          Link against framework and mark it and all referenced symbols as weak
    \\-weak-l[name]                   Alias of -weak_library
    \\-weak_library [name]            Link against library and mark it and all referenced symbols as weak
    \\--entitlements                  (Linker extension) add path to entitlements file for embedding in code signature
    \\-o [path]                       Specify output path for the final artifact
    \\-h, --help                      Print this help and exit
;

fn printHelpAndExit() noreturn {
    io.getStdOut().writeAll(usage) catch {};
    process.exit(0);
}

fn fatal(arena: Allocator, comptime format: []const u8, args: anytype) noreturn {
    ret: {
        const msg = std.fmt.allocPrint(arena, format, args) catch break :ret;
        io.getStdErr().writeAll(msg) catch {};
    }
    process.exit(1);
}

emit: Zld.Emit,
output_mode: Zld.OutputMode,
target: CrossTarget,
platform_version: std.builtin.Version,
sdk_version: std.builtin.Version,
positionals: []const Zld.LinkObject,
libs: std.StringArrayHashMap(Zld.SystemLib),
frameworks: std.StringArrayHashMap(Zld.SystemLib),
lib_dirs: []const []const u8,
framework_dirs: []const []const u8,
rpath_list: []const []const u8,
dynamic: bool = false,
syslibroot: ?[]const u8 = null,
stack_size: ?u64 = null,
strip: bool = false,
entry: ?[]const u8 = null,
current_version: ?std.builtin.Version = null,
compatibility_version: ?std.builtin.Version = null,
install_name: ?[]const u8 = null,
entitlements: ?[]const u8 = null,
pagezero_size: ?u64 = null,
search_strategy: ?SearchStrategy = null,
headerpad: ?u32 = null,
headerpad_max_install_names: bool = false,
dead_strip: bool = false,
dead_strip_dylibs: bool = false,

pub fn parseArgs(arena: Allocator, args: []const []const u8) !Options {
    if (args.len == 0) {
        printHelpAndExit();
    }

    var positionals = std.ArrayList(Zld.LinkObject).init(arena);
    var libs = std.StringArrayHashMap(Zld.SystemLib).init(arena);
    var lib_dirs = std.ArrayList([]const u8).init(arena);
    var frameworks = std.StringArrayHashMap(Zld.SystemLib).init(arena);
    var framework_dirs = std.ArrayList([]const u8).init(arena);
    var rpath_list = std.ArrayList([]const u8).init(arena);
    var out_path: ?[]const u8 = null;
    var syslibroot: ?[]const u8 = null;
    var stack_size: ?u64 = null;
    var dynamic: bool = false;
    var dylib: bool = false;
    var install_name: ?[]const u8 = null;
    var current_version: ?std.builtin.Version = null;
    var compatibility_version: ?std.builtin.Version = null;
    var headerpad: ?u32 = null;
    var headerpad_max_install_names: bool = false;
    var pagezero_size: ?u64 = null;
    var dead_strip: bool = false;
    var dead_strip_dylibs: bool = false;
    var entry: ?[]const u8 = null;
    var strip: bool = false;

    var platform_version: std.builtin.Version = builtin.target.os.version_range.semver.min;
    var sdk_version: std.builtin.Version = platform_version;

    const Iterator = struct {
        args: []const []const u8,
        i: usize = 0,
        fn next(it: *@This()) ?[]const u8 {
            if (it.i >= it.args.len) {
                return null;
            }
            defer it.i += 1;
            return it.args[it.i];
        }
    };
    var args_iter = Iterator{ .args = args };

    while (args_iter.next()) |arg| {
        if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
            printHelpAndExit();
        } else if (mem.eql(u8, arg, "-syslibroot")) {
            syslibroot = args_iter.next() orelse fatal(arena, "Expected path after {s}", .{arg});
        } else if (mem.startsWith(u8, arg, "-l")) {
            try libs.put(arg[2..], .{});
        } else if (mem.startsWith(u8, arg, "-L")) {
            try lib_dirs.append(arg[2..]);
        } else if (mem.eql(u8, arg, "-framework") or mem.eql(u8, arg, "-weak_framework")) {
            const name = args_iter.next() orelse fatal(arena, "Expected framework name after {s}", .{arg});
            try frameworks.put(name, .{});
        } else if (mem.startsWith(u8, arg, "-F")) {
            try framework_dirs.append(arg[2..]);
        } else if (mem.startsWith(u8, arg, "-needed-l")) {
            try libs.put(arg["-needed-l".len..], .{ .needed = true });
        } else if (mem.eql(u8, arg, "-needed_library")) {
            const name = args_iter.next() orelse fatal(arena, "Expected library name after {s}", .{arg});
            try libs.put(name, .{ .needed = true });
        } else if (mem.eql(u8, arg, "-needed_framework")) {
            const name = args_iter.next() orelse fatal(arena, "Expected framework name after {s}", .{arg});
            try frameworks.put(name, .{ .needed = true });
        } else if (mem.startsWith(u8, arg, "-weak-l")) {
            try libs.put(arg["-weak-l".len..], .{ .weak = true });
        } else if (mem.eql(u8, arg, "-weak_library")) {
            const name = args_iter.next() orelse fatal(arena, "Expected library name after {s}", .{arg});
            try libs.put(name, .{ .weak = true });
        } else if (mem.eql(u8, arg, "-weak_framework")) {
            const name = args_iter.next() orelse fatal(arena, "Expected framework name after {s}", .{arg});
            try frameworks.put(name, .{ .weak = true });
        } else if (mem.eql(u8, arg, "-o")) {
            out_path = args_iter.next() orelse fatal(arena, "Expected output path after {s}", .{arg});
        } else if (mem.eql(u8, arg, "-stack_size")) {
            const stack_s = args_iter.next() orelse
                fatal(arena, "Expected stack size value after {s}", .{arg});
            stack_size = std.fmt.parseUnsigned(u64, eatIntPrefix(stack_s, 16), 16) catch |err| {
                fatal(arena, "Unable to parse '{s}': {s}", .{ arg, @errorName(err) });
            };
        } else if (mem.eql(u8, arg, "-dylib")) {
            dylib = true;
        } else if (mem.eql(u8, arg, "-dynamic")) {
            dynamic = true;
        } else if (mem.eql(u8, arg, "-static")) {
            dynamic = false;
        } else if (mem.eql(u8, arg, "-rpath")) {
            const rpath = args_iter.next() orelse fatal(arena, "Expected path after {s}", .{arg});
            try rpath_list.append(rpath);
        } else if (mem.eql(u8, arg, "-compatibility_version")) {
            const raw = args_iter.next() orelse fatal(arena, "Expected version after {s}", .{arg});
            compatibility_version = std.builtin.Version.parse(raw) catch |err| {
                fatal(arena, "Unable to parse {s} {s}: {s}", .{ arg, raw, @errorName(err) });
            };
        } else if (mem.eql(u8, arg, "-current_version")) {
            const raw = args_iter.next() orelse fatal(arena, "Expected version after {s}", .{arg});
            current_version = std.builtin.Version.parse(raw) catch |err| {
                fatal(arena, "Unable to parse {s} {s}: {s}", .{ arg, raw, @errorName(err) });
            };
        } else if (mem.eql(u8, arg, "-install_name")) {
            install_name = args_iter.next() orelse fatal(arena, "Expected argument after {s}", .{arg});
        } else if (mem.eql(u8, arg, "-headerpad")) {
            const headerpad_s = args_iter.next() orelse
                fatal(arena, "Expected headerpad size value after {s}", .{arg});
            headerpad = std.fmt.parseUnsigned(u32, eatIntPrefix(headerpad_s, 16), 16) catch |err| {
                fatal(arena, "Unable to parse '{s}': {s}", .{ arg, @errorName(err) });
            };
        } else if (mem.eql(u8, arg, "-headerpad_max_install_names")) {
            headerpad_max_install_names = true;
        } else if (mem.eql(u8, arg, "-pagezero_size")) {
            const pagezero_s = args_iter.next() orelse
                fatal(arena, "Expected pagezero size value after {s}", .{arg});
            pagezero_size = std.fmt.parseUnsigned(u64, eatIntPrefix(pagezero_s, 16), 16) catch |err| {
                fatal(arena, "Unable to parse '{s}': {s}", .{ arg, @errorName(err) });
            };
        } else if (mem.eql(u8, arg, "-dead_strip")) {
            dead_strip = true;
        } else if (mem.eql(u8, arg, "-dead_strip_dylibs")) {
            dead_strip_dylibs = true;
        } else if (mem.eql(u8, arg, "-e")) {
            entry = args_iter.next() orelse fatal(arena, "Expected symbol name after {s}", .{arg});
        } else if (mem.eql(u8, arg, "-S")) {
            strip = true;
        } else if (mem.eql(u8, arg, "-force_load")) {
            const path = args_iter.next() orelse fatal(arena, "Expected path after {s}", .{arg});
            try positionals.append(.{
                .path = path,
                .must_link = true,
            });
        } else {
            try positionals.append(.{
                .path = arg,
                .must_link = false,
            });
        }
    }

    if (positionals.items.len == 0) {
        fatal(arena, "Expected at least one input .o file", .{});
    }

    // Add some defaults
    try lib_dirs.append("/usr/lib");
    try framework_dirs.append("/System/Library/Frameworks");

    return Options{
        .emit = .{
            .directory = std.fs.cwd(),
            .sub_path = out_path orelse "a.out",
        },
        .dynamic = dynamic,
        .target = CrossTarget.fromTarget(builtin.target),
        .platform_version = platform_version,
        .sdk_version = sdk_version,
        .output_mode = if (dylib) .lib else .exe,
        .syslibroot = syslibroot,
        .positionals = positionals.items,
        .libs = libs,
        .frameworks = frameworks,
        .lib_dirs = lib_dirs.items,
        .framework_dirs = framework_dirs.items,
        .rpath_list = rpath_list.items,
        .stack_size = stack_size,
        .install_name = install_name,
        .current_version = current_version,
        .compatibility_version = compatibility_version,
        .dead_strip = dead_strip,
        .dead_strip_dylibs = dead_strip_dylibs,
        .headerpad = headerpad,
        .headerpad_max_install_names = headerpad_max_install_names,
        .pagezero_size = pagezero_size,
        .entry = entry,
        .strip = strip,
    };
}

fn eatIntPrefix(arg: []const u8, radix: u8) []const u8 {
    if (arg.len > 2 and arg[0] == '0') {
        switch (std.ascii.toLower(arg[1])) {
            'b' => if (radix == 2) return arg[2..],
            'o' => if (radix == 8) return arg[2..],
            'x' => if (radix == 16) return arg[2..],
            else => {},
        }
    }
    return arg;
}
