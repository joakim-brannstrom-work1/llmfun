# Storage Engine Design

## Introduction
This document describes the custom append-only storage engine used by the audit
log service. It is not related to the authentication subsystem except that both
were written by the same team.

## File format
Each segment file contains a header, a series of records, and a footer. Records
are length-prefixed with a variable-length integer. The writer appends records
and never mutates them, which makes crash recovery trivial: on restart the
reader scans forward until it finds a corrupt record and truncates the tail.

## Index structures
Every segment carries a sparse index mapping record keys to file offsets. The
index is rebuilt lazily on first read after a reopen. For point lookups the
engine consults a per-segment bloom filter before touching the index.

### Bloom filters
The bloom filter false-positive target is 0.1 percent; with a 10 bits-per-key
budget this gives a load factor of 0.62 before automatic resizing. Filter
parameters are stored in the segment header.

## Compaction
Compaction merges small segments into larger ones and drops tombstones.
Compaction runs in the background with a fixed write budget of 32 MB per second
so it never starves foreground traffic.

## Retention
Segments older than the retention window are sealed and deleted after a grace
period of 7 days. The retention window defaults to 90 days and is configurable
per audit stream.

## Failure modes
- Torn writes are detected via per-record CRCs.
- The engine refuses to start if the manifest is missing; an explicit recovery
  flag can rebuild it from the segments.
- Disk full: the writer blocks until space is available or the grace timeout
  expires, then returns an error to the caller.
