archive: ?[]const u8 = null,
path: []const u8,
data: []const u8,
index: File.Index,

header: ?elf.Elf64_Ehdr = null,
symtab: []align(1) const elf.Elf64_Sym = &[0]elf.Elf64_Sym{},
strtab: []const u8 = &[0]u8{},
shstrtab: []const u8 = &[0]u8{},
first_global: ?u32 = null,

symbols: std.ArrayListUnmanaged(u32) = .{},
atoms: std.ArrayListUnmanaged(Atom.Index) = .{},
comdat_groups: std.ArrayListUnmanaged(Elf.ComdatGroup.Index) = .{},

needs_exec_stack: bool = false,
alive: bool = true,

output_symtab_size: Elf.SymtabSize = .{},

pub fn isValidHeader(header: *const elf.Elf64_Ehdr) bool {
    if (!mem.eql(u8, header.e_ident[0..4], "\x7fELF")) {
        log.debug("invalid ELF magic '{s}', expected \x7fELF", .{header.e_ident[0..4]});
        return false;
    }
    if (header.e_ident[elf.EI_VERSION] != 1) {
        log.debug("unknown ELF version '{d}', expected 1", .{header.e_ident[elf.EI_VERSION]});
        return false;
    }
    if (header.e_type != elf.ET.REL) {
        log.debug("invalid file type '{s}', expected ET.REL", .{@tagName(header.e_type)});
        return false;
    }
    if (header.e_version != 1) {
        log.debug("invalid ELF version '{d}', expected 1", .{header.e_version});
        return false;
    }
    return true;
}

pub fn deinit(self: *Object, allocator: Allocator) void {
    self.symbols.deinit(allocator);
    self.atoms.deinit(allocator);
    self.comdat_groups.deinit(allocator);
}

pub fn parse(self: *Object, elf_file: *Elf) !void {
    var stream = std.io.fixedBufferStream(self.data);
    const reader = stream.reader();

    self.header = try reader.readStruct(elf.Elf64_Ehdr);

    if (self.header.?.e_shnum == 0) return;

    const shdrs = self.getShdrs();
    self.shstrtab = self.getShdrContents(self.header.?.e_shstrndx);

    const symtab_index = for (self.getShdrs(), 0..) |shdr, i| switch (shdr.sh_type) {
        elf.SHT_SYMTAB => break @intCast(u16, i),
        else => {},
    } else null;

    if (symtab_index) |index| {
        const shdr = shdrs[index];
        self.first_global = shdr.sh_info;

        const symtab = self.getShdrContents(index);
        const nsyms = @divExact(symtab.len, @sizeOf(elf.Elf64_Sym));
        self.symtab = @ptrCast([*]align(1) const elf.Elf64_Sym, symtab.ptr)[0..nsyms];
        self.strtab = self.getShdrContents(@intCast(u16, shdr.sh_link));
    }

    try self.initAtoms(elf_file);
    try self.initSymtab(elf_file);
}

fn initAtoms(self: *Object, elf_file: *Elf) !void {
    const shdrs = self.getShdrs();
    try self.atoms.resize(elf_file.base.allocator, shdrs.len);
    @memset(self.atoms.items, 0);

    for (shdrs, 0..) |shdr, i| {
        if (shdr.sh_flags & elf.SHF_EXCLUDE != 0 and
            shdr.sh_flags & elf.SHF_ALLOC == 0 and
            shdr.sh_type != elf.SHT_LLVM_ADDRSIG) continue;

        switch (shdr.sh_type) {
            elf.SHT_GROUP => {
                if (shdr.sh_info >= self.symtab.len) {
                    elf_file.base.fatal("{}: invalid symbol index in sh_info", .{self.fmtPath()});
                    continue;
                }
                const group_info_sym = self.symtab[shdr.sh_info];
                const group_signature = blk: {
                    if (group_info_sym.st_name == 0 and group_info_sym.st_type() == elf.STT_SECTION) {
                        const sym_shdr = shdrs[group_info_sym.st_shndx];
                        break :blk self.getShString(sym_shdr.sh_name);
                    }
                    break :blk self.getString(group_info_sym.st_name);
                };

                const shndx = @intCast(u16, i);
                const group_raw_data = self.getShdrContents(shndx);
                const group_nmembers = @divExact(group_raw_data.len, @sizeOf(u32));
                const group_members = @ptrCast([*]align(1) const u32, group_raw_data.ptr)[0..group_nmembers];

                if (group_members[0] != 0x1) { // GRP_COMDAT
                    elf_file.base.fatal("{}: unknown SHT_GROUP format", .{self.fmtPath()});
                    continue;
                }

                const group_signature_off = try elf_file.internString("{s}", .{group_signature});
                const gop = try elf_file.getOrCreateComdatGroupOwner(group_signature_off);
                const comdat_group_index = try elf_file.addComdatGroup();
                const comdat_group = elf_file.getComdatGroup(comdat_group_index);
                comdat_group.* = .{
                    .owner = gop.index,
                    .shndx = shndx,
                };
                try self.comdat_groups.append(elf_file.base.allocator, comdat_group_index);
            },

            elf.SHT_SYMTAB_SHNDX => @panic("TODO"),

            elf.SHT_NULL,
            elf.SHT_REL,
            elf.SHT_RELA,
            elf.SHT_SYMTAB,
            elf.SHT_STRTAB,
            => {},

            else => {
                const name = self.getShString(shdr.sh_name);
                const shndx = @intCast(u16, i);

                if (mem.eql(u8, ".note.GNU-stack", name)) {
                    if (shdr.sh_flags & elf.SHF_EXECINSTR != 0) {
                        if (!elf_file.options.z_execstack or !elf_file.options.z_execstack_if_needed) {
                            elf_file.base.warn(
                                "{}: may cause segmentation fault as this file requested executable stack",
                                .{self.fmtPath()},
                            );
                        }
                        self.needs_exec_stack = true;
                    }
                    continue;
                }
                if (self.skipShdr(shndx, elf_file)) continue;
                try self.addAtom(shdr, shndx, name, elf_file);
            },
        }
    }

    // Parse relocs sections if any.
    for (shdrs, 0..) |shdr, i| switch (shdr.sh_type) {
        elf.SHT_REL, elf.SHT_RELA => {
            const atom_index = self.atoms.items[shdr.sh_info];
            if (elf_file.getAtom(atom_index)) |atom| {
                atom.relocs_shndx = @intCast(u16, i);
            }
        },
        else => {},
    };
}

fn addAtom(self: *Object, shdr: elf.Elf64_Shdr, shndx: u16, name: [:0]const u8, elf_file: *Elf) !void {
    const atom_index = try elf_file.addAtom();
    const atom = elf_file.getAtom(atom_index).?;
    atom.atom_index = atom_index;
    atom.name = try elf_file.string_intern.insert(elf_file.base.allocator, name);
    atom.file = self.index;
    atom.shndx = shndx;
    self.atoms.items[shndx] = atom_index;

    if (shdr.sh_flags & elf.SHF_COMPRESSED != 0) {
        const data = self.getShdrContents(shndx);
        const chdr = @ptrCast(*align(1) const elf.Elf64_Chdr, data.ptr).*;
        atom.size = @intCast(u32, chdr.ch_size);
        atom.alignment = math.log2_int(u64, chdr.ch_addralign);
    } else {
        atom.size = @intCast(u32, shdr.sh_size);
        atom.alignment = math.log2_int(u64, shdr.sh_addralign);
    }
}

fn skipShdr(self: *Object, index: u32, elf_file: *Elf) bool {
    const shdr = self.getShdrs()[index];
    const name = self.getShString(shdr.sh_name);
    const ignore = blk: {
        if (shdr.sh_type == elf.SHT_X86_64_UNWIND) break :blk true;
        if (mem.startsWith(u8, name, ".note")) break :blk true;
        if (mem.startsWith(u8, name, ".comment")) break :blk true;
        if (mem.startsWith(u8, name, ".llvm_addrsig")) break :blk true;
        if ((elf_file.options.strip_debug or elf_file.options.strip_all) and
            shdr.sh_flags & elf.SHF_ALLOC == 0 and
            mem.startsWith(u8, name, ".debug")) break :blk true;
        break :blk false;
    };
    return ignore;
}

fn initSymtab(self: *Object, elf_file: *Elf) !void {
    const gpa = elf_file.base.allocator;
    const first_global = self.first_global orelse self.symtab.len;
    const shdrs = self.getShdrs();

    try self.symbols.ensureTotalCapacityPrecise(gpa, self.symtab.len);

    for (self.symtab[0..first_global], 0..) |sym, i| {
        const index = try elf_file.addSymbol();
        self.symbols.appendAssumeCapacity(index);
        const symbol = elf_file.getSymbol(index);
        const name = blk: {
            if (sym.st_name == 0 and sym.st_type() == elf.STT_SECTION) {
                const shdr = shdrs[sym.st_shndx];
                break :blk self.getShString(shdr.sh_name);
            }
            break :blk self.getString(sym.st_name);
        };
        symbol.* = .{
            .value = sym.st_value,
            .name = try elf_file.string_intern.insert(gpa, name),
            .sym_idx = @intCast(u32, i),
            .atom = if (sym.st_shndx == elf.SHN_ABS) 0 else self.atoms.items[sym.st_shndx],
            .file = self.index,
        };
    }

    for (self.symtab[first_global..]) |sym| {
        const name = self.getString(sym.st_name);
        const off = try elf_file.internString("{s}", .{name});
        const gop = try elf_file.getOrCreateGlobal(off);
        self.symbols.addOneAssumeCapacity().* = gop.index;
    }
}

pub fn resolveSymbols(self: *Object, elf_file: *Elf) void {
    const first_global = self.first_global orelse return;
    for (self.getGlobals(), 0..) |index, i| {
        const sym_idx = @intCast(u32, first_global + i);
        const this_sym = self.symtab[sym_idx];

        if (this_sym.st_shndx == elf.SHN_UNDEF) continue;

        if (this_sym.st_shndx != elf.SHN_ABS and this_sym.st_shndx != elf.SHN_COMMON) {
            const atom_index = self.atoms.items[this_sym.st_shndx];
            const atom = elf_file.getAtom(atom_index) orelse continue;
            if (!atom.is_alive) continue;
        }

        const global = elf_file.getSymbol(index);
        if (self.asFile().getSymbolRank(this_sym, !self.alive) < global.getSymbolRank(elf_file)) {
            const atom = switch (this_sym.st_shndx) {
                elf.SHN_ABS, elf.SHN_COMMON => 0,
                else => self.atoms.items[this_sym.st_shndx],
            };
            global.* = .{
                .value = this_sym.st_value,
                .name = global.name,
                .atom = atom,
                .sym_idx = sym_idx,
                .file = self.index,
                .ver_idx = elf_file.default_sym_version,
            };
            if (this_sym.st_bind() == elf.STB_WEAK) global.flags.weak = true;
        }
    }
}

pub fn resetGlobals(self: *Object, elf_file: *Elf) void {
    for (self.getGlobals()) |index| {
        const global = elf_file.getSymbol(index);
        const name = global.name;
        global.* = .{};
        global.name = name;
    }
}

pub fn markLive(self: *Object, elf_file: *Elf) void {
    const first_global = self.first_global orelse return;
    for (self.getGlobals(), 0..) |index, i| {
        const sym_idx = first_global + i;
        const sym = self.symtab[sym_idx];
        if (sym.st_bind() == elf.STB_WEAK) continue;

        const global = elf_file.getSymbol(index);
        const file = global.getFile(elf_file) orelse continue;
        if (sym.st_shndx == elf.SHN_UNDEF and !file.isAlive()) {
            file.setAlive();
            file.markLive(elf_file);
        }
    }
}

pub fn checkDuplicates(self: *Object, elf_file: *Elf) void {
    const first_global = self.first_global orelse return;
    for (self.getGlobals(), 0..) |index, i| {
        const sym_idx = @intCast(u32, first_global + i);
        const this_sym = self.symtab[sym_idx];
        const global = elf_file.getSymbol(index);
        const global_file = global.getFile(elf_file) orelse continue;

        if (self.index == global_file.getIndex() or
            this_sym.st_shndx == elf.SHN_UNDEF or
            this_sym.st_bind() == elf.STB_WEAK) continue;

        if (this_sym.st_shndx != elf.SHN_ABS) {
            const atom_index = self.atoms.items[this_sym.st_shndx];
            const atom = elf_file.getAtom(atom_index) orelse continue;
            if (!atom.is_alive) continue;
        }

        elf_file.base.fatal("multiple definition: {}: {}: {s}", .{
            self.fmtPath(),
            global_file.fmtPath(),
            global.getName(elf_file),
        });
    }
}

pub fn calcSymtabSize(self: *Object, elf_file: *Elf) !void {
    if (elf_file.options.strip_all) return;

    for (self.getLocals()) |local_index| {
        const local = elf_file.getSymbol(local_index);
        if (local.getAtom(elf_file)) |atom| if (!atom.is_alive) continue;
        const s_sym = local.getSourceSymbol(elf_file);
        switch (s_sym.st_type()) {
            elf.STT_SECTION, elf.STT_NOTYPE => continue,
            else => {},
        }
        local.flags.output_symtab = true;
        self.output_symtab_size.nlocals += 1;
        self.output_symtab_size.strsize += @intCast(u32, local.getName(elf_file).len + 1);
    }

    for (self.getGlobals()) |global_index| {
        const global = elf_file.getSymbol(global_index);
        if (global.getFile(elf_file)) |file| if (file.getIndex() != self.index) continue;
        if (global.getAtom(elf_file)) |atom| if (!atom.is_alive) continue;
        global.flags.output_symtab = true;
        if (global.isLocal()) {
            self.output_symtab_size.nlocals += 1;
        } else {
            self.output_symtab_size.nglobals += 1;
        }
        self.output_symtab_size.strsize += @intCast(u32, global.getName(elf_file).len + 1);
    }
}

pub fn writeSymtab(self: *Object, elf_file: *Elf, ctx: Elf.WriteSymtabCtx) !void {
    if (elf_file.options.strip_all) return;

    const gpa = elf_file.base.allocator;

    var ilocal = ctx.ilocal;
    for (self.getLocals()) |local_index| {
        const local = elf_file.getSymbol(local_index);
        if (!local.flags.output_symtab) continue;
        const st_name = try ctx.strtab.insert(gpa, local.getName(elf_file));
        ctx.symtab[ilocal] = local.asElfSym(st_name, elf_file);
        ilocal += 1;
    }

    var iglobal = ctx.iglobal;
    for (self.getGlobals()) |global_index| {
        const global = elf_file.getSymbol(global_index);
        if (global.getFile(elf_file)) |file| if (file.getIndex() != self.index) continue;
        if (!global.flags.output_symtab) continue;
        const st_name = try ctx.strtab.insert(gpa, global.getName(elf_file));
        if (global.isLocal()) {
            ctx.symtab[ilocal] = global.asElfSym(st_name, elf_file);
            ilocal += 1;
        } else {
            ctx.symtab[iglobal] = global.asElfSym(st_name, elf_file);
            iglobal += 1;
        }
    }
}

pub fn getLocals(self: *Object) []const u32 {
    const end = self.first_global orelse self.symbols.items.len;
    return self.symbols.items[0..end];
}

pub fn getGlobals(self: *Object) []const u32 {
    const start = self.first_global orelse self.symbols.items.len;
    return self.symbols.items[start..];
}

pub inline fn getSymbol(self: *Object, index: u32, elf_file: *Elf) *Symbol {
    return elf_file.getSymbol(self.symbols.items[index]);
}

pub inline fn getShdrs(self: *Object) []align(1) const elf.Elf64_Shdr {
    const header = self.header orelse return &[0]elf.Elf64_Shdr{};
    return @ptrCast([*]align(1) const elf.Elf64_Shdr, self.data.ptr + header.e_shoff)[0..header.e_shnum];
}

pub inline fn getShdrContents(self: *Object, index: u16) []const u8 {
    const shdr = self.getShdrs()[index];
    return self.data[shdr.sh_offset..][0..shdr.sh_size];
}

inline fn getString(self: *Object, off: u32) [:0]const u8 {
    assert(off < self.strtab.len);
    return mem.sliceTo(@ptrCast([*:0]const u8, self.strtab.ptr + off), 0);
}

inline fn getShString(self: *Object, off: u32) [:0]const u8 {
    assert(off < self.shstrtab.len);
    return mem.sliceTo(@ptrCast([*:0]const u8, self.shstrtab.ptr + off), 0);
}

pub fn getComdatGroupMembers(self: *Object, index: u16) []align(1) const u32 {
    const raw = self.getShdrContents(index);
    const nmembers = @divExact(raw.len, @sizeOf(u32));
    const members = @ptrCast([*]align(1) const u32, raw.ptr)[1..nmembers];
    return members;
}

pub fn asFile(self: *Object) File {
    return .{ .object = self };
}

pub fn format(
    self: *Object,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = self;
    _ = unused_fmt_string;
    _ = options;
    _ = writer;
    @compileError("do not format objects directly");
}

pub fn fmtSymtab(self: *Object, elf_file: *Elf) std.fmt.Formatter(formatSymtab) {
    return .{ .data = .{
        .object = self,
        .elf_file = elf_file,
    } };
}

const FormatContext = struct {
    object: *Object,
    elf_file: *Elf,
};

fn formatSymtab(
    ctx: FormatContext,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = unused_fmt_string;
    _ = options;
    const object = ctx.object;
    try writer.writeAll("  locals\n");
    for (object.getLocals()) |index| {
        const local = ctx.elf_file.getSymbol(index);
        try writer.print("    {}\n", .{local.fmt(ctx.elf_file)});
    }
    try writer.writeAll("  globals\n");
    for (object.getGlobals()) |index| {
        const global = ctx.elf_file.getSymbol(index);
        try writer.print("    {}\n", .{global.fmt(ctx.elf_file)});
    }
}

pub fn fmtAtoms(self: *Object, elf_file: *Elf) std.fmt.Formatter(formatAtoms) {
    return .{ .data = .{
        .object = self,
        .elf_file = elf_file,
    } };
}

fn formatAtoms(
    ctx: FormatContext,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = unused_fmt_string;
    _ = options;
    const object = ctx.object;
    try writer.writeAll("  atoms\n");
    for (object.atoms.items) |atom_index| {
        const atom = ctx.elf_file.getAtom(atom_index) orelse continue;
        try writer.print("    {}\n", .{atom.fmt(ctx.elf_file)});
    }
}

pub fn fmtComdatGroups(self: *Object, elf_file: *Elf) std.fmt.Formatter(formatComdatGroups) {
    return .{ .data = .{
        .object = self,
        .elf_file = elf_file,
    } };
}

fn formatComdatGroups(
    ctx: FormatContext,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = unused_fmt_string;
    _ = options;
    const object = ctx.object;
    const elf_file = ctx.elf_file;
    try writer.writeAll("  comdat groups\n");
    for (object.comdat_groups.items) |cg_index| {
        const cg = elf_file.getComdatGroup(cg_index);
        const cg_owner = elf_file.getComdatGroupOwner(cg.owner);
        if (cg_owner.file != object.index) continue;
        for (object.getComdatGroupMembers(cg.shndx)) |shndx| {
            const atom_index = object.atoms.items[shndx];
            const atom = elf_file.getAtom(atom_index) orelse continue;
            try writer.print("    atom({d}) : {s}\n", .{ atom_index, atom.getName(elf_file) });
        }
    }
}

pub fn fmtPath(self: *Object) std.fmt.Formatter(formatPath) {
    return .{ .data = self };
}

fn formatPath(
    object: *Object,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = unused_fmt_string;
    _ = options;
    if (object.archive) |path| {
        try writer.writeAll(path);
        try writer.writeByte('(');
        try writer.writeAll(object.path);
        try writer.writeByte(')');
    } else try writer.writeAll(object.path);
}

const Object = @This();

const std = @import("std");
const assert = std.debug.assert;
const elf = std.elf;
const fs = std.fs;
const log = std.log.scoped(.elf);
const math = std.math;
const mem = std.mem;

const Allocator = mem.Allocator;
const Atom = @import("Atom.zig");
const Elf = @import("../Elf.zig");
const File = @import("file.zig").File;
const Symbol = @import("Symbol.zig");
