//! zom-sql = rom's `rom-sql`, minus the driver: compiles a relation's query
//! into a parameterized `SELECT`, and inserts, updates and deletes into
//! `INSERT`, `UPDATE` and `DELETE`, for a `Dialect`. A gateway such as
//! zom-pg pairs it with a driver: compile, bind `params`, decode rows.
//!
//!     const compiled = try zom_sql.compileRelation(.postgres, allocator, users.where(.age, .gte, 18));
//!     defer compiled.deinit(allocator);
//!     // compiled.sql: SELECT "id", ... FROM "users" WHERE "age" >= $1

pub const Dialect = @import("dialect.zig").Dialect;

const compile = @import("compile.zig");
pub const Compiled = compile.Compiled;
pub const CompileError = compile.CompileError;
pub const RenderError = compile.RenderError;
pub const Params = compile.Params;
pub const compileSelect = compile.compileSelect;
pub const compileProjected = compile.compileProjected;
pub const compileRelation = compile.compileRelation;
pub const writeSelect = compile.writeSelect;
pub const WriteError = compile.WriteError;
pub const WriteRenderError = compile.WriteRenderError;
pub const Batch = compile.Batch;
pub const rowsPerStatement = compile.rowsPerStatement;
pub const compileInsert = compile.compileInsert;
pub const compileInsertMany = compile.compileInsertMany;
pub const compileUpdate = compile.compileUpdate;
pub const compileDelete = compile.compileDelete;
pub const writeInsert = compile.writeInsert;
pub const writeUpdate = compile.writeUpdate;
pub const writeDelete = compile.writeDelete;
pub const writeIdent = compile.writeIdent;

/// Zig schema source from a database catalog; see infer.zig.
pub const infer = @import("infer.zig");

test {
    _ = compile;
    _ = @import("compile_test.zig");
    _ = @import("write_test.zig");
    _ = @import("join_test.zig");
    _ = infer;
    _ = @import("infer_test.zig");
}
