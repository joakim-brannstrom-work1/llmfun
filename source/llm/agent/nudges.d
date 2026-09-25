/// Nudge template loading and emission for the agent harness. The config
/// structs and shipped default file names live in llm.config.
module llm.agent.nudges;

import logger = std.logger;
import std.algorithm.comparison : min;
import std.array : empty, replace;
import std.sumtype : match;
import std.traits : EnumMembers;

import my.path;

import llm.config : CompressionNudgeConfig, DefaultCompressionNudge,
    EscalationConfig, FeedbackNudgeConfig, NudgeConfig, NudgeKind, defaultNudgeFiles;

/// Resolved file list for one ladder phase: the configured list, or the
/// shipped defaults when the configured list is empty. The single source of
/// the fallback rule — both loadNudgeTexts (which files get read) and the
/// agent's trace-log source resolution (llm/agent/package.d nudgeSourceFile,
/// which file name gets logged) go through this, so the logged file name can
/// never drift from the loaded template.
const(string)[] resolvedNudgeFiles(in EscalationConfig esc, NudgeKind kind, bool hard) @safe pure {
    return hard ? (esc.hardNudges.empty ? defaultNudgeFiles(kind, true) : esc.hardNudges) : (
            esc.softNudges.empty ? defaultNudgeFiles(kind, false) : esc.softNudges);
}

/// Template text for strike `strikeNo` (1-based) of a ladder.
/// Last entry repeats for strikes beyond the list length. Callers must pass
/// strikeNo >= 1 and a resolved (non-empty) ladder — e.g. check the kind's
/// `enabled` flag before calling: a disabled kind has no ladder.
string nudgeFor(in string[] ladder, in long strikeNo) @safe pure {
    assert(strikeNo >= 1 && !ladder.empty,
            "nudgeFor: 1-based strikeNo and a resolved (non-empty) ladder "
            ~ "required — check the kind's enabled flag before calling");
    return ladder[min(strikeNo, cast(long) ladder.length) - 1];
}

/// Replace {{name}} placeholders (initially {{context_percent}}).
/// Literal token replacement of code-controlled values: no format-string
/// interpretation, so arbitrary user-authored template text is safe.
string substituteNudgeVars(string tmpl, in string[string] vars) @safe pure {
    string result = tmpl;
    foreach (name, value; vars) {
        result = result.replace("{{" ~ name ~ "}}", value);
    }
    return result;
}

struct NudgeTexts {
    /// kind → resolved ladder of templates (one entry per strike, last repeats)
    string[][NudgeKind] soft;
    string[][NudgeKind] hard;
    string compression; // loaded template; empty when disabled
}

/// The escalation sub-config for `kind` (const copy of the caller's config).
/// final switch, not a ternary: a future NudgeKind member then fails to
/// compile until handled instead of silently routing to recovery.
private const(EscalationConfig) escalationOf(NudgeKind kind, in NudgeConfig cfg) @safe pure {
    final switch (kind) with (NudgeKind) {
    case keepReasoning:
        return cfg.keepReasoning;
    case recovery:
        return cfg.recovery;
    }
}

/// Load all templates for `cfg` through FlatVfs(promptDir) — the same
/// resolution as the system prompt. Throws when a required file is missing,
/// surfacing config errors at agent construction / model switch. Kinds with
/// `enabled: false` contribute no entries and load no files; kinds with
/// `softStrikes: 0` load no soft files either (soft phase unreachable).
NudgeTexts loadNudgeTexts(in Path[] promptDir, in NudgeConfig cfg) @safe {
    NudgeTexts texts;

    foreach (kind; EnumMembers!NudgeKind) {
        auto esc = escalationOf(kind, cfg);
        if (!esc.enabled) {
            continue;
        }
        auto softFiles = resolvedNudgeFiles(esc, kind, false);
        auto hardFiles = resolvedNudgeFiles(esc, kind, true);
        // `softStrikes: 0` makes the soft phase unreachable (strike >= 1
        // is never <= 0) — skip the soft reads so configs that can never emit
        // a soft nudge don't need its file on disk. `hardStrikes: 0` (legacy
        // unlimited) keeps loading hard: hard stays reachable.
        if (esc.softStrikes > 0) {
            foreach (file; softFiles) {
                texts.soft[kind] ~= readNudgeTemplate(promptDir, file);
            }
        }
        foreach (file; hardFiles) {
            texts.hard[kind] ~= readNudgeTemplate(promptDir, file);
        }
    }

    if (cfg.compression.enabled) {
        auto name = cfg.compression.prompt.empty ? DefaultCompressionNudge : cfg.compression.prompt;
        texts.compression = readNudgeTemplate(promptDir, name);
    }

    return texts;
}

private string readNudgeTemplate(in Path[] promptDir, string name) @safe {
    import llm.vfs : FlatVfs;

    // FlatVfs is unattributed (thus @system) while doing only memory-safe
    // work (array copy, exists, readText): confine the boundary to one
    // @trusted scope, the same way vfs.d confines dirEntries.
    return () @trusted {
        // dup: `in` is const and FlatVfs takes the hierarchy by mutable value.
        auto vfs = FlatVfs(promptDir.dup);
        return vfs.read(name).match!((string a) => a, (_) {
            logger.warningf("Prompt '%s' not found", name);
            throw new Exception("Prompt file not found: " ~ name);
            return null;
        });
    }();
}

@("nudgeFor repeats the last template for strikes beyond the ladder")
unittest {
    // Ladder selection repeats the last entry for strikes beyond the list.
    assert(nudgeFor(["a", "b"], 1) == "a");
    assert(nudgeFor(["a", "b"], 2) == "b");
    assert(nudgeFor(["a", "b"], 5) == "b");
    assert(nudgeFor(["solo"], 3) == "solo");
    // Misuse fails loudly: 0-based strike or an unresolved (disabled) ladder.
    import core.exception : AssertError;
    import std.exception : assertThrown;

    assertThrown!AssertError(nudgeFor([], 1));
    assertThrown!AssertError(nudgeFor(["a"], 0));
}

@("defaultNudgeFiles maps kind and phase to the shipped default files")
unittest {
    assert(defaultNudgeFiles(NudgeKind.keepReasoning, false) == [
        "NUDGE_KEEP_REASONING_SOFT.md"
    ]);
    assert(defaultNudgeFiles(NudgeKind.keepReasoning, true) == [
        "NUDGE_KEEP_REASONING_HARD.md"
    ]);
    assert(defaultNudgeFiles(NudgeKind.recovery, false) == [
        "NUDGE_RECOVERY_SOFT.md"
    ]);
    assert(defaultNudgeFiles(NudgeKind.recovery, true) == [
        "NUDGE_RECOVERY_HARD.md"
    ]);
}

@("resolvedNudgeFiles applies the empty→default fallback per phase")
unittest {
    // Empty configured lists resolve to the shipped defaults; non-empty
    // configured lists win wholesale — the same rule loadNudgeTexts applies.
    auto esc = EscalationConfig.init;
    assert(resolvedNudgeFiles(esc, NudgeKind.keepReasoning,
            false) == ["NUDGE_KEEP_REASONING_SOFT.md"]);
    assert(resolvedNudgeFiles(esc, NudgeKind.recovery, true) == [
        "NUDGE_RECOVERY_HARD.md"
    ]);

    esc.softNudges = ["MY_SOFT.md"];
    esc.hardNudges = ["MY_HARD.md"];
    assert(resolvedNudgeFiles(esc, NudgeKind.keepReasoning, false) == [
        "MY_SOFT.md"
    ]);
    assert(resolvedNudgeFiles(esc, NudgeKind.keepReasoning, true) == [
        "MY_HARD.md"
    ]);
}

@("substituteNudgeVars replaces {{context_percent}} and leaves unknown tokens literal")
unittest {
    // {{context_percent}} → the %.1f-rendered value, e.g. 80.0. Unknown
    // tokens stay literal: values are code-controlled, no format interpretation.
    string[string] vars;
    vars["context_percent"] = "80.0";
    assert(substituteNudgeVars("Context at {{context_percent}}% — compress now.",
            vars) == "Context at 80.0% — compress now.");
    assert(substituteNudgeVars("{{unknown}} stays", vars) == "{{unknown}} stays");
}

@("a missing nudge file throws the readPromptFile message at load time")
unittest {
    // Surfacing config errors before any request is wasted.
    import std.conv : to;
    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;

    auto tmpDir = buildPath("llmfun_test", "nudges_missing_" ~ __LINE__.to!string);
    mkdirRecurse(tmpDir);
    scope (exit)
        rmdirRecurse(tmpDir);
    write(buildPath(tmpDir, "NUDGE_KEEP_REASONING_SOFT.md"), "soft");

    auto cfg = NudgeConfig.init;
    cfg.keepReasoning.softNudges = ["MISSING_NUDGE.md"];

    string msg;
    try {
        loadNudgeTexts([Path(tmpDir)], cfg);
    } catch (Exception e) {
        msg = e.msg;
    }
    assert(msg == "Prompt file not found: MISSING_NUDGE.md", msg);
}

@("disabled kinds load no files and need no prompt dir")
unittest {
    // No throw even though the prompt dir does not exist at all.
    auto cfg = NudgeConfig.init;
    cfg.keepReasoning.enabled = false;
    cfg.recovery.enabled = false;
    cfg.compression.enabled = false;

    auto texts = loadNudgeTexts([Path("no_such_prompt_dir")], cfg);
    assert(texts.soft.length == 0 && texts.hard.length == 0);
    assert(texts.compression.empty);
}

@("empty lists resolve to the shipped defaults; overrides restate only what they change")
unittest {
    // Empty lists resolve to the shipped defaults; the resolved ladders
    // are returned so nudgeFor is total. User-provided lists replace the
    // defaults wholesale; compression.prompt overrides the default file.
    import std.conv : to;
    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;

    auto tmpDir = buildPath("llmfun_test", "nudges_defaults_" ~ __LINE__.to!string);
    mkdirRecurse(tmpDir);
    scope (exit)
        rmdirRecurse(tmpDir);
    write(buildPath(tmpDir, "NUDGE_KEEP_REASONING_SOFT.md"), "KEEP_SOFT");
    write(buildPath(tmpDir, "NUDGE_KEEP_REASONING_HARD.md"), "KEEP_HARD");
    write(buildPath(tmpDir, "NUDGE_RECOVERY_SOFT.md"), "RECOVERY_SOFT");
    write(buildPath(tmpDir, "NUDGE_RECOVERY_HARD.md"), "RECOVERY_HARD");
    write(buildPath(tmpDir, "NUDGE_COMPRESSION.md"), "COMPRESSION {{context_percent}}");
    write(buildPath(tmpDir, "MY_COMPRESSION.md"), "MY_COMPRESSION");

    auto texts = loadNudgeTexts([Path(tmpDir)], NudgeConfig.init);
    assert(texts.soft[NudgeKind.keepReasoning] == ["KEEP_SOFT"]);
    assert(texts.hard[NudgeKind.keepReasoning] == ["KEEP_HARD"]);
    assert(texts.soft[NudgeKind.recovery] == ["RECOVERY_SOFT"]);
    assert(texts.hard[NudgeKind.recovery] == ["RECOVERY_HARD"]);
    assert(texts.compression == "COMPRESSION {{context_percent}}");

    // Phase selection over the resolved ladders: soft strikes 1-2 (repeat-last)
    // then the hard phase (caller math).
    auto soft = texts.soft[NudgeKind.keepReasoning];
    auto hard = texts.hard[NudgeKind.keepReasoning];
    assert(nudgeFor(soft, 1) == "KEEP_SOFT");
    assert(nudgeFor(soft, 2) == "KEEP_SOFT");
    assert(nudgeFor(hard, 1) == "KEEP_HARD");

    auto overridden = NudgeConfig.init;
    overridden.recovery.softNudges = [
        "NUDGE_RECOVERY_SOFT.md", "MY_COMPRESSION.md"
    ];
    overridden.compression.prompt = "MY_COMPRESSION.md";
    auto custom = loadNudgeTexts([Path(tmpDir)], overridden);
    assert(custom.soft[NudgeKind.recovery] == [
        "RECOVERY_SOFT", "MY_COMPRESSION"
    ]);
    assert(custom.compression == "MY_COMPRESSION");
    // An override restates only what it changes; the other kind keeps defaults.
    assert(custom.soft[NudgeKind.keepReasoning] == ["KEEP_SOFT"]);
}

version (unittest) {
    /// One shared serialization object for every test that swaps the
    /// process-wide `logger.sharedLog` (capture tests in llm.config,
    /// llm.rag.dialogue_worker and llm.rag.reasoning_index): silly runs
    /// unittests in parallel (TaskPool), so overlapping swap windows would
    /// send log lines into the WRONG capture. Each test holds this mutex from
    /// install through takeLines() to make its swap+drain critical section
    /// atomic.
    ///
    /// This lives here (a module llm.config already imports at file scope and
    /// the other capture tests reach through llm.test_util's re-export)
    /// because a module constructor inside the module-import cycle around
    /// llm.chat/llm.utility/llm.rag makes module init order ambiguous -- the
    /// runtime then aborts with "Cyclic dependency between module
    /// constructors/destructors" depending on link order. nudges imports
    /// nothing from that cycle, so its constructor always initializes first.
    __gshared Object sharedLogSwapMutex = new Object;
}
