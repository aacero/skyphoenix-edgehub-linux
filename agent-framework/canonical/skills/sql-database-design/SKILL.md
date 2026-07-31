---
name: sql-database-design
description: Design and review relational database schemas — normalization, keys, constraints, indexing, transactions, and migration safety. Use when creating or changing tables, keys, indexes, or migrations, or reviewing a relational data model for integrity and evolvability.
license: Proprietary
metadata:
  status: complete
  kind: domain
  last-reviewed: "2026-07-18"
---

# SQL Database Design

## Trigger

Load this skill when the task involves: designing a new relational schema; adding/altering tables, columns, keys, constraints, or indexes; writing or reviewing schema migrations; reviewing a data model for integrity, redundancy, or query-performance risks.

## Scope

Vendor-neutral relational design: normalization, key selection, constraints, data types, indexing strategy, transactional integrity, and safe schema evolution. Grounded in long-stable relational theory (Codd's normal forms) and the ISO/IEC 9075 SQL standard family; vendor specifics are deferred to the vendor's own documentation.

## Non-goals

- Vendor-specific tuning (planner hints, storage engines, partitioning syntax) — consult the vendor docs for the exact engine and version.
- NoSQL/document/graph modeling, ORM API usage, and database operations (backup, replication topology).

## Official-source policy

Consult official documentation before relying on this file, and prefer current official docs over this file wherever they differ:

- ISO/IEC 9075 (SQL standard family) — normative but paywalled; use vendor conformance notes.
- PostgreSQL documentation: https://www.postgresql.org/docs/ (verified, accessed 2026-07-18; versions 14–18 supported, 18 current at access time) — a rigorous reference implementation of standard behavior.
- The customer's actual engine's official docs (MySQL, SQL Server, Oracle, SAP HANA, SQLite…) for anything type-, locking-, or index-implementation-specific.

If the role executing this skill lacks the `web` tool (only the `deep-researcher` and `market-opportunity-researcher` roles hold it), it must not cite official-source claims from memory. Instead, it requests the lookup as a deep-researcher task via the orchestrator, per `agent-framework/canonical/policies/research-policy.md`, and marks the item `UNKNOWN` until the research report returns.

## Version awareness

Identify the exact engine and major version before advising: default isolation levels, identity/serial mechanics, index types, and DDL-locking behavior differ by engine and version. Verified example: PostgreSQL supported major lines at access date were 14–18 (source above). Do not assume feature parity across engines.

## Required citations

Any engine-specific recommendation (type behavior, index type, isolation default, online-DDL capability) must cite the official documentation page for the customer's engine and version. Engine-neutral relational-theory guidance may cite this skill.

## Terminology

Verified, standard relational vocabulary: relation/table, candidate key, primary key, natural vs. surrogate key, foreign key, functional dependency, normal forms (1NF, 2NF, 3NF, BCNF), denormalization, referential integrity, `CHECK`/`UNIQUE`/`NOT NULL` constraints, transaction, ACID, isolation levels (read uncommitted, read committed, repeatable read, serializable — SQL-standard names), index selectivity, covering index, composite index, migration (forward/rollback).

## Common workflows

1. **Schema design.** Model entities and relationships; choose keys (stable, minimal; surrogate keys where natural keys are mutable or wide); normalize to 3NF/BCNF by default; denormalize only for a measured need, documented with the invariant that keeps the copies consistent.
2. **Integrity enforcement.** Push invariants into the database: `NOT NULL`, `UNIQUE`, foreign keys with deliberate `ON DELETE`/`ON UPDATE` actions, `CHECK` constraints. Application-only enforcement of critical invariants is a review finding.
3. **Type selection.** Exact numeric types for money (never binary floating point); explicit character set/collation awareness; store timestamps with time zone semantics decided and documented.
4. **Indexing.** Index to the query set: foreign-key columns used in joins, high-selectivity filter columns, composite indexes matching leftmost-prefix query patterns. Every index is a write cost — justify each.
5. **Transactions.** Identify units of work needing atomicity; choose isolation level per anomaly tolerance; keep transactions short; define a consistent lock-acquisition order to avoid deadlocks.
6. **Migration safety.** Every migration has a forward script and a rollback plan; additive changes first (add column nullable → backfill → constrain), destructive changes only after a deprecation window; test on realistic data volume; check DDL locking behavior in the engine's docs before running against production-sized tables.

## Integration boundaries

Typically sits behind application services and ORMs; feeds analytics/ETL pipelines and reporting tools; participates in backup/recovery and replication managed by operations. Schema contracts are public interfaces to every consumer — changing them follows the same contract-change rules as APIs.

## Verification checklist

- [ ] Engine and major version identified and recorded
- [ ] Every table has an explicit primary key; key choice justified
- [ ] Normal form stated; each denormalization documented with its consistency mechanism
- [ ] Critical invariants enforced by constraints in the schema, not only in code
- [ ] Money/temporal/text types chosen deliberately and documented
- [ ] Each index mapped to a real query pattern
- [ ] Migration has tested forward path and stated rollback path
- [ ] Engine-specific claims cite official docs for the actual version

## References

See `references/SOURCES.md` in this skill's directory for official URLs and access dates.

## Last reviewed: 2026-07-18 (status: complete)
