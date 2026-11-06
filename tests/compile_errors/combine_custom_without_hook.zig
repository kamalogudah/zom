// expect: zom.combine(.conversation) on relation 'people': 'conversation' is a custom association (`.both_sides`), which the dataset of "messages" must load, but adapter 'memory' declares no `loadAssociation` on it
//! A custom association has no foreign key for the generic `in` query, so
//! only a dataset with `loadAssociation` can combine it.
const zom = @import("zom");

const Person = struct { id: u32, name: []const u8 };
const Message = struct { id: u32, sender_id: u32, recipient_id: u32 };
const PersonSchema = zom.Schema(Person, "people", .id, .{
    .associations = struct {
        pub const conversation = zom.customAssociation(MessageSchema, .both_sides, .many);
    },
});
const MessageSchema = zom.Schema(Message, "messages", .id, .{});

export fn entry() void {
    var gw = zom.memory.Gateway.init(@import("std").heap.page_allocator, .{});
    const people = zom.Relation(PersonSchema, zom.memory.Gateway).init(&gw) catch return;
    const messages = zom.Relation(MessageSchema, zom.memory.Gateway).init(&gw) catch return;
    _ = people.combine(.conversation, messages);
}
