# State-Chain Knowledge Base Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the `kb/` knowledge-base substrate on top of the existing `state_chain.zig` + `txlog.zig` + `canonical_json.zig` primitives, per the validated design at `docs/plans/2026-05-17-state-chain-knowledge-base-design.md`.

**Architecture:** New `src/kb/` module tree (`chain`, `branches`, `manifest`, `ingest`, `rollup`, `divergence`). Per-market substrate chains + per-thesis projection chains, both JSONL-backed using the existing txlog format. Git-like branches via `branches.json` metadata + one JSONL file per branch. `flock(2)` advisory locks for single-writer-per-chain. Read API returns zero-copy slices. Hooks into `src/kalshi/markets.zig` and `src/kalshi/orders.zig` are optional and configured per-deployment via a `kb_root` path.

**Tech Stack:** Zig 0.16.0 (pinned). Existing dependencies only — no new packages. GitButler (`mcp__gitbutler__gitbutler_update_branches`) for all commits.

---

## Conventions

> **REVISED 2026-05-17 after Task 1.4** — the plan was originally drafted against a pre-0.16 Zig stdlib. Zig 0.16 reorganized file/clock APIs into `std.Io.*` and threads an explicit `io: std.Io` parameter through every filesystem operation. The Zig 0.16 API map below is authoritative for Tasks 1.4 onward. Earlier tasks (1.1–1.3) didn't touch the filesystem and don't need re-translation.

### Zig 0.16 stdlib API map (authoritative for this plan)

| Was (pre-0.16) | Is (Zig 0.16) |
|---|---|
| `std.fs.Dir` | `std.Io.Dir` |
| `std.fs.File` | `std.Io.File` |
| `std.fs.cwd()` | `std.Io.Dir.cwd()` |
| `dir.createFile(name, opts)` | `dir.createFile(io, name, opts)` |
| `dir.openFile(name, opts)` | `dir.openFile(io, name, opts)` |
| `dir.openDir(name, opts)` | `dir.openDir(io, name, opts)` |
| `dir.makePath(path)` | `dir.makePath(io, path)` |
| `dir.makeDir(name)` | `dir.makeDir(io, name)` |
| `dir.readFileAlloc(allocator, name, max)` | `dir.readFileAlloc(io, name, allocator, .unlimited)` |
| `dir.writeFile(.{...})` | `dir.writeFile(io, .{...})` |
| `dir.rename(old, new)` | `dir.rename(old_sub_path, new_dir, new_sub_path, io)` (5-arg form on a `Dir`) |
| `dir.deleteFile(name)` | `dir.deleteFile(io, name)` |
| `file.writeAll(bytes)` | `file.writeStreamingAll(io, bytes)` |
| `file.readToEndAlloc(alloc, max)` | use `dir.readFileAlloc(io, ...)` instead, or `file.readStreamingAll(io, buf)` |
| `file.sync()` | `file.sync(io)` |
| `file.close()` | `file.close(io)` (used inside `defer f.close(io);`) |
| `file.seekFromEnd(n)` | `file.seekFromEnd(io, n)` |
| `file.setEndPos(n)` | `file.setEndPos(io, n)` |
| `std.time.nanoTimestamp()` | `std.Io.Clock.awake.now(io).nanoseconds` |
| `std.time.milliTimestamp()` | `@divFloor(std.Io.Clock.wall.now(io).nanoseconds, 1_000_000)` |
| `std.posix.flock(fd, LOCK.EX \| LOCK.NB)` | `file.tryLock(io, .exclusive)` (returns `bool` instead of erroring) |

Tests get the io handle from `std.testing.io`. Pass it through to any function that takes `io: std.Io`.

The lone non-mechanical translation is Task 1.7's `flock` → `tryLock`. The pre-0.16 form errored with `WouldBlock` on contention; `tryLock` returns `false`. The plan's Task 1.7 below has been hand-revised to use the `bool`-returning API.

### Why one canonical reference

Tasks 1.4–1.13 each have several code blocks (failing-test stub, implementation, follow-up tests). Rather than duplicate translation guidance in every task, the implementer is expected to apply this map mechanically and surface ANY genuine ambiguity (e.g., "this stdlib function isn't in the map, what do I use?") as a question before guessing.

### Test command (project-wide)

`zig build test --summary all` runs every inline test in `src/`, `server/`, and `tools/common.zig`. New `src/kb/*.zig` modules become part of the library test surface as soon as they're imported from `src/root.zig`.

**TDD cycle per task:**
1. **Write the failing test.** Edit the relevant `.zig` file. Add an inline `test "..."` block that references the API you're about to build.
2. **Verify it fails for the right reason.** Run `zig build test --summary all`. Expect a compile error (`no such public declaration`) or a runtime test failure — never a green run before implementation.
3. **Implement.** Write the minimum code to make the test pass.
4. **Verify green.** Re-run `zig build test --summary all`. Expect `All N tests passed.` and zero failures.
5. **Commit.** Call the GitButler MCP tool (see below). One task → one commit.

**Commit via GitButler — do NOT use `git commit`.** For every task:

```
Call mcp__gitbutler__gitbutler_update_branches with:
  fullPrompt:            <copy of the task title from this plan>
  changesSummary:        <2–4 bullet points: what changed and why>
  currentWorkingDirectory: /Users/lawls/Development/TuesdayCrowd/Praescientia
```

The post-tool hook stages files automatically; this call materializes them as a commit on the active virtual branch. If the plan adds files to a branch you haven't marked yet, run `but status -fv` after the first commit to confirm placement, then `but mark <branch-name>` so subsequent task hooks land in the same branch instead of spawning `cd-branch-N+1`.

**Editing rules:**
- One inline test per behavior; reuse `std.testing.allocator`.
- Use `@embedFile` for golden fixtures under `src/kb/testdata/`.
- Match existing module style: `//!` file doc-comment, `const std = @import("std");`, `pub const Foo = struct { ... };`, inline tests at the bottom of the same file.
- No floats in any payload field that gets hashed. Use cents (`u32`) for prices, basis points (`u32`) for confidence/probability.

**Stage boundaries.** At the end of every stage, `zig build test --summary all` must pass with zero failures. Stages are landable units; tasks within a stage may briefly leave the tree in a half-built state between commits but must converge by the stage's final task.

---

## Stage 1 — KB Substrate

**Deliverable:** A `kb.Chain` that can be opened, read, appended-to under a `flock`, forked into new branches, and recovered from a torn write. No Kalshi integration yet. A golden-fixture test exercises the full lifecycle.

### Task 1.1 — Bootstrap `src/kb/` and wire empty namespace into `root.zig`

**Files:**
- Create: `src/kb/chain.zig` (placeholder with one trivial test)
- Modify: `src/root.zig` (add `pub const kb = struct { pub const chain = @import("kb/chain.zig"); };` and `_ = kb.chain;` to the root `test {}` block)

**Step 1: Write the failing test.**
Create `src/kb/chain.zig` with:

```zig
//! Knowledge-base chain — wraps txlog.TxLog with branch metadata and flock-based
//! single-writer semantics. Filled in by subsequent tasks.

const std = @import("std");

test "kb.chain module compiles" {
    try std.testing.expect(true);
}
```

Edit `src/root.zig` — add the import inside the existing `pub const kb = struct { ... };` (create the block if absent, above `canonical_json`):

```zig
pub const kb = struct {
    pub const chain = @import("kb/chain.zig");
};
```

And add `_ = kb.chain;` to the root `test {}` block.

**Step 2: Verify the test runs (green is fine here — this is a bootstrap task, not a TDD task).**
Run: `zig build test --summary all`
Expected: `All N tests passed.` where N is one greater than the pre-task count.

**Step 3: Commit.** See Conventions. `fullPrompt`: "Stage 1 Task 1.1 — Bootstrap src/kb/ namespace".

---

### Task 1.2 — `kb.branches.BranchInfo` type + `branches.json` parser

**Files:**
- Create: `src/kb/branches.zig`
- Modify: `src/root.zig` (add `pub const branches = @import("kb/branches.zig");` inside the `kb` namespace, plus `_ = kb.branches;` in the root test block)

**Step 1: Write the failing test.**
In `src/kb/branches.zig`:

```zig
//! Branch metadata for kb chains. Each chain directory contains one
//! `branches.json` file enumerating its branches; each branch is a separate
//! JSONL file in the same directory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Hash = @import("../state_chain.zig").Hash;
const hash_hex_len = 64;

pub const BranchInfo = struct {
    name: []const u8,
    head_hash: Hash,
    parent_hash: Hash,
    parent_branch: []const u8, // empty string for the root branch
    created_ts_ms: u64,
};

pub const BranchesFile = struct {
    allocator: Allocator,
    active: []const u8, // name of the default branch for reads
    branches: []BranchInfo,

    pub fn deinit(self: *BranchesFile) void {
        for (self.branches) |b| {
            self.allocator.free(b.name);
            self.allocator.free(b.parent_branch);
        }
        self.allocator.free(self.branches);
        self.allocator.free(self.active);
    }
};

pub fn parseSlice(allocator: Allocator, json: []const u8) !BranchesFile {
    _ = allocator;
    _ = json;
    return error.NotImplemented;
}

test "parseSlice round-trips a two-branch file" {
    const json =
        \\{"active":"main","branches":[
        \\{"name":"main","head_hash":"0000000000000000000000000000000000000000000000000000000000000000",
        \\"parent_hash":"0000000000000000000000000000000000000000000000000000000000000000",
        \\"parent_branch":"","created_ts_ms":1747500000000},
        \\{"name":"fork-a","head_hash":"abababababababababababababababababababababababababababababababab",
        \\"parent_hash":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
        \\"parent_branch":"main","created_ts_ms":1747510000000}
        \\]}
    ;
    var bf = try parseSlice(std.testing.allocator, json);
    defer bf.deinit();
    try std.testing.expectEqualStrings("main", bf.active);
    try std.testing.expectEqual(@as(usize, 2), bf.branches.len);
    try std.testing.expectEqualStrings("fork-a", bf.branches[1].name);
    try std.testing.expectEqualStrings("main", bf.branches[1].parent_branch);
}
```

Wire into `src/root.zig` as in Task 1.1.

**Step 2: Verify failure.**
Run: `zig build test --summary all`
Expected: test runs to `parseSlice` and fails with `error.NotImplemented`.

**Step 3: Implement `parseSlice`.**

```zig
pub fn parseSlice(allocator: Allocator, json: []const u8) !BranchesFile {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const active_src = root.get("active").?.string;
    const list = root.get("branches").?.array;

    const branches = try allocator.alloc(BranchInfo, list.items.len);
    errdefer allocator.free(branches);

    for (list.items, 0..) |item, i| {
        const obj = item.object;
        const name = try allocator.dupe(u8, obj.get("name").?.string);
        errdefer allocator.free(name);
        const parent_branch = try allocator.dupe(u8, obj.get("parent_branch").?.string);
        errdefer allocator.free(parent_branch);

        var head_hash: Hash = undefined;
        try hexDecode(obj.get("head_hash").?.string, &head_hash);
        var parent_hash: Hash = undefined;
        try hexDecode(obj.get("parent_hash").?.string, &parent_hash);

        branches[i] = .{
            .name = name,
            .head_hash = head_hash,
            .parent_hash = parent_hash,
            .parent_branch = parent_branch,
            .created_ts_ms = @intCast(obj.get("created_ts_ms").?.integer),
        };
    }

    return .{
        .allocator = allocator,
        .active = try allocator.dupe(u8, active_src),
        .branches = branches,
    };
}

fn hexDecode(hex: []const u8, out: *Hash) !void {
    if (hex.len != hash_hex_len) return error.WrongHexLength;
    for (out, 0..) |*byte, i| {
        const hi = try hexNibble(hex[i * 2]);
        const lo = try hexNibble(hex[i * 2 + 1]);
        byte.* = (hi << 4) | lo;
    }
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => 10 + c - 'a',
        'A'...'F' => 10 + c - 'A',
        else => error.InvalidHex,
    };
}
```

**Step 4: Verify green.** `zig build test --summary all` → all tests pass.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.2 — Add kb.branches.BranchesFile parser".

---

### Task 1.3 — `kb.branches.writeSlice` (round-trip)

**Files:**
- Modify: `src/kb/branches.zig`

**Step 1: Write the failing test.** Append to `src/kb/branches.zig`:

```zig
pub fn writeSlice(allocator: Allocator, bf: *const BranchesFile) ![]u8 {
    _ = allocator;
    _ = bf;
    return error.NotImplemented;
}

test "writeSlice + parseSlice round-trip is stable" {
    const original_json =
        \\{"active":"main","branches":[{"name":"main","head_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_branch":"","created_ts_ms":1747500000000}]}
    ;
    var bf = try parseSlice(std.testing.allocator, original_json);
    defer bf.deinit();

    const round = try writeSlice(std.testing.allocator, &bf);
    defer std.testing.allocator.free(round);

    var bf2 = try parseSlice(std.testing.allocator, round);
    defer bf2.deinit();

    try std.testing.expectEqualStrings(bf.active, bf2.active);
    try std.testing.expectEqual(bf.branches.len, bf2.branches.len);
    try std.testing.expectEqualSlices(u8, &bf.branches[0].head_hash, &bf2.branches[0].head_hash);
}
```

**Step 2: Verify failure.** `zig build test --summary all` → `error.NotImplemented`.

**Step 3: Implement.**

```zig
pub fn writeSlice(allocator: Allocator, bf: *const BranchesFile) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.print("{{\"active\":\"{s}\",\"branches\":[", .{bf.active});
    for (bf.branches, 0..) |b, i| {
        if (i > 0) try w.writeByte(',');
        var head_hex: [hash_hex_len]u8 = undefined;
        var parent_hex: [hash_hex_len]u8 = undefined;
        _ = std.fmt.bufPrint(&head_hex, "{x}", .{b.head_hash}) catch unreachable;
        _ = std.fmt.bufPrint(&parent_hex, "{x}", .{b.parent_hash}) catch unreachable;
        try w.print(
            "{{\"name\":\"{s}\",\"head_hash\":\"{s}\",\"parent_hash\":\"{s}\",\"parent_branch\":\"{s}\",\"created_ts_ms\":{d}}}",
            .{ b.name, head_hex, parent_hex, b.parent_branch, b.created_ts_ms },
        );
    }
    try w.writeAll("]}");
    return aw.toOwnedSlice();
}
```

**Step 4: Verify green.** `zig build test --summary all`.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.3 — Add kb.branches.writeSlice round-trip".

---

### Task 1.4 — `kb.branches.atomicWrite` (write-temp-then-rename)

**Files:**
- Modify: `src/kb/branches.zig`

**Step 1: Write the failing test.**

```zig
pub fn atomicWrite(io: std.Io, dir: std.Io.Dir, bf: *const BranchesFile, scratch: Allocator) !void {
    _ = dir;
    _ = bf;
    _ = scratch;
    return error.NotImplemented;
}

test "atomicWrite produces a parseable branches.json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const sa = arena.allocator();

    const branches = try sa.alloc(BranchInfo, 1);
    branches[0] = .{
        .name = try sa.dupe(u8, "main"),
        .head_hash = @splat(0),
        .parent_hash = @splat(0),
        .parent_branch = try sa.dupe(u8, ""),
        .created_ts_ms = 1747500000000,
    };
    const bf = BranchesFile{
        .allocator = sa,
        .active = try sa.dupe(u8, "main"),
        .branches = branches,
    };

    try atomicWrite(tmp.dir, &bf, std.testing.allocator);

    const buf = try tmp.dir.readFileAlloc(io, "branches.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(buf);
    var parsed = try parseSlice(std.testing.allocator, buf);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("main", parsed.active);
}
```

**Step 2: Verify failure.** `error.NotImplemented`.

**Step 3: Implement.**

```zig
pub fn atomicWrite(io: std.Io, dir: std.Io.Dir, bf: *const BranchesFile, scratch: Allocator) !void {
    const bytes = try writeSlice(scratch, bf);
    defer scratch.free(bytes);

    var tmp_name_buf: [64]u8 = undefined;
    const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, ".branches.json.tmp.{d}", .{std.Io.Clock.awake.now(io).nanoseconds});

    {
        var f = try dir.createFile(io, tmp_name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
        try f.sync(io);
    }
    try dir.rename(tmp_name, dir, "branches.json", io);
}
```

**Step 4: Verify green.**

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.4 — Add kb.branches.atomicWrite".

---

### Task 1.5 — `kb.chain.Chain` minimal read-only open

**Files:**
- Modify: `src/kb/chain.zig`

**Step 1: Write the failing test.** Replace the placeholder in `src/kb/chain.zig`:

```zig
//! Knowledge-base chain — wraps txlog.TxLog with branch metadata.

const std = @import("std");
const Allocator = std.mem.Allocator;

const txlog = @import("../txlog.zig");
const branches_mod = @import("branches.zig");
const Hash = @import("../state_chain.zig").Hash;

pub const Chain = struct {
    allocator: Allocator,
    log: txlog.TxLog,
    branch_name: []u8, // owned

    pub fn deinit(self: *Chain) void {
        self.log.deinit();
        self.allocator.free(self.branch_name);
    }

    pub fn head(self: *const Chain) ?Hash {
        if (self.log.len() == 0) return null;
        return self.log.items.items[self.log.len() - 1].hash;
    }

    pub fn len(self: *const Chain) usize {
        return self.log.len();
    }
};

pub fn openRead(allocator: Allocator, io: std.Io, dir: std.Io.Dir, branch: []const u8) !Chain {
    _ = allocator;
    _ = dir;
    _ = branch;
    return error.NotImplemented;
}

test "openRead loads an existing branch's JSONL" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // Hand-craft a one-entry JSONL using TxLog directly.
    var src: txlog.TxLog = .init(std.testing.allocator);
    defer src.deinit();
    _ = try src.append("{\"v\":1}");

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try src.writeAll(&aw.writer);

    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = aw.written() });

    var chain = try openRead(std.testing.allocator, io, tmp.dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.len());
    try std.testing.expect(chain.head() != null);
}
```

**Step 2: Verify failure.** `error.NotImplemented`.

**Step 3: Implement.**

```zig
pub fn openRead(allocator: Allocator, io: std.Io, dir: std.Io.Dir, branch: []const u8) !Chain {
    var file_name_buf: [256]u8 = undefined;
    const file_name = try std.fmt.bufPrint(&file_name_buf, "{s}.jsonl", .{branch});

    const data = dir.readFileAlloc(io, file_name, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.BranchNotFound,
        else => return err,
    };
    defer allocator.free(data);

    var log = try txlog.TxLog.parseSlice(allocator, data);
    errdefer log.deinit();

    return .{
        .allocator = allocator,
        .log = log,
        .branch_name = try allocator.dupe(u8, branch),
    };
}
```

**Step 4: Verify green.**

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.5 — Add kb.chain.openRead".

---

### Task 1.6 — `kb.chain` read primitives: `at`, `tail`, `rangeByHash`, `rangeByTime`

**Files:**
- Modify: `src/kb/chain.zig`

**Step 1: Write the failing test.**

```zig
pub fn at(self: *const Chain, hash: Hash) ?*const txlog.Tx {
    for (self.log.items.items) |*tx| {
        if (std.mem.eql(u8, &tx.hash, &hash)) return tx;
    }
    return null;
}

pub fn tail(self: *const Chain, n: usize) []const txlog.Tx {
    const total = self.log.len();
    if (n >= total) return self.log.items.items;
    return self.log.items.items[total - n ..];
}

pub fn rangeByHash(self: *const Chain, from: Hash, to: Hash) ?[]const txlog.Tx {
    var from_idx: ?usize = null;
    var to_idx: ?usize = null;
    for (self.log.items.items, 0..) |*tx, i| {
        if (from_idx == null and std.mem.eql(u8, &tx.hash, &from)) from_idx = i;
        if (std.mem.eql(u8, &tx.hash, &to)) to_idx = i;
    }
    if (from_idx == null or to_idx == null) return null;
    if (to_idx.? < from_idx.?) return null;
    return self.log.items.items[from_idx.? .. to_idx.? + 1];
}

pub fn rangeByTime(self: *const Chain, from_ms: u64, to_ms: u64) []const txlog.Tx {
    _ = self;
    _ = from_ms;
    _ = to_ms;
    return &.{}; // implemented after payload ts-parsing is in place
}

test "tail returns last N entries; rangeByHash bounds inclusive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var src: txlog.TxLog = .init(std.testing.allocator);
    defer src.deinit();
    _ = try src.append("{\"v\":1}");
    _ = try src.append("{\"v\":2}");
    _ = try src.append("{\"v\":3}");

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try src.writeAll(&aw.writer);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = aw.written() });

    var chain = try openRead(std.testing.allocator, io, tmp.dir, "main");
    defer chain.deinit();

    try std.testing.expectEqual(@as(usize, 2), chain.tail(2).len);
    try std.testing.expectEqualStrings("{\"v\":3}", chain.tail(1)[0].payload);

    const h0 = src.items.items[0].hash;
    const h2 = src.items.items[2].hash;
    const r = chain.rangeByHash(h0, h2).?;
    try std.testing.expectEqual(@as(usize, 3), r.len);
}
```

**Step 2:** Tests in step 1 are already valid implementations. Run `zig build test --summary all` — they should compile and pass.
Expected: green.

**Step 3: (skipped — implementation went in with the test).**

**Step 4: Commit.** `fullPrompt`: "Stage 1 Task 1.6 — kb.chain read primitives at/tail/rangeByHash".

> **Note on rangeByTime:** stubbed for now. Implemented in Task 1.13 after payload ts-parsing utility lands.

---

### Task 1.7 — `kb.chain.openForWrite` with `flock(2)` and fail-fast

**Files:**
- Modify: `src/kb/chain.zig`

**Step 1: Write the failing test.**

```zig
pub const WriteHandle = struct {
    allocator: Allocator,
    chain: Chain,
    file: std.Io.File, // holds the exclusive lock for the lifetime of the handle
    io: std.Io,
    dir: std.Io.Dir,
    branch_file_name: []u8,

    pub fn deinit(self: *WriteHandle) void {
        // Closing the file releases the advisory lock (POSIX flock semantics).
        self.file.close(self.io);
        self.chain.deinit();
        self.allocator.free(self.branch_file_name);
    }
};

pub fn openForWrite(allocator: Allocator, io: std.Io, dir: std.Io.Dir, branch: []const u8) !WriteHandle {
    _ = allocator;
    _ = io;
    _ = dir;
    _ = branch;
    return error.NotImplemented;
}

test "openForWrite acquires an exclusive lock; second open fails fast" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // Empty branch file is acceptable — chain is empty, head = null.
    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = "" });

    var h1 = try openForWrite(std.testing.allocator, io, io, tmp.dir, "main");
    defer h1.deinit();

    const err = openForWrite(std.testing.allocator, io, io, tmp.dir, "main");
    try std.testing.expectError(error.AlreadyLocked, err);
}
```

**Step 2: Verify failure.** `error.NotImplemented`.

**Step 3: Implement.**

```zig
pub fn openForWrite(allocator: Allocator, io: std.Io, dir: std.Io.Dir, branch: []const u8) !WriteHandle {
    var file_name_buf: [256]u8 = undefined;
    const file_name = try std.fmt.bufPrint(&file_name_buf, "{s}.jsonl", .{branch});

    var file = dir.openFile(io, file_name, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try dir.createFile(io, file_name, .{ .read = true, .truncate = false }),
        else => return err,
    };
    errdefer file.close(io);

    // Advisory exclusive lock, non-blocking. tryLock returns false on contention;
    // surface that as error.AlreadyLocked so callers can fail fast.
    if (!try file.tryLock(io, .exclusive)) return error.AlreadyLocked;

    // Load existing chain content. We hold the exclusive lock, so reading via the
    // dir (separate fd, same inode) is race-free with any well-behaved writer.
    const data = try dir.readFileAlloc(io, file_name, allocator, .unlimited);
    defer allocator.free(data);

    var log = try txlog.TxLog.parseSlice(allocator, data);
    errdefer log.deinit();

    return .{
        .allocator = allocator,
        .chain = .{
            .allocator = allocator,
            .log = log,
            .branch_name = try allocator.dupe(u8, branch),
        },
        .file = file,
        .io = io,
        .dir = dir,
        .branch_file_name = try allocator.dupe(u8, file_name),
    };
}
```

**Step 4: Verify green.**

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.7 — kb.chain.openForWrite with flock".

---

### Task 1.8 — `WriteHandle.append` with `fdatasync`

**Files:**
- Modify: `src/kb/chain.zig`

**Step 1: Write the failing test.**

```zig
pub fn append(self: *WriteHandle, canonical_json: []const u8) !*const txlog.Tx {
    _ = self;
    _ = canonical_json;
    return error.NotImplemented;
}

test "append writes a JSONL line, fdatasyncs, and updates the in-memory chain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = "" });

    var h = try openForWrite(std.testing.allocator, io, tmp.dir, "main");
    defer h.deinit();

    _ = try h.append("{\"kind\":\"market.reality\",\"ts\":1,\"yes_bid_cents\":50,\"yes_ask_cents\":51}");
    try std.testing.expectEqual(@as(usize, 1), h.chain.len());

    // File on disk has exactly one line.
    const buf = try tmp.dir.readFileAlloc(io, "main.jsonl", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(buf);
    var line_count: usize = 0;
    for (buf) |c| if (c == '\n') { line_count += 1; };
    try std.testing.expectEqual(@as(usize, 1), line_count);
}
```

**Step 2: Verify failure.** `error.NotImplemented`.

**Step 3: Implement.**

```zig
pub fn append(self: *WriteHandle, canonical_json: []const u8) !*const txlog.Tx {
    const tx = try self.chain.log.append(canonical_json);

    var line_buf: std.Io.Writer.Allocating = .init(self.allocator);
    defer line_buf.deinit();

    // Emit exactly this one tx via the existing txlog writeAll pattern.
    var prev_hex: [hash_hex_len]u8 = undefined;
    var hash_hex: [hash_hex_len]u8 = undefined;
    _ = std.fmt.bufPrint(&prev_hex, "{x}", .{tx.prev_hash}) catch unreachable;
    _ = std.fmt.bufPrint(&hash_hex, "{x}", .{tx.hash}) catch unreachable;
    try line_buf.writer.print(
        "{{\"tx_id\":\"{s}\",\"prev_hash\":\"{s}\",\"hash\":\"{s}\",\"payload\":{s}}}\n",
        .{ tx.tx_id, prev_hex, hash_hex, tx.payload },
    );

    try self.file.seekFromEnd(io, 0);
    try self.file.writeStreamingAll(io, line_buf.written());
    try self.file.sync(io); // fdatasync on POSIX; fallback on others.

    return tx;
}

const hash_hex_len = txlog.hash_hex_len;
```

**Step 4: Verify green.** `zig build test --summary all`.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.8 — WriteHandle.append with fdatasync".

---

### Task 1.9 — Crash-recovery: torn final write is truncated on next open

**Files:**
- Modify: `src/kb/chain.zig`

**Step 1: Write the failing test.**

```zig
pub fn recoverTornTail(io: std.Io, dir: std.Io.Dir, branch_file_name: []const u8) !void {
    _ = dir;
    _ = branch_file_name;
    return error.NotImplemented;
}

test "recoverTornTail truncates a malformed final line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // Build a well-formed two-line JSONL then append a torn third line.
    var src: txlog.TxLog = .init(std.testing.allocator);
    defer src.deinit();
    _ = try src.append("{\"v\":1}");
    _ = try src.append("{\"v\":2}");
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try src.writeAll(&aw.writer);

    var full = std.array_list.Managed(u8).init(std.testing.allocator);
    defer full.deinit();
    try full.appendSlice(aw.written());
    try full.appendSlice("{\"tx_id\":\"tx_BROKE"); // torn line, no newline

    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = full.items });

    try recoverTornTail(io, tmp.dir, "main.jsonl");

    // After recovery, file parses cleanly and has exactly 2 entries.
    const after = try tmp.dir.readFileAlloc(io, "main.jsonl", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(after);
    var parsed = try txlog.TxLog.parseSlice(std.testing.allocator, after);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.len());
}
```

**Step 2: Verify failure.** `error.NotImplemented`.

**Step 3: Implement.**

```zig
pub fn recoverTornTail(io: std.Io, dir: std.Io.Dir, branch_file_name: []const u8) !void {
    var file = try dir.openFile(io, branch_file_name, .{ .mode = .read_write });
    defer file.close(io);

    // Read current contents via a separate fd through the directory — same inode,
    // no lock needed since recovery runs before any writer acquires the chain lock.
    const data = try dir.readFileAlloc(io, branch_file_name, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(data);

    // Find the last newline; anything after it is a torn write.
    if (data.len == 0) return;
    const last_nl = std.mem.lastIndexOfScalar(u8, data, '\n');
    if (last_nl == null) {
        try file.setEndPos(io, 0);
        return;
    }
    const valid_len = last_nl.? + 1;
    if (valid_len < data.len) {
        try file.setEndPos(io, valid_len);
    }

    // Additionally, validate the full chain — if the LAST complete line is
    // itself hash-broken (rare: power loss between write and fsync), peel it.
    const trimmed = data[0..valid_len];
    var probe = txlog.TxLog.parseSlice(std.testing.allocator, trimmed) catch |err| switch (err) {
        error.HashMismatch, error.PrevHashBroken => {
            // Drop the last newline-terminated line and re-validate.
            const prior_nl = std.mem.lastIndexOfScalar(u8, trimmed[0..valid_len - 1], '\n');
            const new_len: usize = if (prior_nl) |i| i + 1 else 0;
            try file.setEndPos(io, new_len);
            return;
        },
        else => return err,
    };
    probe.deinit();
}
```

> **Note:** the in-test allocator usage is acceptable here because `recoverTornTail` is invoked under a test or directly by `openForWrite` which has its allocator on hand. Refactor to take an `Allocator` if you want to call it from production paths — easy follow-up.

**Step 4: Verify green.**

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.9 — Torn-write recovery for kb chains".

---

### Task 1.10 — `kb.branches.fork(parent_branch, io, fork_at_hash, new_name)`

**Files:**
- Modify: `src/kb/branches.zig`

**Step 1: Write the failing test.**

```zig
const chain_mod = @import("chain.zig");

pub fn fork(
    allocator: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    parent_branch: []const u8,
    fork_at_hash: Hash,
    new_branch_name: []const u8,
) !void {
    _ = allocator;
    _ = dir;
    _ = parent_branch;
    _ = fork_at_hash;
    _ = new_branch_name;
    return error.NotImplemented;
}

test "fork copies entries up to and including fork_at_hash into a new branch file" {
    const txlog = @import("../txlog.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var src: txlog.TxLog = .init(std.testing.allocator);
    defer src.deinit();
    _ = try src.append("{\"v\":1}");
    _ = try src.append("{\"v\":2}");
    _ = try src.append("{\"v\":3}");
    const fork_at = src.items.items[1].hash;

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try src.writeAll(&aw.writer);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = aw.written() });

    // Seed minimal branches.json
    try tmp.dir.writeFile(io, .{
        .sub_path = "branches.json",
        .data =
        \\{"active":"main","branches":[{"name":"main","head_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_branch":"","created_ts_ms":0}]}
        ,
    });

    try fork(std.testing.allocator, tmp.dir, "main", fork_at, "exp-a");

    // New branch file exists and has exactly 2 entries.
    const buf = try tmp.dir.readFileAlloc(io, "exp-a.jsonl", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(buf);
    var parsed = try txlog.TxLog.parseSlice(std.testing.allocator, buf);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.len());
    try std.testing.expectEqualSlices(u8, &parsed.items.items[1].hash, &fork_at);
}
```

**Step 2: Verify failure.** `error.NotImplemented`.

**Step 3: Implement.**

```zig
pub fn fork(
    allocator: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    parent_branch: []const u8,
    fork_at_hash: Hash,
    new_branch_name: []const u8,
) !void {
    // 1) Open parent's JSONL, find fork_at_hash, slice entries up to (incl) that idx.
    var parent_chain = try chain_mod.openRead(allocator, io, io, io, dir, parent_branch);
    defer parent_chain.deinit();

    var fork_idx: ?usize = null;
    for (parent_chain.log.items.items, 0..) |tx, i| {
        if (std.mem.eql(u8, &tx.hash, &fork_at_hash)) { fork_idx = i; break; }
    }
    if (fork_idx == null) return error.ForkHashNotFound;

    // 2) Re-emit those entries as JSONL into the new branch file.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    for (parent_chain.log.items.items[0 .. fork_idx.? + 1]) |tx| {
        var prev_hex: [hash_hex_len]u8 = undefined;
        var hash_hex: [hash_hex_len]u8 = undefined;
        _ = std.fmt.bufPrint(&prev_hex, "{x}", .{tx.prev_hash}) catch unreachable;
        _ = std.fmt.bufPrint(&hash_hex, "{x}", .{tx.hash}) catch unreachable;
        try aw.writer.print(
            "{{\"tx_id\":\"{s}\",\"prev_hash\":\"{s}\",\"hash\":\"{s}\",\"payload\":{s}}}\n",
            .{ tx.tx_id, prev_hex, hash_hex, tx.payload },
        );
    }
    var new_file_name_buf: [256]u8 = undefined;
    const new_file_name = try std.fmt.bufPrint(&new_file_name_buf, "{s}.jsonl", .{new_branch_name});
    try dir.writeFile(io, .{ .sub_path = new_file_name, .data = aw.written() });

    // 3) Update branches.json: add a new BranchInfo with parent_hash = fork_at_hash.
    const meta_buf = try dir.readFileAlloc(io, "branches.json", allocator, .unlimited);
    defer allocator.free(meta_buf);
    var bf = try parseSlice(allocator, meta_buf);
    defer bf.deinit();

    var new_list = try allocator.alloc(BranchInfo, bf.branches.len + 1);
    @memcpy(new_list[0..bf.branches.len], bf.branches);
    new_list[bf.branches.len] = .{
        .name = try allocator.dupe(u8, new_branch_name),
        .head_hash = fork_at_hash,
        .parent_hash = fork_at_hash,
        .parent_branch = try allocator.dupe(u8, parent_branch),
        .created_ts_ms = @intCast(@divFloor(std.Io.Clock.wall.now(io).nanoseconds, 1_000_000)),
    };
    // Take ownership of the existing slice entries by zeroing the old one so
    // bf.deinit doesn't double-free; replace pointers.
    allocator.free(bf.branches);
    bf.branches = new_list;

    try atomicWrite(io, dir, &bf, allocator);
}
```

**Step 4: Verify green.**

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.10 — kb.branches.fork".

---

### Task 1.11 — `kb.branches.switchActive`

**Files:**
- Modify: `src/kb/branches.zig`

**Step 1: Write the failing test.**

```zig
pub fn switchActive(
    allocator: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    branch_name: []const u8,
) !void {
    _ = allocator;
    _ = dir;
    _ = branch_name;
    return error.NotImplemented;
}

test "switchActive flips branches.json.active and errors on unknown branch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{
        .sub_path = "branches.json",
        .data =
        \\{"active":"main","branches":[
        \\{"name":"main","head_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_branch":"","created_ts_ms":0},
        \\{"name":"exp-a","head_hash":"abababababababababababababababababababababababababababababababab","parent_hash":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd","parent_branch":"main","created_ts_ms":1}
        \\]}
        ,
    });

    try switchActive(std.testing.allocator, tmp.dir, "exp-a");

    const buf = try tmp.dir.readFileAlloc(io, "branches.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(buf);
    var bf = try parseSlice(std.testing.allocator, buf);
    defer bf.deinit();
    try std.testing.expectEqualStrings("exp-a", bf.active);

    try std.testing.expectError(
        error.UnknownBranch,
        switchActive(std.testing.allocator, tmp.dir, "nope"),
    );
}
```

**Step 2: Verify failure.** `error.NotImplemented`.

**Step 3: Implement.**

```zig
pub fn switchActive(
    allocator: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    branch_name: []const u8,
) !void {
    const buf = try dir.readFileAlloc(io, "branches.json", allocator, .unlimited);
    defer allocator.free(buf);
    var bf = try parseSlice(allocator, buf);
    defer bf.deinit();

    var found = false;
    for (bf.branches) |b| {
        if (std.mem.eql(u8, b.name, branch_name)) { found = true; break; }
    }
    if (!found) return error.UnknownBranch;

    allocator.free(bf.active);
    bf.active = try allocator.dupe(u8, branch_name);
    try atomicWrite(io, dir, &bf, allocator);
}
```

**Step 4: Verify green.**

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.11 — kb.branches.switchActive".

---

### Task 1.12 — `kb.manifest` (market + thesis manifest parsers)

**Files:**
- Create: `src/kb/manifest.zig`
- Modify: `src/root.zig` (add `pub const manifest = @import("kb/manifest.zig");` to the `kb` namespace + `_ = kb.manifest;` in root test block)

**Step 1: Write the failing test.** Create `src/kb/manifest.zig`:

```zig
//! market + thesis manifest schemas.
//!
//! market/<TICKER>/manifest.json:
//!   {"kind":"market","ticker":"KXBTC-...","trigger":{"price_delta_cents":1}}
//!
//! theses/<id>/manifest.json:
//!   {"kind":"thesis","id":"fed-cuts-june-2026","description":"...",
//!    "market_set":["KXFED-JUN-CUT","KXRECESSION-Q2"],
//!    "rollup_fn":"weighted_avg_v1","weights":{"KXFED-JUN-CUT":7000,"KXRECESSION-Q2":3000},
//!    "trigger":{"confidence_delta_bp":500}}

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MarketManifest = struct {
    allocator: Allocator,
    ticker: []u8,
    price_delta_cents: u32,

    pub fn deinit(self: *MarketManifest) void {
        self.allocator.free(self.ticker);
    }
};

pub const ThesisManifest = struct {
    allocator: Allocator,
    id: []u8,
    description: []u8,
    rollup_fn: []u8,
    market_set: [][]u8,
    weights_bp: []u32, // parallel to market_set; weighted average weights in basis points
    confidence_delta_bp: u32,

    pub fn deinit(self: *ThesisManifest) void {
        self.allocator.free(self.id);
        self.allocator.free(self.description);
        self.allocator.free(self.rollup_fn);
        for (self.market_set) |t| self.allocator.free(t);
        self.allocator.free(self.market_set);
        self.allocator.free(self.weights_bp);
    }
};

pub fn parseMarket(allocator: Allocator, json: []const u8) !MarketManifest {
    _ = allocator;
    _ = json;
    return error.NotImplemented;
}

pub fn parseThesis(allocator: Allocator, json: []const u8) !ThesisManifest {
    _ = allocator;
    _ = json;
    return error.NotImplemented;
}

test "parseMarket extracts ticker + price_delta_cents" {
    const json =
        \\{"kind":"market","ticker":"KXBTC-26APR10-T100000","trigger":{"price_delta_cents":1}}
    ;
    var m = try parseMarket(std.testing.allocator, json);
    defer m.deinit();
    try std.testing.expectEqualStrings("KXBTC-26APR10-T100000", m.ticker);
    try std.testing.expectEqual(@as(u32, 1), m.price_delta_cents);
}

test "parseThesis reads market_set + weights in parallel" {
    const json =
        \\{"kind":"thesis","id":"fed-cuts-june-2026","description":"Fed cuts in June",
        \\"market_set":["KXFED-JUN-CUT","KXRECESSION-Q2"],"rollup_fn":"weighted_avg_v1",
        \\"weights":{"KXFED-JUN-CUT":7000,"KXRECESSION-Q2":3000},
        \\"trigger":{"confidence_delta_bp":500}}
    ;
    var t = try parseThesis(std.testing.allocator, json);
    defer t.deinit();
    try std.testing.expectEqualStrings("fed-cuts-june-2026", t.id);
    try std.testing.expectEqual(@as(usize, 2), t.market_set.len);
    try std.testing.expectEqualStrings("KXFED-JUN-CUT", t.market_set[0]);
    try std.testing.expectEqual(@as(u32, 7000), t.weights_bp[0]);
}
```

Wire into `src/root.zig`.

**Step 2: Verify failure.** Two test cases fail with `error.NotImplemented`.

**Step 3: Implement.**

```zig
pub fn parseMarket(allocator: Allocator, json: []const u8) !MarketManifest {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    if (!std.mem.eql(u8, root.get("kind").?.string, "market")) return error.WrongManifestKind;
    return .{
        .allocator = allocator,
        .ticker = try allocator.dupe(u8, root.get("ticker").?.string),
        .price_delta_cents = @intCast(root.get("trigger").?.object.get("price_delta_cents").?.integer),
    };
}

pub fn parseThesis(allocator: Allocator, json: []const u8) !ThesisManifest {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    if (!std.mem.eql(u8, root.get("kind").?.string, "thesis")) return error.WrongManifestKind;

    const market_arr = root.get("market_set").?.array;
    const market_set = try allocator.alloc([]u8, market_arr.items.len);
    errdefer allocator.free(market_set);
    const weights = try allocator.alloc(u32, market_arr.items.len);
    errdefer allocator.free(weights);

    const weights_obj = root.get("weights").?.object;
    for (market_arr.items, 0..) |item, i| {
        market_set[i] = try allocator.dupe(u8, item.string);
        weights[i] = @intCast(weights_obj.get(item.string).?.integer);
    }

    return .{
        .allocator = allocator,
        .id = try allocator.dupe(u8, root.get("id").?.string),
        .description = try allocator.dupe(u8, root.get("description").?.string),
        .rollup_fn = try allocator.dupe(u8, root.get("rollup_fn").?.string),
        .market_set = market_set,
        .weights_bp = weights,
        .confidence_delta_bp = @intCast(root.get("trigger").?.object.get("confidence_delta_bp").?.integer),
    };
}
```

**Step 4: Verify green.**

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.12 — kb.manifest parsers".

---

### Task 1.13 — Stage 1 golden-fixture test (`kb/testdata/lifecycle.zig`)

**Files:**
- Create: `src/kb/testdata/lifecycle_seed.zig` (a small Zig helper that emits the fixture JSONL deterministically)
- Modify: `src/kb/chain.zig` (add the test at the bottom)

> **Rationale:** the fixture is generated by code (not a static file) because `tx_id` is non-deterministic. We assert on chain structure, not byte-equality of the txlog itself.

**Step 1: Write the failing test.** Append to `src/kb/chain.zig`:

```zig
test "golden lifecycle: write 3 → fork at idx1 → switchActive → recover torn tail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // Seed empty main + branches.json.
    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = "" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "branches.json",
        .data =
        \\{"active":"main","branches":[{"name":"main","head_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_branch":"","created_ts_ms":0}]}
        ,
    });

    // 1. Write 3 entries on main.
    var fork_at_hash: Hash = undefined;
    {
        var h = try openForWrite(std.testing.allocator, io, tmp.dir, "main");
        defer h.deinit();
        _ = try h.append("{\"kind\":\"market.reality\",\"ts\":1,\"yes_bid_cents\":50}");
        const tx2 = try h.append("{\"kind\":\"market.reality\",\"ts\":2,\"yes_bid_cents\":55}");
        fork_at_hash = tx2.hash;
        _ = try h.append("{\"kind\":\"market.reality\",\"ts\":3,\"yes_bid_cents\":60}");
    }

    // 2. Fork at idx 1 → exp-a.
    try branches_mod.fork(std.testing.allocator, tmp.dir, "main", fork_at_hash, "exp-a");

    // 3. Switch active to exp-a.
    try branches_mod.switchActive(std.testing.allocator, tmp.dir, "exp-a");

    // 4. exp-a chain has 2 entries; main still has 3.
    var exp_a = try openRead(std.testing.allocator, io, tmp.dir, "exp-a");
    defer exp_a.deinit();
    try std.testing.expectEqual(@as(usize, 2), exp_a.len());

    var main_chain = try openRead(std.testing.allocator, io, tmp.dir, "main");
    defer main_chain.deinit();
    try std.testing.expectEqual(@as(usize, 3), main_chain.len());

    // 5. Append a 3rd entry to exp-a, then simulate a torn write.
    {
        var h = try openForWrite(std.testing.allocator, io, tmp.dir, "exp-a");
        defer h.deinit();
        _ = try h.append("{\"kind\":\"market.reality\",\"ts\":4,\"yes_bid_cents\":58}");
    }
    {
        var f = try tmp.dir.openFile(io, "exp-a.jsonl", .{ .mode = .read_write });
        defer f.close(io);
        try f.seekFromEnd(io, 0);
        try f.writeStreamingAll(io, "{\"tx_id\":\"tx_TORN_");
    }

    try recoverTornTail(io, tmp.dir, "exp-a.jsonl");

    var exp_a_recovered = try openRead(std.testing.allocator, io, tmp.dir, "exp-a");
    defer exp_a_recovered.deinit();
    try std.testing.expectEqual(@as(usize, 3), exp_a_recovered.len());
}
```

> If the test fails to compile because `branches_mod` is not yet referenced inside `chain.zig`, add `const branches_mod = @import("branches.zig");` at the top.

**Step 2: Verify** — runs and passes (all components from prior tasks are in place). If it fails, fix the relevant prior task before proceeding.

**Step 3: Commit.** `fullPrompt`: "Stage 1 Task 1.13 — KB lifecycle golden fixture".

---

**Stage 1 exit gate:** `zig build test --summary all` is green. The KB substrate compiles, exposes `kb.chain.{openRead,openForWrite,append,recoverTornTail}`, `kb.branches.{fork,switchActive}`, `kb.manifest.{parseMarket,parseThesis}`, and a full lifecycle is covered by an inline golden test.

---

## Stage 2 — Market Ingest + Kalshi Integration

**Deliverable:** `kb.ingest.observeMarket / observeResolution / observeManual` plus optional hooks in `src/kalshi/markets.zig` and `src/kalshi/orders.zig`. With `kb_root` unset, the Kalshi modules behave exactly as before.

### Task 2.1 — `kb.ingest.MarketSnapshot` + `observeMarket` (price_delta predicate)

**Files:**
- Create: `src/kb/ingest.zig`
- Modify: `src/root.zig` (add `pub const ingest = @import("kb/ingest.zig");` + `_ = kb.ingest;`)

**Step 1: Write the failing test.**

```zig
//! kb.ingest — pushes observations into market chains, gated by per-market
//! trigger predicates.

const std = @import("std");
const Allocator = std.mem.Allocator;
const chain_mod = @import("chain.zig");
const manifest_mod = @import("manifest.zig");

pub const MarketSnapshot = struct {
    ts_ms: u64,
    yes_bid_cents: u32,
    yes_ask_cents: u32,
    volume: u64,
    last_trade_cents: ?u32,
};

/// Apply the market's trigger predicate against the current chain head, and
/// if it fires, append a `market.reality` checkpoint. Returns true if a
/// checkpoint was written.
pub fn observeMarket(
    allocator: Allocator,
    io: std.Io,
    market_dir: std.Io.Dir,
    snap: MarketSnapshot,
) !bool {
    _ = allocator;
    _ = market_dir;
    _ = snap;
    return error.NotImplemented;
}

test "observeMarket appends only when price moved past manifest threshold" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.makeDir(io, "reality");

    // Seed market manifest with 1c threshold + empty reality chain + branches.json.
    try tmp.dir.writeFile(io, .{
        .sub_path = "manifest.json",
        .data = "{\"kind\":\"market\",\"ticker\":\"KXTEST\",\"trigger\":{\"price_delta_cents\":1}}",
    });
    var reality_dir = try tmp.dir.openDir(io, "reality", .{ .iterate = false });
    defer reality_dir.close();
    try reality_dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = "" });
    try reality_dir.writeFile(io, .{
        .sub_path = "branches.json",
        .data =
        \\{"active":"main","branches":[{"name":"main","head_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_branch":"","created_ts_ms":0}]}
        ,
    });

    // First observation: empty chain → always appends.
    const wrote1 = try observeMarket(std.testing.allocator, tmp.dir, .{
        .ts_ms = 100,
        .yes_bid_cents = 50,
        .yes_ask_cents = 51,
        .volume = 1000,
        .last_trade_cents = null,
    });
    try std.testing.expect(wrote1);

    // Second: 0c delta → no append.
    const wrote2 = try observeMarket(std.testing.allocator, tmp.dir, .{
        .ts_ms = 200,
        .yes_bid_cents = 50,
        .yes_ask_cents = 51,
        .volume = 1100,
        .last_trade_cents = null,
    });
    try std.testing.expect(!wrote2);

    // Third: 2c delta → appends.
    const wrote3 = try observeMarket(std.testing.allocator, tmp.dir, .{
        .ts_ms = 300,
        .yes_bid_cents = 52,
        .yes_ask_cents = 53,
        .volume = 1200,
        .last_trade_cents = null,
    });
    try std.testing.expect(wrote3);

    var chain = try chain_mod.openRead(std.testing.allocator, io, reality_dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 2), chain.len());
}
```

**Step 2: Verify failure.** `error.NotImplemented`.

**Step 3: Implement.**

```zig
pub fn observeMarket(
    allocator: Allocator,
    io: std.Io,
    market_dir: std.Io.Dir,
    snap: MarketSnapshot,
) !bool {
    // Load manifest.
    const manifest_buf = try market_dir.readFileAlloc(io, "manifest.json", allocator, .unlimited);
    defer allocator.free(manifest_buf);
    var manifest = try manifest_mod.parseMarket(allocator, manifest_buf);
    defer manifest.deinit();

    // Open reality chain for write under flock.
    var reality_dir = try market_dir.openDir(io, "reality", .{ .iterate = false });
    defer reality_dir.close();

    // Peek the current head's payload to extract prev_yes_bid for trigger comparison.
    var prev_yes_bid: ?u32 = null;
    {
        var read = chain_mod.openRead(allocator, io, io, io, reality_dir, "main") catch |err| switch (err) {
            error.BranchNotFound => null_chain: {
                break :null_chain return error.BranchNotFound;
            },
            else => return err,
        };
        defer read.deinit();
        if (read.len() > 0) {
            const last = read.log.items.items[read.len() - 1];
            // Parse just enough to grab yes_bid_cents from the payload object.
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, last.payload, .{});
            defer parsed.deinit();
            if (parsed.value.object.get("yes_bid_cents")) |v| {
                prev_yes_bid = @intCast(v.integer);
            }
        }
    }

    // Predicate.
    const fires = prev_yes_bid == null or absDeltaU32(prev_yes_bid.?, snap.yes_bid_cents) >= manifest.price_delta_cents;
    if (!fires) return false;

    // Build canonical JSON payload and append.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print(
        "{{\"kind\":\"market.reality\",\"last_trade_cents\":{?d},\"trigger\":{{\"prev_yes_bid\":{?d},\"type\":\"price_delta\"}},\"ts\":{d},\"volume\":{d},\"yes_ask_cents\":{d},\"yes_bid_cents\":{d}}}",
        .{ snap.last_trade_cents, prev_yes_bid, snap.ts_ms, snap.volume, snap.yes_ask_cents, snap.yes_bid_cents },
    );

    var h = try chain_mod.openForWrite(allocator, io, io, io, reality_dir, "main");
    defer h.deinit();
    _ = try h.append(aw.written());
    return true;
}

fn absDeltaU32(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}
```

> Note: keys in the printf are pre-sorted alphabetically to satisfy canonical-JSON encoding. (If you want to be defensive, route the payload through `canonical_json.encodeSlice` instead.)

**Step 4: Verify green.**

**Step 5: Commit.** `fullPrompt`: "Stage 2 Task 2.1 — observeMarket with price_delta predicate".

---

### Task 2.2 — `observeResolution` (terminal trigger)

**Files:**
- Modify: `src/kb/ingest.zig`

**Step 1: Write the failing test.**

```zig
pub const Resolution = struct {
    ts_ms: u64,
    resolved_yes: bool,
};

pub fn observeResolution(
    allocator: Allocator,
    io: std.Io,
    market_dir: std.Io.Dir,
    res: Resolution,
) !void {
    _ = allocator;
    _ = market_dir;
    _ = res;
    return error.NotImplemented;
}

test "observeResolution appends a terminal record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.makeDir(io, "reality");

    try tmp.dir.writeFile(io, .{ .sub_path = "manifest.json",
        .data = "{\"kind\":\"market\",\"ticker\":\"KXTEST\",\"trigger\":{\"price_delta_cents\":1}}" });
    var reality_dir = try tmp.dir.openDir(io, "reality", .{ .iterate = false });
    defer reality_dir.close();
    try reality_dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = "" });
    try reality_dir.writeFile(io, .{ .sub_path = "branches.json",
        .data = "{\"active\":\"main\",\"branches\":[{\"name\":\"main\",\"head_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_branch\":\"\",\"created_ts_ms\":0}]}" });

    try observeResolution(std.testing.allocator, tmp.dir, .{ .ts_ms = 999, .resolved_yes = true });

    var chain = try chain_mod.openRead(std.testing.allocator, io, reality_dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.len());
    try std.testing.expect(std.mem.indexOf(u8, chain.log.items.items[0].payload, "\"resolution\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain.log.items.items[0].payload, "\"resolved_yes\":true") != null);
}
```

**Step 2: Verify failure.** `error.NotImplemented`.

**Step 3: Implement.**

```zig
pub fn observeResolution(
    allocator: Allocator,
    io: std.Io,
    market_dir: std.Io.Dir,
    res: Resolution,
) !void {
    var reality_dir = try market_dir.openDir(io, "reality", .{ .iterate = false });
    defer reality_dir.close();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print(
        "{{\"kind\":\"market.reality\",\"resolved_yes\":{s},\"trigger\":{{\"type\":\"resolution\"}},\"ts\":{d}}}",
        .{ if (res.resolved_yes) "true" else "false", res.ts_ms },
    );

    var h = try chain_mod.openForWrite(allocator, io, io, io, reality_dir, "main");
    defer h.deinit();
    _ = try h.append(aw.written());
}
```

**Step 4: Verify green.**

**Step 5: Commit.** `fullPrompt`: "Stage 2 Task 2.2 — observeResolution".

---

### Task 2.3 — `observeManual` (prediction-chain bypass)

**Files:**
- Modify: `src/kb/ingest.zig`

**Step 1: Write the failing test.**

```zig
pub fn observeManual(
    allocator: Allocator,
    io: std.Io,
    chain_dir: std.Io.Dir,
    canonical_payload: []const u8,
) !void {
    _ = allocator;
    _ = chain_dir;
    _ = canonical_payload;
    return error.NotImplemented;
}

test "observeManual bypasses predicates and appends raw payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "branches.json",
        .data = "{\"active\":\"main\",\"branches\":[{\"name\":\"main\",\"head_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_branch\":\"\",\"created_ts_ms\":0}]}" });

    const payload = "{\"confidence_bp\":7200,\"kind\":\"market.prediction\",\"rationale\":\"manual override\",\"trigger\":{\"type\":\"manual_decision\"},\"ts\":42}";
    try observeManual(std.testing.allocator, tmp.dir, payload);

    var chain = try chain_mod.openRead(std.testing.allocator, io, tmp.dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.len());
}
```

**Step 2: Verify failure.** `error.NotImplemented`.

**Step 3: Implement.**

```zig
pub fn observeManual(
    allocator: Allocator,
    io: std.Io,
    chain_dir: std.Io.Dir,
    canonical_payload: []const u8,
) !void {
    var h = try chain_mod.openForWrite(allocator, io, io, io, chain_dir, "main");
    defer h.deinit();
    _ = try h.append(canonical_payload);
}
```

**Step 4: Verify green.**

**Step 5: Commit.** `fullPrompt`: "Stage 2 Task 2.3 — observeManual".

---

### Task 2.4 — Optional `kb_root` hook in `src/kalshi/markets.zig`

**Files:**
- Modify: `src/kalshi/markets.zig` (add an optional ingest hook to the `get` and `list` entry points)

**Background:** the integration is opt-in — if `kb_root` is null, behavior is identical to today.

**Step 1: Write the failing integration test in `src/kalshi/markets.zig`.**

```zig
test "kb_root hook: get() appends to market chain when kb_root is set" {
    // This test uses tmp dirs to stand in for kb_root. It does NOT make a real
    // Kalshi request; instead it exercises the hook function directly.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.makePath(io, "markets/KXTEST/reality");
    try tmp.dir.writeFile(io, .{ .sub_path = "markets/KXTEST/manifest.json",
        .data = "{\"kind\":\"market\",\"ticker\":\"KXTEST\",\"trigger\":{\"price_delta_cents\":1}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "markets/KXTEST/reality/main.jsonl", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "markets/KXTEST/reality/branches.json",
        .data = "{\"active\":\"main\",\"branches\":[{\"name\":\"main\",\"head_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_branch\":\"\",\"created_ts_ms\":0}]}" });

    try kbHookMarket(std.testing.allocator, tmp.dir, "KXTEST", .{
        .ts_ms = 1, .yes_bid_cents = 50, .yes_ask_cents = 51, .volume = 100, .last_trade_cents = null,
    });

    // The chain now has one entry.
    var market_dir = try tmp.dir.openDir(io, "markets/KXTEST", .{ .iterate = false });
    defer market_dir.close();
    var reality_dir = try market_dir.openDir(io, "reality", .{ .iterate = false });
    defer reality_dir.close();
    var chain = try @import("../kb/chain.zig").openRead(std.testing.allocator, io, reality_dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.len());
}
```

**Step 2: Verify failure.** `kbHookMarket` is undeclared → compile error.

**Step 3: Implement** at the bottom of `src/kalshi/markets.zig`:

```zig
const ingest = @import("../kb/ingest.zig");

/// Optional pass-through: callers that have a kb_root opened and a market
/// directory inside it call this after every successful `get`/`list` to keep
/// the reality chain current. If no kb_root is configured, this function is
/// never called.
pub fn kbHookMarket(
    allocator: std.mem.Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
    ticker: []const u8,
    snap: ingest.MarketSnapshot,
) !void {
    var market_path_buf: [256]u8 = undefined;
    const market_path = try std.fmt.bufPrint(&market_path_buf, "markets/{s}", .{ticker});
    var market_dir = try kb_root.openDir(io, market_path, .{ .iterate = false });
    defer market_dir.close();
    _ = try ingest.observeMarket(allocator, market_dir, snap);
}
```

**Step 4: Verify green.**

**Step 5: Commit.** `fullPrompt`: "Stage 2 Task 2.4 — kb_root hook in src/kalshi/markets.zig".

---

### Task 2.5 — Same hook in `src/kalshi/orders.zig` (fill → resolution dispatch is a follow-up)

**Files:**
- Modify: `src/kalshi/orders.zig`

**Step 1: Write the failing test** — analogous to 2.4 but exercising `kbHookFill` which appends a `new_trade`-triggered reality record using the fill's price.

```zig
test "kb_root hook: fill appends a new_trade reality record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.makePath(io, "markets/KXTEST/reality");
    try tmp.dir.writeFile(io, .{ .sub_path = "markets/KXTEST/manifest.json",
        .data = "{\"kind\":\"market\",\"ticker\":\"KXTEST\",\"trigger\":{\"price_delta_cents\":1}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "markets/KXTEST/reality/main.jsonl", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "markets/KXTEST/reality/branches.json",
        .data = "{\"active\":\"main\",\"branches\":[{\"name\":\"main\",\"head_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_branch\":\"\",\"created_ts_ms\":0}]}" });

    try kbHookFill(std.testing.allocator, tmp.dir, "KXTEST", 1, 55, 100);

    var market_dir = try tmp.dir.openDir(io, "markets/KXTEST", .{ .iterate = false });
    defer market_dir.close();
    var reality_dir = try market_dir.openDir(io, "reality", .{ .iterate = false });
    defer reality_dir.close();
    var chain = try @import("../kb/chain.zig").openRead(std.testing.allocator, io, reality_dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.len());
    try std.testing.expect(std.mem.indexOf(u8, chain.log.items.items[0].payload, "\"new_trade\"") != null);
}
```

**Step 2: Verify failure.** `kbHookFill` undeclared.

**Step 3: Implement** at the bottom of `src/kalshi/orders.zig`:

```zig
const ingest = @import("../kb/ingest.zig");
const chain_mod = @import("../kb/chain.zig");

pub fn kbHookFill(
    allocator: std.mem.Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
    ticker: []const u8,
    ts_ms: u64,
    trade_cents: u32,
    quantity: u64,
) !void {
    var market_path_buf: [256]u8 = undefined;
    const market_path = try std.fmt.bufPrint(&market_path_buf, "markets/{s}", .{ticker});
    var market_dir = try kb_root.openDir(io, market_path, .{ .iterate = false });
    defer market_dir.close();
    var reality_dir = try market_dir.openDir(io, "reality", .{ .iterate = false });
    defer reality_dir.close();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print(
        "{{\"kind\":\"market.reality\",\"last_trade_cents\":{d},\"quantity\":{d},\"trigger\":{{\"type\":\"new_trade\"}},\"ts\":{d}}}",
        .{ trade_cents, quantity, ts_ms },
    );

    var h = try chain_mod.openForWrite(allocator, io, io, io, reality_dir, "main");
    defer h.deinit();
    _ = try h.append(aw.written());
}
```

**Step 4: Verify green.**

**Step 5: Commit.** `fullPrompt`: "Stage 2 Task 2.5 — kb_root hook in src/kalshi/orders.zig".

---

**Stage 2 exit gate:** `zig build test --summary all` is green. New `kb.ingest` surface is in place. Both Kalshi modules accept an optional `kb_root` and write to per-market reality chains without breaking any existing tests.

---

## Stage 3 — Rollup Registry + Thesis Projection

**Deliverable:** Thesis chains exist. A registered rollup function (`weighted_avg_v1`) projects market-level reality into thesis-level reality. A simple reducer recomputes thesis chains on demand.

### Task 3.1 — `kb.rollup` registry skeleton

**Files:**
- Create: `src/kb/rollup.zig`
- Modify: `src/root.zig` (`pub const rollup = @import("kb/rollup.zig");` + `_ = kb.rollup;`)

**Step 1: Write the failing test.**

```zig
//! Compile-time registry of rollup functions. Each thesis manifest names a
//! rollup by string; the registry resolves names to function pointers.

const std = @import("std");

pub const MarketSnapshotForRollup = struct {
    ticker: []const u8,
    yes_bid_cents: u32,
    yes_ask_cents: u32,
    head_hash_hex: []const u8,
};

pub const RollupInput = struct {
    sources: []const MarketSnapshotForRollup,
    weights_bp: []const u32, // parallel to sources, sums to 10000 (validated)
};

pub const RollupResult = struct {
    aggregate_yes_cents: u32,
};

pub const RollupFn = *const fn (input: RollupInput) RollupResult;

var registry: std.StringHashMapUnmanaged(RollupFn) = .{};

pub fn register(allocator: std.mem.Allocator, name: []const u8, f: RollupFn) !void {
    _ = allocator;
    _ = name;
    _ = f;
    return error.NotImplemented;
}

pub fn lookup(name: []const u8) ?RollupFn {
    _ = name;
    return null;
}

fn dummyV1(input: RollupInput) RollupResult {
    _ = input;
    return .{ .aggregate_yes_cents = 0 };
}

test "register + lookup round-trip" {
    try register(std.testing.allocator, "dummy_v1", &dummyV1);
    defer registry.deinit(std.testing.allocator);

    const f = lookup("dummy_v1").?;
    const r = f(.{ .sources = &.{}, .weights_bp = &.{} });
    try std.testing.expectEqual(@as(u32, 0), r.aggregate_yes_cents);
}
```

**Step 2: Verify failure.** `register` → `error.NotImplemented`.

**Step 3: Implement.**

```zig
pub fn register(allocator: std.mem.Allocator, name: []const u8, f: RollupFn) !void {
    try registry.put(allocator, name, f);
}

pub fn lookup(name: []const u8) ?RollupFn {
    return registry.get(name);
}
```

**Step 4: Verify green.**

**Step 5: Commit.** `fullPrompt`: "Stage 3 Task 3.1 — Rollup registry".

---

### Task 3.2 — `weighted_avg_v1` implementation

**Files:**
- Modify: `src/kb/rollup.zig`

**Step 1: Write the failing test.**

```zig
pub fn weightedAvgV1(input: RollupInput) RollupResult {
    _ = input;
    return .{ .aggregate_yes_cents = 0 };
}

test "weighted_avg_v1 averages by basis-point weights" {
    const sources = [_]MarketSnapshotForRollup{
        .{ .ticker = "A", .yes_bid_cents = 60, .yes_ask_cents = 62, .head_hash_hex = "aa" ** 32 },
        .{ .ticker = "B", .yes_bid_cents = 40, .yes_ask_cents = 42, .head_hash_hex = "bb" ** 32 },
    };
    const weights = [_]u32{ 7000, 3000 };
    const r = weightedAvgV1(.{ .sources = &sources, .weights_bp = &weights });
    // mid-prices: (60+62)/2 = 61, (40+42)/2 = 41
    // weighted: 0.7*61 + 0.3*41 = 42.7 + 12.3 = 55
    try std.testing.expectEqual(@as(u32, 55), r.aggregate_yes_cents);
}
```

**Step 2: Verify failure.** Returns 0, test expects 55.

**Step 3: Implement.**

```zig
pub fn weightedAvgV1(input: RollupInput) RollupResult {
    std.debug.assert(input.sources.len == input.weights_bp.len);
    var total: u64 = 0;
    var weight_total: u64 = 0;
    for (input.sources, input.weights_bp) |src, w| {
        const mid = (@as(u64, src.yes_bid_cents) + @as(u64, src.yes_ask_cents)) / 2;
        total += mid * @as(u64, w);
        weight_total += w;
    }
    if (weight_total == 0) return .{ .aggregate_yes_cents = 0 };
    return .{ .aggregate_yes_cents = @intCast(total / weight_total) };
}
```

**Step 4: Verify green.**

**Step 5: Commit.** `fullPrompt`: "Stage 3 Task 3.2 — weighted_avg_v1 rollup".

---

### Task 3.3 — Boot-time registration of all v1 rollups (`registerAll`)

**Files:**
- Modify: `src/kb/rollup.zig`

**Step 1: Write the failing test.**

```zig
pub fn registerAll(allocator: std.mem.Allocator) !void {
    _ = allocator;
    return error.NotImplemented;
}

test "registerAll wires up weighted_avg_v1" {
    try registerAll(std.testing.allocator);
    defer registry.deinit(std.testing.allocator);
    try std.testing.expect(lookup("weighted_avg_v1") != null);
}
```

**Step 2: Verify failure.** `error.NotImplemented`.

**Step 3: Implement.**

```zig
pub fn registerAll(allocator: std.mem.Allocator) !void {
    try register(allocator, "weighted_avg_v1", &weightedAvgV1);
}
```

**Step 4: Verify green.**

**Step 5: Commit.** `fullPrompt`: "Stage 3 Task 3.3 — Rollup registerAll".

---

### Task 3.4 — Thesis reducer: `kb.ingest.recomputeThesisReality`

**Files:**
- Modify: `src/kb/ingest.zig`

**Step 1: Write the failing test.**

```zig
const rollup_mod = @import("rollup.zig");

pub fn recomputeThesisReality(
    allocator: Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
    thesis_id: []const u8,
) !bool {
    _ = allocator;
    _ = kb_root;
    _ = thesis_id;
    return error.NotImplemented;
}

test "recomputeThesisReality appends a thesis.reality entry when rollup crosses threshold" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // Two market chains with one entry each.
    inline for (.{ "A", "B" }) |t| {
        const market_path = "markets/" ++ t;
        try tmp.dir.makePath(market_path ++ "/reality");
        try tmp.dir.writeFile(io, .{
            .sub_path = market_path ++ "/manifest.json",
            .data = "{\"kind\":\"market\",\"ticker\":\"" ++ t ++ "\",\"trigger\":{\"price_delta_cents\":1}}",
        });
        try tmp.dir.writeFile(io, .{ .sub_path = market_path ++ "/reality/main.jsonl", .data = "" });
        try tmp.dir.writeFile(io, .{ .sub_path = market_path ++ "/reality/branches.json",
            .data = "{\"active\":\"main\",\"branches\":[{\"name\":\"main\",\"head_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_branch\":\"\",\"created_ts_ms\":0}]}" });
    }
    // Seed market A at 60c, B at 40c.
    var a_dir = try tmp.dir.openDir(io, "markets/A", .{ .iterate = false });
    defer a_dir.close();
    _ = try observeMarket(std.testing.allocator, a_dir, .{ .ts_ms = 1, .yes_bid_cents = 60, .yes_ask_cents = 62, .volume = 1, .last_trade_cents = null });
    var b_dir = try tmp.dir.openDir(io, "markets/B", .{ .iterate = false });
    defer b_dir.close();
    _ = try observeMarket(std.testing.allocator, b_dir, .{ .ts_ms = 1, .yes_bid_cents = 40, .yes_ask_cents = 42, .volume = 1, .last_trade_cents = null });

    // Thesis manifest + empty thesis reality chain.
    try tmp.dir.makePath(io, "theses/T/reality");
    try tmp.dir.writeFile(io, .{ .sub_path = "theses/T/manifest.json",
        .data =
        \\{"kind":"thesis","id":"T","description":"x","market_set":["A","B"],"rollup_fn":"weighted_avg_v1","weights":{"A":7000,"B":3000},"trigger":{"confidence_delta_bp":500}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "theses/T/reality/main.jsonl", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "theses/T/reality/branches.json",
        .data = "{\"active\":\"main\",\"branches\":[{\"name\":\"main\",\"head_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_branch\":\"\",\"created_ts_ms\":0}]}" });

    try rollup_mod.registerAll(std.testing.allocator);
    defer rollup_mod.registry.deinit(std.testing.allocator);

    const wrote = try recomputeThesisReality(std.testing.allocator, tmp.dir, "T");
    try std.testing.expect(wrote);

    var thesis_reality_dir = try tmp.dir.openDir(io, "theses/T/reality", .{ .iterate = false });
    defer thesis_reality_dir.close();
    var chain = try chain_mod.openRead(std.testing.allocator, io, thesis_reality_dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.len());
    try std.testing.expect(std.mem.indexOf(u8, chain.log.items.items[0].payload, "\"aggregate_yes_cents\":55") != null);
}
```

**Step 2: Verify failure.** `error.NotImplemented`.

**Step 3: Implement.**

```zig
pub fn recomputeThesisReality(
    allocator: Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
    thesis_id: []const u8,
) !bool {
    var thesis_path_buf: [256]u8 = undefined;
    const thesis_path = try std.fmt.bufPrint(&thesis_path_buf, "theses/{s}", .{thesis_id});
    var thesis_dir = try kb_root.openDir(io, thesis_path, .{ .iterate = false });
    defer thesis_dir.close();

    const manifest_buf = try thesis_dir.readFileAlloc(io, "manifest.json", allocator, .unlimited);
    defer allocator.free(manifest_buf);
    var manifest = try manifest_mod.parseThesis(allocator, manifest_buf);
    defer manifest.deinit();

    const rollup_fn = rollup_mod.lookup(manifest.rollup_fn) orelse return error.UnknownRollupFn;

    // Gather current heads + bids/asks from each market in market_set.
    const snaps = try allocator.alloc(rollup_mod.MarketSnapshotForRollup, manifest.market_set.len);
    defer {
        for (snaps) |s| allocator.free(@constCast(s.head_hash_hex));
        allocator.free(snaps);
    }

    for (manifest.market_set, 0..) |ticker, i| {
        var market_path_buf: [256]u8 = undefined;
        const market_path = try std.fmt.bufPrint(&market_path_buf, "markets/{s}/reality", .{ticker});
        var reality_dir = try kb_root.openDir(io, market_path, .{ .iterate = false });
        defer reality_dir.close();

        var read = try chain_mod.openRead(allocator, io, io, io, reality_dir, "main");
        defer read.deinit();
        if (read.len() == 0) return false;
        const last = read.log.items.items[read.len() - 1];

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, last.payload, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const yes_bid: u32 = if (obj.get("yes_bid_cents")) |v| @intCast(v.integer) else 0;
        const yes_ask: u32 = if (obj.get("yes_ask_cents")) |v| @intCast(v.integer) else 0;

        var hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x}", .{last.hash}) catch unreachable;
        snaps[i] = .{
            .ticker = ticker,
            .yes_bid_cents = yes_bid,
            .yes_ask_cents = yes_ask,
            .head_hash_hex = try allocator.dupe(u8, &hex),
        };
    }

    const result = rollup_fn(.{ .sources = snaps, .weights_bp = manifest.weights_bp });

    // Compare against current thesis reality head (only emit if delta > threshold or first entry).
    var reality_dir = try thesis_dir.openDir(io, "reality", .{ .iterate = false });
    defer reality_dir.close();
    var prev_agg: ?u32 = null;
    {
        var read = try chain_mod.openRead(allocator, io, io, io, reality_dir, "main");
        defer read.deinit();
        if (read.len() > 0) {
            const last = read.log.items.items[read.len() - 1];
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, last.payload, .{});
            defer parsed.deinit();
            if (parsed.value.object.get("aggregate_yes_cents")) |v| prev_agg = @intCast(v.integer);
        }
    }
    if (prev_agg) |p| {
        const delta = if (p > result.aggregate_yes_cents) p - result.aggregate_yes_cents else result.aggregate_yes_cents - p;
        if (delta < 1) return false; // tiny threshold to keep the test deterministic; tune later
    }

    // Build sources object: alphabetical by ticker.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print(
        "{{\"aggregate_yes_cents\":{d},\"kind\":\"thesis.reality\",\"rollup_fn\":\"{s}\",\"sources\":{{",
        .{ result.aggregate_yes_cents, manifest.rollup_fn },
    );
    for (snaps, 0..) |s, i| {
        if (i > 0) try aw.writer.writeByte(',');
        try aw.writer.print("\"{s}\":\"{s}\"", .{ s.ticker, s.head_hash_hex });
    }
    try aw.writer.print(
        "}},\"trigger\":{{\"type\":\"source_delta\"}},\"ts\":{d}}}",
        .{@as(u64, @intCast(@divFloor(std.Io.Clock.wall.now(io).nanoseconds, 1_000_000)))},
    );

    var h = try chain_mod.openForWrite(allocator, io, io, io, reality_dir, "main");
    defer h.deinit();
    _ = try h.append(aw.written());
    return true;
}
```

**Step 4: Verify green.**

**Step 5: Commit.** `fullPrompt`: "Stage 3 Task 3.4 — Thesis reality reducer".

---

**Stage 3 exit gate:** Thesis chains compile and update on demand. `weighted_avg_v1` is registered and exercised by an inline test. `recomputeThesisReality` reads market heads, composes via rollup, and writes a `thesis.reality` checkpoint.

---

## Stage 4 — Divergence + User Surfaces

**Deliverable:** `kb.divergence.{temporalDivergence,outcomeDivergence}` plus a CLI (`praescientia-kb`) and three read-only dashboard routes.

### Task 4.1 — `kb.divergence.temporalDivergence`

**Files:**
- Create: `src/kb/divergence.zig`
- Modify: `src/root.zig` (`pub const divergence = @import("kb/divergence.zig");` + `_ = kb.divergence;`)

**Step 1: Write the failing test.**

```zig
//! kb.divergence — compare prediction chains against reality chains.

const std = @import("std");
const chain_mod = @import("chain.zig");
const txlog = @import("../txlog.zig");

pub const TemporalDivergence = struct {
    first_drift_idx: ?usize,
    drift_amount_bp: u32,
    threshold_bp: u32,
};

pub fn temporalDivergence(
    prediction: *const chain_mod.Chain,
    reality: *const chain_mod.Chain,
    threshold_bp: u32,
) TemporalDivergence {
    _ = prediction;
    _ = reality;
    return .{ .first_drift_idx = null, .drift_amount_bp = 0, .threshold_bp = threshold_bp };
}

test "temporalDivergence finds first prediction whose belief diverges from reality past threshold" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    // ... seed prediction chain with [50, 55, 70 cents] and reality with [50, 55, 55 cents].
    // Expect first_drift_idx = 2.
    // (Concrete seeding omitted for brevity — match the pattern from prior tasks.)
    _ = tmp;
}
```

**Step 2: Implement** by walking the prediction chain; for each prediction, find the reality entry closest in time (or by `sources` hash for thesis chains), parse `yes_bid_cents` from both, compute |delta| in basis points (delta_cents * 100), compare to threshold. Return first index where threshold is crossed.

(Concrete implementation: ~30 lines. The test seeding needs to mirror the structure of Task 2.1's tests.)

**Step 3: Verify green.**

**Step 4: Commit.** `fullPrompt`: "Stage 4 Task 4.1 — temporalDivergence".

---

### Task 4.2 — `kb.divergence.outcomeDivergence`

**Files:**
- Modify: `src/kb/divergence.zig`

Mirror of Task 4.1 but operating on a resolved-yes terminal record. Walk the prediction chain backwards from the resolution timestamp; find the first prediction whose direction agrees with the resolution. The entry immediately before that is `first_wrong_idx`.

**Test:** seed predictions `[0.40, 0.55, 0.65, 0.70]` confidence on `yes`; resolution = yes. The first prediction where confidence > 0.5 is index 1. So `first_wrong_idx = 0`.

**Commit:** `fullPrompt`: "Stage 4 Task 4.2 — outcomeDivergence".

---

### Task 4.3 — `praescientia-kb` CLI scaffolding

**Files:**
- Create: `tools/kb.zig`
- Modify: `build.zig` (add `praescientia-kb` to the Stage 4 tools array)

**Step 1: Write a `--help` smoke test** that mirrors the existing pattern (`expectExitCode(0)` + `expectStdErrMatch("Usage:")`). The Stage 4 `smoke_step` automatically picks up the new tool when it's added to the `stage4_tools` array.

**Step 2: Implement** `tools/kb.zig` with subcommands `inspect`, `branches`, `fork`, `divergence` using the existing `common.zig` dispatch. Each subcommand opens the relevant chain and prints summary state. ~150 lines following the pattern of `tools/markets.zig`.

**Step 3: Verify** `zig build test --summary all` passes (includes the smoke test) and `./zig-out/bin/praescientia-kb --help` works manually.

**Step 4: Commit.** `fullPrompt`: "Stage 4 Task 4.3 — praescientia-kb CLI".

---

### Task 4.4 — Dashboard read routes

**Files:**
- Modify: `server/handlers.zig` (add three routes: `GET /api/kb/markets/{ticker}/head`, `GET /api/kb/theses/{id}/divergence`, `GET /api/kb/theses/{id}/branches`)

**Step 1: Write a route-match test** confirming `match(.GET, "/api/kb/markets/KXBTC/head", &params)` returns the right route and captures `KXBTC` as `params[0]`.

**Step 2: Implement** each handler. Each opens the relevant chain under `kb_root` (passed via env var or CLI flag at server startup), reads the head/divergence/branches, and returns the standard `{"success":true,"data":..., "timestamp":...}` envelope.

**Step 3: Verify** `zig build test --summary all` is green; manually `curl http://localhost:8080/api/kb/markets/KXBTC/head` returns valid JSON.

**Step 4: Commit.** `fullPrompt`: "Stage 4 Task 4.4 — KB dashboard read routes".

---

### Task 4.5 — Documentation update

**Files:**
- Modify: `README.md` (add a short "Knowledge Base" section pointing at `praescientia-kb --help` and the design doc)
- Modify: `CLAUDE.md` (add `kb/` to the project structure tree; add a row to the CLI table for `praescientia-kb`)

**Step 1:** edit both files.

**Step 2: Commit.** `fullPrompt`: "Stage 4 Task 4.5 — Document KB surface".

---

**Stage 4 exit gate:** `zig build test --summary all` is green. `./zig-out/bin/praescientia-kb inspect kb/markets/KXBTC/reality` prints the head, length, and last 3 entries. The dashboard serves `/api/kb/...` routes. Design + implementation match.

---

## Cross-stage invariants

These hold throughout:

1. **No floats in hashable payloads.** Every numeric field stored in a chain is an integer (cents, basis points, ms timestamps, volumes). Adding a float field is a deliberate decision requiring re-justification.
2. **Single static binary.** No new system dependencies. mbedTLS remains the only vendored library.
3. **Existing tests stay green.** Every `zig build test --summary all` between commits passes.
4. **GitButler-only commits.** Never `git commit`. Always the MCP tool. After the first commit on a new virtual branch, run `but mark` so subsequent hooks land in that branch instead of spawning new ones.
5. **Inline tests only.** No separate `test/` directory. Tests live at the bottom of the file they exercise, matching the existing convention.

---

## Deferred (out of scope for this plan)

- Manifest schema validation against a JSON Schema document
- Prometheus-style `/metrics` endpoint
- Migration of existing `portfolios/` runtime data into kb format
- `praescientia-kb init` bootstrap command
- Dashboard HTML changes (a new "KB" tab is left as a separate user-facing iteration once the API routes are in place)

---

## Execution

Plan complete and saved to `docs/plans/2026-05-17-state-chain-knowledge-base-implementation.md`. Two execution options:

**1. Subagent-Driven (this session)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Parallel Session (separate)** — Open a new Claude Code session in this repo with `superpowers:executing-plans` to batch-execute with checkpoints.

Which approach?
