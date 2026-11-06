// expect: zom: `associate(.sender, ...)` on relation 'messages': 'sender' is a custom association, which has no foreign key to set
const zom = @import("zom");

const Person = struct { id: u32, name: []const u8 };
const Message = struct { id: u32, sender_id: u32, recipient_id: u32 };
const PersonSchema = zom.Schema(Person, "people", .id, .{});
const MessageSchema = zom.Schema(Message, "messages", .id, .{
    .associations = struct {
        pub const sender = zom.customAssociation(PersonSchema, .sender, .one);
    },
});

export fn entry() void {
    var gw = zom.memory.Gateway.init(@import("std").heap.page_allocator, .{});
    const messages = zom.Relation(MessageSchema, zom.memory.Gateway).init(&gw) catch return;
    _ = messages.associate(.sender, Person{ .id = 1, .name = "Achieng" });
}
