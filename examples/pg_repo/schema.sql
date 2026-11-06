-- The tables for examples/pg_repo. zom has no migrations: apply this once,
--
--   psql "$DATABASE_URL" -f schema.sql
--
-- and the program checks the tables against its schema structs at startup
-- (`Gateway.verify`). A Zig `u32` needs `bigint`: `integer` stops at 2^31-1.

CREATE TABLE IF NOT EXISTS users (
    id         bigint PRIMARY KEY,
    name       text   NOT NULL,
    email      text   NOT NULL UNIQUE,
    deleted_at bigint              -- ?i64: null while the account is active
);

CREATE TABLE IF NOT EXISTS posts (
    id      bigint PRIMARY KEY,
    user_id bigint NOT NULL REFERENCES users (id),
    title   text   NOT NULL
);
