# Knowledge Retrieval Protocol — Detailed Steps

## Phase 0: Discovery & First Pass (Call 1 — MANDATORY)

Execute these **simultaneously** in your very first turn:

1. **Call `query_best_match`** with your current objective phrased as a natural question or set of keywords. For this first query, the `textQuery` parameter should contain only one keyword — the most relevant.
2. **Call `list_rag_databases`** to discover available database names.

**Why this default?** `query_best_match` uses RRF to fuse semantic and FTS5 results. Even if your FTS5 query is poorly crafted, the semantic half will still pull in relevant content. This single call gives you a robust, balanced result set 80% of the time.

## Phase 1: The Intentional Pivot (Calls 2-4)

Read your `query_best_match` results. **Do not blindly switch tools.** Pivot *only* based on a specific diagnosis:

### Scenario A: Results are too noisy or diluted
- **Symptom**: You got many results, but the top hits are only tangentially related.
- **Action**: Re-run search **scoped to the most specific database** from Phase 0. Keep using `query_best_match` with the `database` parameter. The narrower corpus improves RRF ranking.

### Scenario B: You know a unique, exact keyword
- **Symptom**: You are certain a specific, non-generic string exists (e.g., `authenticate_user_v2`, `ERR_CONFIG_MISSING`).
- **Action**: Call `query_text_search` scoped to your discovered database. **Warning**: Only if the keyword is highly distinctive. Generic terms will return zero or thousands of hits.

### Scenario C: Objective is purely conceptual
- **Symptom**: You're asking "How does X work?" and got overly specific code snippets.
- **Action**: Call `query_semantic` scoped to your database with a broad, natural-language version of your question. This ignores keywords and searches for meaning.

### Scenario D: Zero results (rare)
- **Action**: Immediately call `query_semantic` (broad) and `query_text_search` (with your most unique noun) **in parallel** as a Hail Mary.

## Phase 2: Digging and Reading (Calls 5-8)

### Reading a referenced document (document chains)

When a result mentions another document by name — e.g. "the token format is
defined in `auth_token_spec.md`" — or the user asks for "the file X", do NOT
keep searching for that document's *content*. Resolve it and read it:

1. **`list_rag_sources`** with `filter` = the name (e.g. `auth_token_spec`) to find
   the exact indexed path.
2. **`read_rag_source`** with `filePath` = that path (a bare file name also works)
   to read the whole document in one call.

If a result header already shows the exact path, you may call `read_rag_source`
directly (1 call). The same bare-name resolution works in `query_read_file`.

### Reading specific lines

- **`query_read_file` takes a single `lineNumber`**. Read the **single most critical line** first. Surrounding context is usually visible in the search snippet.
- You can parallelize up to two `query_read_file` calls if you have two equally critical lines to verify.

## Phase 3: Verification (Calls 9-10)

- Use **Call 9** to verify a critical quoted phrase. Stick with `query_best_match` scoped to your database — RRF will catch it if it exists.
- Use **Call 10** for one final `query_read_file` (or `read_rag_source` for a short document) to confirm your exact quote before citing it.
- **After Call 10, STOP.** Synthesize your answer.

## The "Partial Answer" Rule

If after 6-7 calls you still lack a complete picture:

- Do **not** use remaining calls to chase new leads. Use them only to verify what you have.
- Respond transparently: *"I found [X] (e.g., line 42 of auth.py), but [Y] was not found. Proceeding with [X]."*

## Tool Definitions

- **`query_best_match`** (Combined): Merges semantic and FTS scoring. Best for broad coverage. Note: for very keyword-specific queries, the semantic component may dilute precision.
- **`query_semantic`** (Vector Search): Best for conceptual queries, natural language questions, or searching for ideas rather than exact terms. Useful when synonyms or paraphrasing may be used.
- **`query_text_search`** (Full-Text Search): Best for keyword-heavy queries with specific terms, proper nouns, file names, function names, or when you know the exact words. FTS matches exact text occurrences precisely.
- **`list_rag_sources`** (Source Index): Lists the documents (sources) indexed in the RAG — file paths, topics and URLs with chunk counts. Optional `filter` (substring) and `limit`. Use it to resolve a document name to its exact indexed path.
- **`read_rag_source`** (Whole Document Read): Reads a full document from the RAG by path, reconstructed from its chunks. Resolves bare file names (any path suffix). Optional `maxBytes` cap. This is the cheapest way to read a document that another document referenced.
- **`query_read_file`** (Exact Line Lookup): Retrieves the exact text chunk(s) containing a specific line number from a file in the RAG index. Use when you need to read precise content from a known file at a known line. Resolves bare file names too.
- **`list_rag_databases`** (Discovery): Lists all available RAG databases with their names and file paths. Use to discover database names for filtering queries.

## Database Parameter

All query tools that accept a database parameter restrict the search to the database with that name. Pass `"*"` to search all databases (default). Use `list_rag_databases` to discover available database names before filtering.
