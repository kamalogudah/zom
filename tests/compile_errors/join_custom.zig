// expect: zom: `join(.conversation)` on relation 'people': 'conversation' is a custom association, which has no foreign key to join on; use `combine(.conversation, ...)` to load its rows
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
    _ = people.join(.conversation);
}
