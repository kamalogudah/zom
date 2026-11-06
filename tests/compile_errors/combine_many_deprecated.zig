// expect: zom.combineMany is deprecated: use relation.combine(.assoc, target).mapTo(E, allocator) (built with -Dno-deprecated)
const zom = @import("zom");

const Post = struct { id: u32, user_id: u32 };
const Author = struct { id: u32, posts: []const Post = &.{} };

export fn entry() void {
    var authors = [_]Author{.{ .id = 1 }};
    const posts = [_]Post{.{ .id = 10, .user_id = 1 }};
    zom.combineMany(.{ .into = "posts", .parent_key = "id", .child_key = "user_id" }, undefined, &authors, &posts) catch {};
}
