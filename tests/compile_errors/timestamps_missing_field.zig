// expect: zom.plugins.timestamps on schema "notes": `.updated` field 'updated_at' is not a field of timestamps_missing_field.Note (pass `.updated = .other_field`, or null for none)
const zom = @import("zom");

const Note = struct { id: u32, created_at: i64 };
const NoteSchema = zom.Schema(Note, "notes", .id, .{
    .plugins = .{zom.plugins.timestamps(.{})},
});

export fn entry() void {
    _ = NoteSchema;
}
