//! zom: a Ruby Object Mapper (rom-rb) style data mapping toolkit for Zig.
//!
//! Layers, mirroring ROM:
//!   Gateway / Dataset  -> adapters (memory here; zom-csv, zom-yaml, zom-sql in adapters/)
//!   Schema             -> tuple struct + dataset name + primary key
//!   Relation           -> immutable, chainable query over a dataset
//!   Changeset          -> create / update data, committed explicitly
//!   Mapper / combine   -> tuples to domain structs, nested associations

const std = @import("std");

pub const query = @import("query.zig");
pub const Op = query.Op;
pub const Direction = query.Direction;
pub const Value = query.Value;
pub const Query = query.Query;
/// Boolean groups for `whereAny` / `whereNot`; see `query.any`.
pub const any = query.any;
pub const all = query.all;
pub const not = query.not;

pub const Schema = @import("schema.zig").Schema;
pub const Relation = @import("relation.zig").Relation;
/// A relation whose reads return `Output`; see `Relation.select`.
pub const RelationOf = @import("relation.zig").RelationOf;
/// The relation type with every parameter: `RelationWith(S, G, Output, mode)`.
pub const RelationWith = @import("relation.zig").RelationWith;
/// `.strict` or `.fallback`: what a relation does with query features its
/// adapter does not support. See `Relation.allowFallback`.
pub const Mode = @import("relation.zig").Mode;
/// What a `.fallback` read that ran in memory reports to its scan hook.
pub const Scan = @import("relation.zig").Scan;
pub const ScanHook = @import("relation.zig").ScanHook;
/// The narrower struct `select` reads into: `Project(User, .{ .id, .name })`.
pub const Project = @import("projection.zig").Project;

pub const adapter = @import("adapter.zig");
pub const Adapter = adapter.Adapter;
pub const Capability = adapter.Capability;
pub const Capabilities = adapter.Capabilities;
pub const Supports = adapter.Supports;

pub const changeset = @import("changeset.zig");

pub const Container = @import("container.zig").Container;

pub const lint = @import("lint.zig");

pub const mapper = @import("mapper.zig");
pub const Mapper = mapper.Mapper;
pub const combineMany = mapper.combineMany;

pub const codec = @import("codec.zig");

pub const memory = @import("adapters/memory.zig");
pub const file = @import("file.zig");

test {
    _ = @import("tests/adapter_test.zig");
    _ = @import("tests/relation_test.zig");
    _ = @import("tests/changeset_test.zig");
    _ = @import("tests/container_test.zig");
    _ = @import("tests/mapper_test.zig");
    _ = @import("tests/memory_test.zig");
    _ = @import("tests/store_test.zig");
    _ = @import("tests/lint_test.zig");
    _ = @import("tests/codec_test.zig");
    _ = file;
    _ = @import("tests/query_test.zig");
    _ = @import("tests/projection_test.zig");
    _ = @import("tests/fallback_test.zig");
}
