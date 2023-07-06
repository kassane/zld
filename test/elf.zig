pub fn addElfTests(b: *Build, opts: Options) *Step {
    const elf_step = b.step("test-elf", "Run ELF tests");

    if (builtin.target.ofmt == .elf) {
        elf_step.dependOn(testDsoIfunc(b, opts));
    }

    return elf_step;
}

fn testDsoIfunc(b: *Build, opts: Options) *Step {
    const test_step = b.step("test-dso-ifunc", "");

    const dylib = cc(b, "liba.so", opts);
    dylib.addArgs(&.{ "-fPIC", "-shared" });
    dylib.addSourceBytes(
        \\#include<stdio.h>
        \\__attribute__((ifunc("resolve_foobar")))
        \\void foobar(void);
        \\static void real_foobar(void) {
        \\  printf("Hello world\n");
        \\}
        \\typedef void Func();
        \\static Func *resolve_foobar(void) {
        \\  return real_foobar;
        \\}
    , "a.c");

    const exe = cc(b, null, opts);
    exe.addSourceBytes(
        \\void foobar(void);
        \\int main() {
        \\  foobar();
        \\}
    , "main.c");
    exe.addArgs(&.{ "-Wl,-rpath,.", "-la" });
    exe.addArg("-L");
    exe.addDirectorySource(dylib.saveOutputAs("liba.so").dir);

    const run = exe.run();
    run.expectStdOutEqual("Hello world\n");
    test_step.dependOn(&run.step);

    return test_step;
}

const std = @import("std");
const builtin = @import("builtin");
const common = @import("test.zig");
const ar = common.ar;
const cc = common.cc;
const ld = common.ld;

const Build = std.Build;
const Compile = Step.Compile;
const FileSourceWithDir = common.FileSourceWithDir;
const Options = common.Options;
const Step = Build.Step;
const SysCmd = common.SysCmd;
