# Multi-Writer S3 Plain Rewritable: Design Document

## Problem Statement

The current `s3_plain_rewritable` disk in ClickHouse supports only a **single writer** with multiple readers. It uses in-process `metadata_mutex` and `load_mutex` to coordinate access to an in-memory directory tree. This means:

- Only one ClickHouse server instance can write to the disk
- No distributed merges — a single node must perform all compaction
- No distributed GC — orphaned data accumulates if the writer fails

We want to extend this to support **multiple concurrent writers** (multiple ClickHouse nodes), **distributed merges**, and **distributed garbage collection**, all backed by the same shared S3 bucket.

## Current Architecture Summary

### How S3 Plain Rewritable Works Today

**Physical layout in S3:**
```
s3://bucket/data/__meta/{random-token}/prefix.path    → contains logical path (e.g., "/store/xxx/table/all_1_1_0/")
s3://bucket/data/{random-token}/columns.txt            → actual data file
s3://bucket/data/{random-token}/primary.idx             → actual data file
s3://bucket/data/__root/file.txt                        → root-level files
```

**Key design properties:**
- Each logical directory gets a random 32-char ASCII token at creation time
- `prefix.path` files in `__meta/` map random tokens → logical paths
- Directory renames only rewrite `prefix.path` (not physical files) — atomic rename
- In-memory `InMemoryDirectoryTree` caches the full directory structure
- ETag-based incremental refresh detects remote changes

**Current coordination (single-process only):**
- `metadata_mutex` — guards in-memory tree during transaction commits
- `load_mutex` — guards metadata reload from S3
- `MetadataOperationsHolder` — batches operations, executes under lock, rolls back on failure
- No cross-process coordination whatsoever

### Existing Building Blocks in ClickHouse

| Component | Location | Relevance |
|-----------|----------|-----------|
| S3 conditional writes (`If-None-Match`, `If-Match`) | `src/IO/WriteSettings.h:36-37`, `src/IO/WriteBufferFromS3.cpp:639-720` | Can use S3 as a conflict-free metastore |
| Azure conditional writes (`IfNoneMatch`) | `src/Disks/IO/WriteBufferFromAzureBlobStorage.cpp:192-336` | Same pattern for Azure |
| ZeroCopyLock (Keeper ephemeral locks) | `src/Storages/MergeTree/ZeroCopyLock.h` | Part-level locking in shared storage |
| ReplicatedMergeTree queue | `src/Storages/MergeTree/ReplicatedMergeTreeQueue.h` | Full distributed part lifecycle |
| Merge predicates | `src/Storages/MergeTree/Compaction/MergePredicates/ReplicatedMergeTreeMergePredicate.h` | Two-level predicate (local cache + Keeper) |
| Merge strategy picker | `src/Storages/MergeTree/ReplicatedMergeTreeMergeStrategyPicker.h` | Single-replica merge execution |
| Ephemeral locks for block numbers | `src/Storages/MergeTree/EphemeralLockInZooKeeper.h` | Block number allocation |
| Cleanup thread | `src/Storages/MergeTree/ReplicatedMergeTreeCleanupThread.h` | Leader-based GC |
| Leader election | `src/Storages/MergeTree/LeaderElection.h` | Multi-leader mode |

---

## Design: Two Approaches

There are two viable approaches, depending on whether you want to depend on Keeper (ZooKeeper) or keep coordination entirely on S3.

---

## Approach A: Keeper-Coordinated (Recommended)

This approach reuses ClickHouse's existing `ReplicatedMergeTree` coordination machinery, adapted for a shared-nothing S3 storage where all replicas read/write the same physical data (similar to zero-copy replication, but inherent).

### A.1 Architecture Overview

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│  Writer 1   │  │  Writer 2   │  │  Writer 3   │
│  (CH Node)  │  │  (CH Node)  │  │  (CH Node)  │
└──────┬──────┘  └──────┬──────┘  └──────┬──────┘
       │                │                │
       ▼                ▼                ▼
┌─────────────────────────────────────────────────┐
│              ClickHouse Keeper                   │
│  /parts/{part_name} → {node_id, state, etag}    │
│  /log/{seq} → {action, part, source_parts}      │
│  /merges/{part_name} → {assigned_node, status}  │
│  /blocks/{hash} → deduplication                 │
│  /gc/pending/{part} → tombstones                │
└─────────────────────────────────────────────────┘
       │                │                │
       ▼                ▼                ▼
┌─────────────────────────────────────────────────┐
│                    S3 Bucket                     │
│  /__meta/{token}/prefix.path → logical path     │
│  /{token}/columns.txt, primary.idx, ...         │
└─────────────────────────────────────────────────┘
```

### A.2 Part Registry in Keeper

Create a Keeper node structure per table:

```
/clickhouse/tables/{shard}/{table}/
  /parts/
    all_1_1_0 → {"node": "node1", "s3_token": "abc123", "etag": "...", "state": "active"}
    all_2_2_0 → {"node": "node2", "s3_token": "def456", "etag": "...", "state": "active"}
    all_1_2_1 → {"node": "node1", "s3_token": "ghi789", "etag": "...", "state": "active"}
  /log/
    log-0000000001 → {"type": "NEW_PART", "part": "all_1_1_0", "node": "node1"}
    log-0000000002 → {"type": "NEW_PART", "part": "all_2_2_0", "node": "node2"}
    log-0000000003 → {"type": "MERGE", "result": "all_1_2_1", "sources": ["all_1_1_0", "all_2_2_0"]}
  /merges/
    all_1_2_1 → {"assigned_to": "node1", "status": "in_progress"}
  /blocks/
    {insert_hash} → "all_1_1_0"  (deduplication)
  /gc/
    /tombstones/
      all_1_1_0 → {"tombstoned_at": 1708000000, "s3_token": "abc123"}
```

### A.3 Multi-Writer Insert Flow

```
Writer N wants to insert data:

1. Allocate block number via ephemeral lock in Keeper
   (reuse EphemeralLockInZooKeeper pattern)

2. Generate random S3 directory token (existing: getRandomASCIIString(32))

3. Write data files to S3:
   s3://bucket/{token}/columns.txt
   s3://bucket/{token}/primary.idx
   s3://bucket/{token}/checksums.txt
   ...

4. Write metadata to S3:
   s3://bucket/__meta/{token}/prefix.path
   (Use If-None-Match: * to ensure no conflict — CAS on creation)

5. Register part in Keeper atomically (multi-op):
   - Create /parts/{part_name} with metadata
   - Create /log/{next_seq} with NEW_PART entry
   - Remove ephemeral block number lock
   - Create /blocks/{hash} for deduplication

6. On conflict (Keeper tells us part already exists):
   - Delete orphaned S3 objects
   - Retry with new block number
```

**Why this is safe:** Step 4's `If-None-Match: *` prevents two writers from accidentally using the same random token (astronomically unlikely but defensive). Step 5's Keeper multi-op provides the true serialization point — if two nodes try to register overlapping parts, only one succeeds.

### A.4 Distributed Merge Scheduling

Reuse ClickHouse's existing `ReplicatedMergeTreeMergeStrategyPicker` pattern:

```
Merge Coordinator (any node, via leader election or multi-leader):

1. Evaluate merge predicates:
   - ReplicatedMergeTreeLocalMergePredicate (cached, fast)
   - ReplicatedMergeTreeZooKeeperMergePredicate (authoritative)

2. Select parts to merge (existing SimpleMergeSelector / TTLMergeSelector)

3. Create merge assignment in Keeper:
   /merges/{result_part} → {"assigned_to": "node2", "sources": [...]}
   /log/{next_seq} → MERGE_PARTS entry

Merge Executor (assigned node):

4. Read source parts from S3 (all nodes see the same data)

5. Execute merge locally (MergeTask)

6. Write merged result to new S3 directory token

7. Register merged part in Keeper (multi-op):
   - Create /parts/{merged_part}
   - Mark source parts for GC in /gc/tombstones/
   - Update /log with completion
   - Remove /merges/{result_part}

8. All other nodes:
   - Pull log entries
   - Update in-memory tree (add merged part, mark source parts inactive)
   - NO data fetch needed (shared S3 — zero-copy by nature)
```

**Key insight:** Unlike traditional ReplicatedMergeTree where each replica stores its own copy, here ALL nodes already see the merged result in S3. The log entry simply tells them to update their in-memory metadata. This is inherently "zero-copy" — no data transfer between replicas.

### A.5 In-Memory Metadata Synchronization

Each node maintains its `InMemoryDirectoryTree` but must now handle external changes:

```
Enhanced refresh() flow:

1. Pull new log entries from Keeper (watch-based, low latency)

2. For each log entry:
   - NEW_PART: Add to in-memory tree (read prefix.path from S3 if needed)
   - MERGE_PARTS: Add merged part, remove source parts from active set
   - DROP_PART: Remove from active set, add to GC tombstones
   - MUTATE_PART: Replace part in active set

3. ETag-based S3 refresh (existing) as fallback consistency check

4. Consistency invariant:
   virtual_parts = current_parts + pending_queue_entries
   (Same invariant as ReplicatedMergeTreeQueue)
```

### A.6 Distributed Garbage Collection

```
GC Leader (elected via Keeper):

1. Scan /gc/tombstones/ for parts older than retention period

2. For each tombstoned part:
   a. Verify no active references (no node lists it in active parts)
   b. Acquire ZeroCopyLock on the part (prevent concurrent reads during delete)
   c. Delete S3 objects:
      - s3://bucket/{token}/* (data files)
      - s3://bucket/__meta/{token}/prefix.path (metadata)
   d. Remove tombstone from Keeper

3. Orphan detection (periodic):
   - List all tokens in S3 __meta/
   - Compare with registered parts in Keeper
   - Tokens not in Keeper AND older than safety window → orphaned
   - Clean up orphaned tokens
```

### A.7 Failure Handling

| Failure | Recovery |
|---------|----------|
| Writer crashes mid-insert (before Keeper registration) | Orphan GC cleans up unregistered S3 tokens |
| Writer crashes mid-insert (after S3 write, before Keeper) | Same — orphan GC |
| Merge executor crashes mid-merge | Other node picks up merge from /merges/ after timeout |
| GC leader crashes | New leader elected, resumes from tombstones |
| Network partition (node can't reach Keeper) | Node goes read-only until reconnected |
| S3 conditional write conflict | Retry with exponential backoff (extremely rare with random tokens) |

### A.8 Changes Required

| Area | What Changes | Complexity |
|------|-------------|------------|
| `MetadataStorageFromPlainRewritableObjectStorage` | Add Keeper-based coordination alongside in-memory tree | High |
| New: `PlainRewritableKeeperCoordinator` class | Manages Keeper nodes, log pulling, merge scheduling | High |
| `MetadataStorageFromPlainRewritableObjectStorageOperations` | Operations must register in Keeper after S3 writes | Medium |
| New: `PlainRewritableGCThread` | Background GC with leader election | Medium |
| `DiskObjectStorage` / `RegisterDiskObjectStorage` | Config for multi-writer mode (keeper_path, replica identity) | Low |
| `InMemoryDirectoryTree` | Must handle concurrent external modifications (CAS-based updates) | Medium |
| `WriteSettings` | Plumbing to enable `If-None-Match` for metadata writes | Low (already exists) |

---

## Approach B: S3-Only (Keeper-Free)

If you want to avoid Keeper dependency entirely, S3 conditional writes (`If-None-Match`, `If-Match` on ETags) can serve as the coordination primitive. This is simpler but has limitations.

### B.1 Architecture

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│  Writer 1   │  │  Writer 2   │  │  Writer 3   │
└──────┬──────┘  └──────┬──────┘  └──────┬──────┘
       │                │                │
       ▼                ▼                ▼
┌─────────────────────────────────────────────────┐
│                    S3 Bucket                     │
│  /__meta/{token}/prefix.path                    │
│  /__registry/parts.json  (conditional writes)    │
│  /__registry/merges.json (conditional writes)    │
│  /__registry/gc.json     (conditional writes)    │
│  /{token}/data files...                          │
└─────────────────────────────────────────────────┘
```

### B.2 S3 as Metastore via Conditional Writes

Use a central `parts.json` (or partitioned files) with ETag-based CAS:

```
Insert flow:

1. Write data files to S3 (same as today)

2. Read current /__registry/parts.json, note its ETag

3. Append new part entry to the JSON

4. Write back with If-Match: {etag}
   - Success → part registered
   - 412 Precondition Failed → another writer modified it
   - On conflict: re-read, re-merge, retry (optimistic concurrency)
```

### B.3 Limitations of S3-Only

| Concern | Issue |
|---------|-------|
| **No watches/notifications** | Must poll S3 for changes (higher latency, more LIST calls) |
| **No ephemeral nodes** | Can't detect node failures automatically; need lease-based TTLs |
| **CAS contention** | Single `parts.json` becomes a bottleneck under high write rates |
| **No distributed locking** | Must implement lock-free or lease-based merge assignment |
| **Merge assignment** | Harder to coordinate who does which merge without leader election |
| **Consistency** | S3 is eventually consistent for some operations (list-after-write) |
| **Registry size** | `parts.json` grows unbounded; need compaction/partitioning strategy |

### B.4 Mitigation: Partitioned Registry

Instead of a single `parts.json`, partition by:
```
/__registry/partitions/{partition_id}/parts.json
/__registry/merges/{partition_id}/active.json
/__registry/gc/{partition_id}/tombstones.json
```

This reduces CAS contention but adds complexity.

---

## Recommendation: Approach A (Keeper-Coordinated)

**Why Keeper over S3-only:**

1. **Battle-tested patterns** — ReplicatedMergeTree already proves Keeper works for exactly this use case. We can reuse 80% of the coordination logic.

2. **Low-latency watches** — Keeper watches notify nodes of new parts/merges in milliseconds, vs. polling S3 every N seconds.

3. **Ephemeral nodes** — Automatic failure detection. If a merge executor dies, its ephemeral lock disappears and another node takes over.

4. **Atomic multi-operations** — Keeper's multi-op ensures part registration + log entry + deduplication block happen atomically.

5. **Existing infrastructure** — Most ClickHouse deployments with replication already run Keeper.

6. **Inherent zero-copy** — Since all nodes share the same S3 data, we get zero-copy replication for free. No data fetching between replicas — just metadata propagation through Keeper.

**When S3-only might make sense:**
- Serverless/ephemeral compute with no persistent Keeper
- Cost-sensitive deployments wanting to avoid Keeper infrastructure
- Very low write throughput where CAS contention isn't an issue

---

## Implementation Phases

### Phase 1: Foundation (Multi-Writer Inserts)
- [ ] Create `PlainRewritableKeeperCoordinator` class
- [ ] Keeper node structure for part registry and log
- [ ] Block number allocation via ephemeral locks
- [ ] Insert deduplication
- [ ] Use `If-None-Match: *` for S3 metadata writes
- [ ] Log-based metadata sync across nodes
- [ ] Config: `keeper_path`, `replica_name` in disk config

### Phase 2: Distributed Merges
- [ ] Merge predicate adapted for shared-S3 (inherently zero-copy)
- [ ] Merge assignment via Keeper (adapt `ReplicatedMergeTreeMergeStrategyPicker`)
- [ ] Merge execution writes to new S3 tokens
- [ ] Merge completion registered in Keeper
- [ ] Merge failover on executor death

### Phase 3: Distributed GC
- [ ] Part tombstoning in Keeper
- [ ] Leader-elected GC thread
- [ ] S3 orphan detection and cleanup
- [ ] Safety windows to prevent deleting parts being read

### Phase 4: Production Hardening
- [ ] Metrics and monitoring
- [ ] Graceful degradation (read-only mode on Keeper disconnect)
- [ ] Migration path from single-writer to multi-writer
- [ ] Integration tests with multiple CH nodes
- [ ] Chaos testing (network partitions, node failures)
