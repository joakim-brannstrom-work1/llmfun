# eval_rag — RAG retrieval evaluation harness

Indexes a small markdown corpus with the **real configured embedder** (local
nomic model by default) into a scratch RAG database and measures the retrieval
quality of the three query paths:

- `semantic` — `RAG.querySemantic`
- `best`     — `RAG.queryBestMatch` (RRF fusion of vector + FTS5)
- `text`     — `RAG.queryTextSearch` (FTS5)

For every query the first chunk belonging to the **expected** source file is
located in the result list and hit@1 / hit@3 / hit@K and MRR are reported, plus
the raw per-file distance ranking from the vec0 table (the pure embedding
signal before fusion/ranking code) and a read-workflow check (bare file name →
whole document read).

## Files

| Path | Purpose |
| ---- | ------- |
| `eval_rag.d` | The harness (dub configuration `rag_eval`). |
| `corpus/` | 14 synthetic markdown documents with cross-references (auth, deploy, storage, etc.). |
| `probe_embed.c` | Raw llama.cpp probe: pooling/norm sanity, special-token (BOS/EOS) A/B measurement, and proof that `llama_tokenize(add_special=true)` matches the token-array mirror wrap (model's `add_bos`/`add_eos` flags) token-for-token (cos = 1.000000). |
| `probe_token_drift.c` | Measures full-string `add_special=true` token counts against prefix + specials + Σ per-word counts (the chunker's counting): delta = 0 across boundary cases and the whole corpus, so the batch budget is exact. |
| `probe_pooling.c` | Prints the GGUF pooling type and a raw embedding cosine matrix. |
| `probe_fts_limit.c` | SQLite FTS5 probe: `row_number() OVER (ORDER BY rank) ... LIMIT` semantics. |

## Build

```
dub build --config=rag_eval        # binary: build/rag_eval
```

## Run

Run from the directory the model path in the config resolves against
(the workspace root that contains `nomic-embed-text-v2-moe.Q8_0.gguf`):

```
./llmfun/build/rag_eval run \
    --corpus llmfun/tools/eval_rag/corpus \
    --db /tmp/eval.sqlite3 \
    --config .llmfun.yaml \
    --topK 5 \
    --out /tmp/eval.json
```

Flags: `--keep-db` (reuse an existing DB; re-indexing is skipped because
`add` dedups on content hash), `--out` (JSON report), `--topK`.

## Probe builds

```
cd llmfun
gcc -O1 -I vendor/sqlite3 -o probe_fts_limit tools/eval_rag/probe_fts_limit.c \
    build/sqlite3.o -lpthread -ldl -lm
gcc -O1 -I vendor/llama.cpp/include -I vendor/llama.cpp/ggml/include \
    -o probe_embed tools/eval_rag/probe_embed.c -L build -lllama -lggml -lggml-base -lggml-cpu -lm
gcc -O1 -I vendor/llama.cpp/include -I vendor/llama.cpp/ggml/include \
    -o probe_token_drift tools/eval_rag/probe_token_drift.c -L build -lllama -lggml -lggml-base -lggml-cpu -lm
LD_LIBRARY_PATH=build ./probe_embed nomic-embed-text-v2-moe.Q8_0.gguf
LD_LIBRARY_PATH=build ./probe_token_drift nomic-embed-text-v2-moe.Q8_0.gguf tools/eval_rag/corpus
```

## Baseline results (nomic-embed-text-v2-moe, topK=5, corpus as of 2026-09)

| configuration | semantic hit@1 | semantic MRR | best hit@1 | best MRR |
| ------------- | -------------- | ------------ | ---------- | -------- |
| before BOS/EOS fix | 0.44 | 0.656 | 0.50 | 0.573 |
| after BOS/EOS fix  | 0.81 | 0.896 | 0.44 | 0.609 |
| + equal RRF weights (final) | 0.81 | 0.896 | 0.50 | 0.641 |
| + L2-normalization (rejected) | 0.75 | 0.865 | 0.44 | 0.609 |

`text` search is unaffected by embedder changes (hit@1 = 0.31, MRR = 0.427).

The read-workflow phase (`readSource` + bare-name `queryReadFile`) passes for
all tested files: full document read is byte-exact against the corpus file.
