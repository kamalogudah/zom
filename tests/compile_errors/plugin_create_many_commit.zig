// expect: zom: `createMany` on relation 'notes' runs its schema's `beforeCreate` plugin hooks on a copy of the borrowed rows; commit it with `commitAlloc(allocator)`
const zom = @import("zom");

const Note = struct { id: u32, created_at: i64 = 0, updated_at: i64 = 0 };
const Notes = zom.Relation(zom.Schema(Note, "notes", .id, .{
    .plugins = .{zom.plugins.timestamps(.{})},
}), zom.memory.Gateway);

export fn entry() void {
    var gw = zom.memory.Gateway.init(@import("std").heap.page_allocator, .{});
    const notes = Notes.init(&gw) catch return;
    const rows = [_]Note{.{ .id = 1 }};
    _ = notes.createMany(&rows).commit() catch return;
}
