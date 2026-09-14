/**
 * RAG retrieval evaluation harness for llmfun.
 *
 * Indexes a small corpus of markdown documents into a scratch RAG database
 * using the *real* configured embedder (e.g. the local nomic model) and runs
 * a battery of queries against the three retrieval paths:
 *
 *   - semantic  : RAG.querySemantic
 *   - best      : RAG.queryBestMatch (RRF fusion)
 *   - text      : RAG.queryTextSearch (FTS5)
 *
 * For each query the first chunk belonging to the *expected* source file is
 * located in the result list and hit@1 / hit@3 / hit@K and MRR are reported,
 * plus the per-file distance ranking from the raw vector table (the pure
 * embedding signal before any ranking/fusion code).
 *
 * Usage:
 *   rag_eval run --corpus <dir> --db <file.db> [--config <yaml>]
 *                [--topK N] [--keep-db] [--out report.json]
 *
 * Build:
 *   dub build --config=rag_eval
 * Run from the workarea root so the relative modelPath in the config resolves.
 *
 * License: MPL-2.0
 */
module rag_eval;

import std.algorithm : canFind, endsWith, map, sort;
import std.array : appender, array, join;
import std.conv : to;
import std.file : SpanMode, dirEntries, exists, isFile, mkdirRecurse, readText, remove;
import std.format : format;
import std.math : sqrt;
import std.path : baseName, buildPath, dirName;
import std.stdio : File, writefln, writeln;
import std.string : replace, strip;
import std.sumtype : match;

import my.optional;
import my.path : AbsolutePath, Path;

import llm.common.config : EmbedConfig, LocalEmbedConfig, RemoteEmbedConfig;
import llm.common.embedder : createEmbedder, EmbedError, Embedder;
import llm.config : LlmConfig, RagConfig, RagDatabaseConfig, readConfig;
import llm.rag.database : cleanFts5, Source, SourceId;
import llm.rag.rag : Document, Origin, RAG, Topic, Url, add;
import llm.subsystem : deinitLlmfunLocalModel, initLlmfunLocalModel;

enum Mode {
    semantic,
    best,
    text
}

string modeName(Mode m) {
    switch (m) {
    case Mode.semantic:
        return "semantic";
    case Mode.best:
        return "best";
    case Mode.text:
        return "text";
    default:
        return "?";
    }
}

/// A single retrieval test.
struct QueryCase {
    string id;
    string note;
    /// Query text sent to the embedding model (vector half).
    string vectorQuery;
    /// Query text sent to FTS5 (text half). Falls back to vectorQuery.
    string textQuery;
    /// File name (suffix) that the first result should ideally come from.
    string expected;
    /// Which modes to run for this case: any of "s" (semantic), "b" (best), "t" (text).
    string modes;
}

immutable QueryCase[] EvalCases = [
    // --- file-name queries (the reported failure pattern) -------------------
    QueryCase("f1", "want the token spec file, by name", "I want the file auth_token_spec",
            "auth_token_spec", "auth_token_spec.md", "sbt"),
    QueryCase("f2", "bare file name", "auth_token_spec", "auth_token_spec",
            "auth_token_spec.md", "sbt"),
    QueryCase("f3", "file name with extension", "auth_token_spec.md",
            "auth_token_spec", "auth_token_spec.md", "sbt"),
    QueryCase("f4", "want the runbook file", "I want the file deploy_runbook",
            "deploy_runbook", "deploy_runbook.md", "sbt"),
    QueryCase("f5", "show me the database schema document",
            "show me the database schema document", "database schema", "db_schema.md",
            "sbt"),
    QueryCase("f6", "onboarding file by name", "I want the file onboarding",
            "onboarding", "onboarding.md", "sbt"),

    // --- content queries ----------------------------------------------------
    QueryCase("c1", "token format", "What is the token format?",
            "token format", "auth_token_spec.md", "sbt"),
    QueryCase("c2", "access token lifetime", "How long do access tokens live?",
            "access token 15 minutes", "auth_token_spec.md", "sbt"),
    QueryCase("c3", "signing key rotation", "Where is the signing key rotation described?",
            "signing key rotation", "deploy_runbook.md", "sbt"),
    QueryCase("c4", "data retention", "What are the data retention rules?",
            "data retention", "onboarding.md", "sbt"),
    QueryCase("c5", "refresh token incident",
            "Which document describes the refresh token incident?",
            "refresh token incident", "incident_postmortem.md", "sbt"),
    QueryCase("c6", "bloom filter false positive target (long doc, middle)",
            "What is the bloom filter false positive target?",
            "bloom filter false positive target", "storage_engine_design.md",
            "sbt"),

    // --- cross-reference queries: find the referenced document --------------
    QueryCase("x1", "which file defines the token claims",
            "Which file defines the JWT token claims?", "JWT token claims",
            "auth_token_spec.md", "sbt"),
    QueryCase("x2", "document referenced for token format",
            "The token format is defined in which document?",
            "token format defined", "auth_token_spec.md", "sbt"),
    QueryCase("x3", "what does auth overview reference for the migration",
            "What does auth_overview reference for the migration plan?",
            "auth_migration_plan", "auth_migration_plan.md", "sbt"),
    QueryCase("x4", "key rotation steps from the runbook", "The signing key rotation steps are in which file?",
            "signing key rotation steps", "deploy_runbook.md", "sbt"),
];

struct CaseResult {
    string id;
    string mode;
    string expected;
    long rank; // 1-based rank of first chunk of expected source in the result (-1 = miss)
    string[] top; // top source paths (up to topK)
    string[] rawTop; // top files by raw vector distance (best chunk per file)
}

struct ModeStat {
    size_t runs;
    size_t hit1;
    size_t hit3;
    size_t hitTop;
    double mrr = 0.0;
}

string originStr(const Document d) {
    return d.origin.match!((Topic a) => "topic:" ~ a.name,
            (Url a) => "url:" ~ a.value, (Path a) => a.toString);
}

long rankOf(const Document[] docs, string expected) {
    if (docs is null)
        return -1;
    foreach (i, d; docs) {
        if (originStr(d).endsWith(expected))
            return cast(long) i + 1;
    }
    return -1;
}

string[] topSources(const Document[] docs, size_t n) {
    auto app = appender!(string[])();
    if (docs !is null) {
        foreach (i, d; docs) {
            if (i >= n)
                break;
            app.put(originStr(d));
        }
    }
    return app[];
}

string sourcePath(Source s) {
    return s.origin.match!((Topic a) => "topic:" ~ a.name,
            (Url a) => "url:" ~ a.value, (Path a) => a.toString);
}

/// Raw per-file vector distance ranking: the best (smallest) distance per
/// source file, computed directly against the vec0 table.
string[] rawTopFiles(RAG rag, float[] embed, size_t n, out double[] dists) {
    immutable sql = "SELECT id, sourceId, distance FROM EmbeddingsTbl WHERE embedding MATCH :embedding AND k = :limit ORDER BY distance";
    auto stmt = rag.db.prepare(sql);
    stmt.get.bind(":embedding", embed);
    stmt.get.bind(":limit", 1000);

    string[] paths;
    double[] d;
    foreach (ref r; stmt.get.execute) {
        const sid = r.peek!long(1);
        const distance = r.peek!double(2);
        string path;
        rag.db.getSource(sid.SourceId).match!((Source s) { path = sourcePath(s); }, (None _) {
        });
        if (path.length == 0)
            continue;
        // first time this file appears = its best chunk (rows are distance-sorted)
        if (!paths.canFind(path)) {
            paths ~= path;
            d ~= distance;
            if (paths.length >= n)
                break;
        }
    }
    dists = d;
    return paths;
}

void indexCorpus(RAG rag, string corpusDir, RagConfig cfg) {
    writeln("== indexing corpus ==");
    size_t files, chunks;
    auto entries = dirEntries(corpusDir, SpanMode.shallow).array;
    entries.sort!((a, b) => a.name < b.name);
    foreach (entry; entries) {
        if (!entry.isFile)
            continue;
        if (!entry.name.endsWith(".md"))
            continue;
        const rel = "corpus/" ~ baseName(entry.name);
        const text = readText(entry.name);
        auto res = add(rag, Document(origin: Origin(Path(rel)), data: text), cfg);
        writefln("  %-44s %d chunks", rel, res.chunks);
        ++files;
        chunks += res.chunks;
    }
    rag.db.fts5Rebuild;
    writefln("  -> %d files, %d chunks", files, chunks);
}

Document[] runQuery(RAG rag, Mode m, QueryCase c, long topK) {
    const tq = cleanFts5(c.textQuery.length ? c.textQuery : c.vectorQuery);
    switch (m) {
    case Mode.semantic:
        return rag.querySemantic(c.vectorQuery, topK, "*");
    case Mode.best:
        return rag.queryBestMatch(tq, c.vectorQuery, topK, "*");
    case Mode.text:
        return rag.queryTextSearch(tq, topK, "*");
    default:
        assert(false, "unknown mode");
        return null;
    }
}

string jsonEscape(string s) {
    return s.replace(`\`, `\\`).replace(`"`, `\"`);
}

string jsonArray(const string[] items) {
    auto parts = appender!(string[])();
    foreach (it; items)
        parts.put("\"" ~ jsonEscape(it) ~ "\"");
    return parts[].join(", ");
}

void tally(ref ModeStat s, long rank, size_t topK) {
    ++s.runs;
    if (rank == 1)
        ++s.hit1;
    if (rank >= 1 && rank <= 3)
        ++s.hit3;
    if (rank >= 1 && rank <= cast(long) topK)
        ++s.hitTop;
    if (rank >= 1)
        s.mrr += 1.0 / cast(double) rank;
}

int runCmd(string[] args) {
    string argValue(string name, string def) {
        foreach (i, a; args) {
            if (a == name && i + 1 < args.length)
                return args[i + 1];
        }
        return def;
    }

    bool hasFlag(string name) {
        return args.canFind(name);
    }

    auto corpusDir = argValue("--corpus", "");
    auto dbPath = argValue("--db", "");
    auto configPath = argValue("--config", "/workarea/.llmfun.yaml");
    auto topK = argValue("--topK", "5").to!long;
    auto outPath = argValue("--out", "");
    if (corpusDir.length == 0 || dbPath.length == 0) {
        writeln("error: --corpus and --db are required");
        return 1;
    }

    mkdirRecurse(dirName(dbPath));
    if (!hasFlag("--keep-db") && exists(dbPath))
        remove(dbPath);

    auto conf = readConfig(configPath.Path, silent: true, noCwdConfig: true, trustedConfig: false);
    auto emb = createEmbedder(conf.embedConfig);
    if (emb is null) {
        writeln("error: unable to create embedder from config ", configPath);
        return 1;
    }
    scope (exit)
        emb.destroy;

    auto rag = new RAG(emb, RagDatabaseConfig(dbPath.Path, "eval"), null);
    scope (exit)
        rag.destroy;

    indexCorpus(rag, corpusDir, conf.ragConfig);

    // -- embedding probe: norms -------------------------------------------------
    writeln("\n== embedding probe ==");
    foreach (probe; [
        "I want the file auth_token_spec", "the token specification document"
    ]) {
        auto r = emb.embedQuery(probe);
        r.match!((float[] v) {
            double n = 0;
            foreach (x; v)
                n += cast(double) x * x;
            writefln("  query norm %.4f  '%s'", sqrt(n), probe);
        }, (EmbedError e) { writefln("  query embed failed: %s", e.errorMsg); });
    }

    // -- queries ---------------------------------------------------------------
    writeln("\n== query battery (topK=", topK, ") ==");
    CaseResult[] results;
    ModeStat[Mode] stats;

    foreach (c; EvalCases) {
        writeln("\n", c.id, " [", c.note, "] expect: ", c.expected);

        // raw distance ranking (semantic signal before fusion)
        string[] rawTop;
        double[] rawDist;
        if (c.vectorQuery.length) {
            auto r = emb.embedQuery(c.vectorQuery);
            r.match!((float[] v) { rawTop = rawTopFiles(rag, v, 3, rawDist); }, (EmbedError e) {
            });
            if (rawTop.length) {
                auto parts = appender!(string[])();
                foreach (i, p; rawTop)
                    parts.put(format!"%s(%.3f)"(p, rawDist[i]));
                writefln("   raw distances: %s", parts[].join(", "));
            }
        }

        const string[] modesOrder = ["semantic", "best", "text"];
        foreach (mode; modesOrder) {
            if (!c.modes.canFind(mode[0]))
                continue;
            const m = mode == "semantic" ? Mode.semantic : mode == "best" ? Mode.best : Mode.text;
            auto docs = runQuery(rag, m, c, topK);
            const rank = rankOf(docs, c.expected);
            auto tops = topSources(docs, topK);
            results ~= CaseResult(c.id, mode, c.expected, rank, tops, rawTop);
            writefln("   %-8s rank=%-4s top=%s", mode, rank < 0
                    ? "miss" : rank.to!string, tops.join(" | "));

            if (m !in stats)
                stats[m] = ModeStat.init;
            tally(stats[m], rank, topK);
        }
    }

    writeln("\n== summary (topK=", topK, ") ==");
    writeln("mode      runs  hit@1  hit@3  hit@K  MRR");
    foreach (m; [Mode.semantic, Mode.best, Mode.text]) {
        if (m !in stats)
            continue;
        auto s = stats[m];
        writefln("%-8s  %4d  %5d  %5d  %5d  %.3f", modeName(m), s.runs, s.hit1,
                s.hit3, s.hitTop, s.mrr / cast(double)(s.runs ? s.runs : 1));
    }

    // -- reference-read workflow: resolve a bare file name and read it ---------
    writeln("\n== read workflow (bare-name suffix resolution) ==");
    foreach (target; [
        "auth_token_spec.md", "deploy_runbook.md", "storage_engine_design.md"
    ]) {
        auto full = rag.readSource(Path(target), "*");
        const readOk = full.length >= 1;
        const disk = readText(buildPath(corpusDir, baseName(target)));
        const exact = readOk && full.length == 1 && full[0].text == disk;
        auto chunks = rag.queryReadFile(Path(target), 1, "*");
        const chunkOk = chunks !is null && chunks.length >= 1;
        writefln("  %-36s fullRead=%-5s exactMatch=%-5s chunkRead=%s", target,
                readOk, exact, chunkOk);
    }

    // -- JSON report ------------------------------------------------------------
    if (outPath.length) {
        auto f = File(outPath, "w");
        f.write("{\n");
        f.writefln("  \"db\": \"%s\",", jsonEscape(dbPath));
        f.writefln("  \"topK\": %d,", topK);
        f.write("  \"results\": [\n");
        foreach (i, r; results) {
            f.write("    {");
            f.writefln("\"id\": \"%s\", \"mode\": \"%s\", \"expected\": \"%s\", \"rank\": %d,",
                    jsonEscape(r.id), jsonEscape(r.mode), jsonEscape(r.expected), r.rank);
            f.writefln("     \"top\": [%s], \"rawTop\": [%s]}",
                    jsonArray(r.top), jsonArray(r.rawTop));
            f.write(i + 1 < results.length ? ",\n" : "\n");
        }
        f.write("  ]\n}\n");
        writeln("\nwrote ", outPath);
    }

    return 0;
}

int main(string[] args) {
    initLlmfunLocalModel();
    scope (exit)
        deinitLlmfunLocalModel();

    if (args.length < 2) {
        writeln(
                "usage: rag_eval run --corpus <dir> --db <file.db> [--config <yaml>] [--topK N] [--out report.json]");
        return 1;
    }
    switch (args[1]) {
    case "run":
        return runCmd(args);
    default:
        writeln("unknown command: ", args[1]);
        return 1;
    }
}
