// expect: zom.Schema("notes"): plugin `plugin_no_hooks.Typo` declares none of the plugin hooks (validate, beforeCreate, beforeUpdate)
const zom = @import("zom");

const Typo = struct {
    pub fn beforecreate() void {}
};
const Note = struct { id: u32 };
const NoteSchema = zom.Schema(Note, "notes", .id, .{ .plugins = .{Typo} });

export fn entry() void {
    _ = NoteSchema;
}
