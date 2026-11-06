// expect: zom.plugins.timestamps on schema "notes": field 'created_at' is `u64`, expected `i64`
const zom = @import("zom");

const Note = struct { id: u32, created_at: u64, updated_at: i64 };
const NoteSchema = zom.Schema(Note, "notes", .id, .{
    .plugins = .{zom.plugins.timestamps(.{ .created = .created_at, .updated = .updated_at })},
});

export fn entry() void {
    _ = NoteSchema;
}
