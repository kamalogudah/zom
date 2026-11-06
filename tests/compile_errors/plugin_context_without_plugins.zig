// expect: zom: `withPluginContext` on relation 'notes', whose schema has no plugins
const zom = @import("zom");

const Note = struct { id: u32 };
const Notes = zom.Relation(zom.Schema(Note, "notes", .id, .{}), zom.memory.Gateway);

export fn entry() void {
    var gw = zom.memory.Gateway.init(@import("std").heap.page_allocator, .{});
    const notes = Notes.init(&gw) catch return;
    _ = notes.withPluginContext(.{});
}
