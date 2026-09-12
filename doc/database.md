# Design of Best Match
This describes the algorithm for best match used in the database.

FTS5 is a text search algorithm while sqlite-vec is a semantic search. Both have their pro/con. By combining them the result is hopefully better. If there is an exact match then FTS5 find it but also high ranking semantic matches are part of the top-K result. To combine them and avoid e.g. duplication Reciprocal Rank Fusion (RRF) is used.

| Feature           | sqlite-vec (Semantic)                                 | FTS5 (Full-Text Search)                       |
| ----------------- | ----------------------------------------------------- | --------------------------------------------- |
| Goal              | Find concepts and meaning                             | Match exact keywords and phrases              |
| Best for Queries  | Paraphrasing, fuzzy language, cross-lingual queries   | Product codes, names, dates, specific jargon  |
| Explainability	| Low (a "black box" result)	                         | High (based on term frequency)                |
| Query Syntax	    | A vector (numerical list)	                           | Boolean operators, wildcards, etc. (see [FTS5 Query Syntax](#fts5-query-syntax)) |
| Performance	    | Fast on GPUs; can be slow with brute-force	        | Very fast for keyword lookup                  |
| Maturity	        | Relatively new, community effort is active	        | Mature, built-in, and stable                  |

# How the RRF Formula Works

The core idea:
A document's final score = weighted sum of its reciprocal ranks from each engine.

Formula:
```
score(doc) = vec_weight / (k + rank_vec(doc)) + fts_weight / (k + rank_fts(doc))
```

- `rank_vec(doc)` = the position of the document in the vector search results (1 = best, i.e. smallest embedding distance).
- `rank_fts(doc)` = the position of the document in the FTS results (1 = best, i.e. the most negative BM25 rank).
- `vec_weight` / `fts_weight` weight the two engines differently.
- A missing rank (the document is absent from one engine) is replaced by the placeholder 1000 via `coalesce` (see below).

The constants live in `database.d` and are bound into the SQL as `:rrf_k`, `:vec_weight`, `:fts_weight`, `:limit`:

| Constant             | Value | Effect |
| -------------------- | ----- | ------ |
| `RrfK` (k)           | 10    | Sharpens rank sensitivity: rank 1 scores ~36% higher than rank 5 (1/11 vs 1/15), so the top of each engine's list dominates its tail. |
| `VecWeight`          | 1.0   | Baseline weight for vector hits. |
| `FtsWeight`          | 2.0   | An FTS hit counts double a vector hit at the same rank. There are almost always fewer FTS matches, and when they match they are better (exact keywords). |
| `RrfPoolMultiplier`  | 10    | Each engine's candidate pool is topK x 10, not topK. |

Why the pool is topK x 10: for the fusion to work, both engines must contribute deep enough lists. If the FTS pool were only topK, an exact keyword match ranked just below topK in FTS would never enter the fusion while weaker semantic neighbours would — a bias toward semantic-only results. A 10x pool keeps exact FTS matches in the race; the final result is still truncated to topK.

Why the weighting also reduces noise: with k = 10 and FTS weighted double, a weak vector match (low similarity, deep in the vector list) contributes almost nothing to the fusion score, while any genuine FTS hit outweighs it. Low-similarity semantic noise therefore drops out of the top-K instead of diluting the results.

Documents that appear high in both lists get the largest scores. A document matching neither engine is excluded entirely (a trailing `WHERE` requires at least one engine match), so a chunk can never score positively on placeholder ranks alone.

# The Role of coalesce (Handling Missing Documents)

When the two match sets are LEFT JOINed, a document might exist in one but not the other. In SQL, the missing `rank_number` becomes NULL.

The `coalesce(rank_number, 1000)` replaces that NULL with a large placeholder value (here 1000).

Why 1000? Because with k = 10:

- 1 / (10 + 1000) ≈ 0.00099 – a very small contribution.
- This essentially penalises documents that don't appear in one engine, but it doesn't exclude them entirely.
- A document that is rank 1 in vector search but completely missing from FTS will still get a reasonable score:
    `1.0/(10+1) + 2.0/(10+1000) ≈ 0.0909 + 0.0020 = 0.0929`.
    This ensures it can still appear in the final results, especially if it's a top result in one engine.
- The mirror case (rank 1 in FTS, missing from vector) scores `1.0/(10+1000) + 2.0/(10+1) ≈ 0.0010 + 0.1818 = 0.1828` — roughly twice the vector-only score, which is the FTS-over-semantic weighting made visible.

Without coalesce, the NULL would make the entire expression NULL, and the row would be dropped or sorted unpredictably. The placeholder effectively says: "Treat missing as very low relevance, but keep it in the race."

# Why RRF is Better Than “Half the Results from Each”

Taking, say, LIMIT/2 from vector and LIMIT/2 from FTS (then stacking or interleaving) has major flaws:

- Overlap is ignored – The same document could appear in both halves, wasting slots on duplicates while missing other high-quality results.
    - RRF starts with the full candidate pool from both engines (topK x 10), then de-duplicates and re-ranks. No slot is wasted.
- Arbitrary cutoff discards strong candidates – A document ranked 11th in vector search (just below the halfway line) might be 1st in FTS. A LIMIT/2 would drop it from the vector set entirely, and you'd never know it's an excellent hybrid match.
    - RRF considers all retrieved documents. Even if it's rank 50 in one list, its combined rank can push it to the top.
- No score normalization – Vector distances and FTS BM25 scores are on completely different scales. Simple mixing doesn't produce a meaningful unified ranking.
    - RRF only uses ordinal ranks, not raw scores. Ranks are unitless and directly comparable, making fusion trivial and robust.
- Engine strength varies – For a query, vector might be excellent and FTS poor (or vice versa). A rigid 50/50 split forces a balance that might be wrong.
    - RRF automatically lets the stronger engine's top results dominate, because they'll get higher reciprocal weights.

Example (k = 10, weights 1.0 vector / 2.0 FTS):

- Document A: Rank 1 in vector, Rank 50 in FTS.
- Document B: Rank 6 in vector, Rank 6 in FTS.

A LIMIT/2 approach that takes top 5 from each would discard Document A from FTS (since it's rank 50) and might still include it from vector. But it misses the fact that A is excellent overall.
RRF score for A: 1.0/(10+1) + 2.0/(10+50) ≈ 0.0909 + 0.0333 = 0.1242
RRF score for B: 1.0/(10+6) + 2.0/(10+6) ≈ 0.0625 + 0.1250 = 0.1875
B ends up ranked higher, which is sensible because it's strong in both engines. A would still appear high enough, though, because its vector rank is stellar.

# Why This Specific Algorithm (RRF)

- No training required – works out of the box, even when engines are completely different (BM25 vs. vector cosine).
- Simple SQL implementation – the formula is just arithmetic; no complex machine learning.
- Robust – handles missing documents gracefully via the coalesce placeholder.
- Two tuning knobs:
    - k (currently 10) controls rank sharpness: lower k makes top ranks more dominant; higher k flattens the influence. 10 is deliberately sharp so that being rank 1 matters (~36% more than rank 5).
    - The per-engine weights (currently FTS 2.0 vs vector 1.0) encode the observation that FTS matches are rarer and more precise, so an exact keyword hit should outweigh an equally-ranked semantic hit.

In short, RRF is a fair, data‑driven way to marry the precision of keyword search with the semantic intuition of vector search, without throwing away information or forcing an arbitrary split.

# Shuffle-Based Rank Randomization (Deterministic)

After collecting results from the database queries, `randomizeRanks()` is applied to the result array before sorting by rank and truncating to top-K. This eliminates database-order bias: without shuffling, results with identical ranks would always be taken from whichever database returned them first.

How it works:
1. The raw result array from the database is duplicated.
2. A Fisher-Yates shuffle randomizes the copy, using a `Random` seeded with the content hash of the query (`computeContentHash(query)`).
3. The shuffled copy is sorted by rank (stable sort) and then truncated to top-K via the per-database interleaving described below.
4. The original array is never mutated.

The shuffle is **deterministic per query**: the same query always produces the same permutation, so repeated identical queries return identical results. That matters because the agent loop is told the same query gives the same result — a non-deterministic top-K at the boundary would make the agent conclude the database is unstable. Different queries get different seeds, so the database-order bias is still broken across the whole search space.

# Rank Semantics (What "rank" Means Per Engine)

The three query paths use different rank scales. `rag.d` sorts accordingly before truncation:

| Query path       | rank value                                            | Better is   | Sort in `rag.d` |
| ---------------- | ----------------------------------------------------- | ----------- | --------------- |
| `querySemantic`  | `row_number()` ordered by embedding distance (1 = closest) | lower  | ascending       |
| `queryTextSearch`| FTS5 `rank` column (BM25)                             | more negative | ascending     |
| `queryBestMatch` | RRF `fusion_score`                                    | higher      | descending      |

# Multi-Database Parallel Query

The RAG system supports multiple databases. When the `database` parameter is `"*"`, all registered databases are queried in parallel (`std.parallelism`, thread-safe SQL via `spinSql`). The per-database results are then merged:

1. Shuffled with `randomizeRanks(query)` (deterministic per query, see above).
2. Stable-sorted by rank.
3. Truncated to top-K with `takePerSource()`: a round-robin that picks at most `MaxFromSource` (2) matches per database per pass, so the result interleaves each database's best, next best, ... instead of letting a single database sweep the whole top-K when several databases have results.
4. Each result carries a `databaseName` field indicating which database it came from.

`takePerSource` is NOT strict global rank order: a database that has already contributed 2 matches in a pass is skipped for the rest of that pass, so a slightly lower-ranked match from another database can precede it. The trade-off is deliberate — coverage across databases beats perfect global ordering at the top-K boundary. (A single database can still provide the entire top-K if it is the only one with matches.)

For single-database queries (by name), only that database is searched and the merge degenerates to shuffle + stable sort + top-K.

# FTS5 Query Syntax

`queryTextSearch` and the FTS half of `queryBestMatch` pass the text query to SQLite FTS5 (unicode61 tokenizer). The supported grammar, as documented in `fts5Help` and verified against the vendored SQLite 3.53.1:

- Whitespace between terms is an **implicit AND** (highest precedence).
- Boolean operators (uppercase): `AND`, `OR`, `NOT`. Precedence, highest to lowest: implicit AND > NOT > AND > OR.
- `NOT` is **binary only**: `x NOT y`. `x AND NOT y` is a syntax error.
- Grouping with `( )`. A bare term after a closing paren is a syntax error — write `(a OR b) AND c`, not `(a OR b) c`.
- Prefix terms: `term*` (keep `*` outside any quotes).
- Start-of-column: `^term`.
- Proximity: `NEAR(term1 term2, N)` — the comma before the count is required.
- Anything that is not alphanumeric/underscore/`(`/`)`/`*`/`^` is auto-quoted as a literal by `cleanFts5`.
- Column filters (`colname:` or `{col1 col2}:`) are NOT supported and will error.

Valid examples:
```
test AND code
(test OR unittest) NOT python
NEAR(code block, 3)
^header AND body*
```

# Fallback Behavior

`queryBestMatch` requires a valid embedding vector for the combined semantic + text search. If the embedding service fails (HTTP error) or returns an empty vector, the function falls back to `queryTextSearch` with the text query alone. This ensures that a search failure in the embedding layer does not result in zero results.

The fallback chain is:
1. Attempt combined semantic + text search (RRF) using `queryCombineSemanticText`.
2. If embedding is empty or fails → fall back to FTS5 text search only.
