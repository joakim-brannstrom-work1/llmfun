/// Integration and prompt-data guards for the Agent turn policy.
module llm.agent.tests;

import std.algorithm : canFind;
import std.file : exists;
import std.sumtype : match;
import std.typecons : nullable;

import llm.agent;
import llm.chat : Chat, Message, turnIdOf;
import llm.metric.monitor : MetricMonitor;

unittest {
    import std.datetime : Clock;
    import std.file : mkdirRecurse, write;
    import std.format : format;

    // stdTime (100ns resolution) keeps two runs in the same second from colliding on the temp dir.
    auto now = Clock.currTime();
    auto tmpDir = format("llmfun_test/agent_turnid_%d_%d", now.toUnixTime(), now.stdTime);
    mkdirRecurse(tmpDir);
    scope (exit)
        cleanupAgentTestDir(tmpDir);
    write(tmpDir ~ "/SUMMARY.md", "Summarize text.");
    writeDefaultNudgeFiles(tmpDir);

    auto llmConf = makeAgentTestConfig(tmpDir);
    auto agent = new Agent("integration", llmConf, null, null);

    agent.setSystemPrompt("sys");
    agent.addUserQuery("first question"); // opens turn 1
    agent.addContinue(); // nudge continues turn 1
    agent.addUserQuery("second question"); // opens turn 2
    agent.addKeepReasoning(); // nudge continues turn 2
    agent.addContinueMessage("You stopped without calling 'pipelineOutput'."); // retry nudge continues turn 2

    assert(agent.chat.nextTurnId() == 2);
    auto msgs = agent.chat.getMessages;
    assert(msgs.length == 6);
    assert(turnIdOf(msgs[0]) == 0, "system prompt belongs to no turn");
    assert(turnIdOf(msgs[1]) == 1);
    assert(turnIdOf(msgs[2]) == 1);
    assert(turnIdOf(msgs[3]) == 2);
    assert(turnIdOf(msgs[4]) == 2);
    assert(turnIdOf(msgs[5]) == 2, "retry nudge continues turn 2, never opens one");

    // The retry nudge is harness traffic: it appears in neither projection and did not fragment the turn sequence.
    auto dialogue = agent.chat.getDialogueHistory();
    assert(dialogue.length == 2, "only the two real user queries are dialogue");
    assert(turnIdOf(dialogue[0]) == 1 && turnIdOf(dialogue[1]) == 2);
    assert(agent.chat.getReasoningTrace().length == 0, "harness nudges are not trace");
}

// Fail-fast: a configured nudge file that is missing fails the AGENT
// CONSTRUCTION with the same "Prompt file not found" error a missing AGENT.md
// produces — before any request is wasted. The override names a file that
// exists nowhere in the fixture prompt dir.
unittest {
    import std.datetime : Clock;
    import std.file : mkdirRecurse, write;
    import std.format : format;

    auto now = Clock.currTime();
    auto tmpDir = format("llmfun_test/agent_nudges_missing_%d_%d", now.toUnixTime(), now.stdTime);
    mkdirRecurse(tmpDir);
    scope (exit)
        cleanupAgentTestDir(tmpDir);
    write(tmpDir ~ "/SUMMARY.md", "Summarize text.");
    writeDefaultNudgeFiles(tmpDir);

    auto llmConf = makeAgentTestConfig(tmpDir);
    llmConf.nudges.keepReasoning.softNudges = ["NO_SUCH_NUDGE.md"];

    bool thrown;
    try {
        auto a = new Agent("integration", llmConf, null, null);
        assert(a.nudges_.keepReasoning.softNudges == ["NO_SUCH_NUDGE.md"],
                "construction must throw before this line");
    } catch (Exception e) {
        thrown = true;
        assert(e.msg == "Prompt file not found: NO_SUCH_NUDGE.md", e.msg);
    }
    assert(thrown, "construction must fail on a missing configured nudge file (M5)");
}

// Wholesale override + eager load at model switch: resetModel swaps the
// ENTIRE policy — fields the model block does not restate fall back to struct
// defaults, NOT to the global customization — and the model's own templates are
// eagerly loaded from the construction prompt dir.
unittest {
    import std.datetime : Clock;
    import std.file : mkdirRecurse, write;
    import std.format : format;
    import std.typecons : nullable;

    import llm.config : CodeModelConfig, NudgeConfig, NudgeKind;

    auto now = Clock.currTime();
    auto tmpDir = format("llmfun_test/agent_nudges_switch_%d_%d", now.toUnixTime(), now.stdTime);
    mkdirRecurse(tmpDir);
    scope (exit)
        cleanupAgentTestDir(tmpDir);
    write(tmpDir ~ "/SUMMARY.md", "Summarize text.");
    writeDefaultNudgeFiles(tmpDir);
    write(tmpDir ~ "/MODEL_NUDGE.md", "MODEL-NUDGE-MARKER");

    auto llmConf = makeAgentTestConfig(tmpDir);
    llmConf.nudges.recovery.hardStrikes = 9; // global customization the model block does NOT restate

    CodeModelConfig modelCfg;
    modelCfg.modelName = "nudged-model";
    modelCfg.contextSize = 8192;
    NudgeConfig modelNudges;
    modelNudges.keepReasoning.softNudges = ["MODEL_NUDGE.md"];
    modelCfg.nudges = modelNudges.nullable;
    llmConf.codeModels ~= modelCfg;

    auto a = new Agent("integration", llmConf, null, null);

    // Construction resolved the active model from the global default.
    assert(a.nudges_.keepReasoning.softNudges.length == 0);
    assert(a.nudges_.recovery.hardStrikes == 9);
    assert(a.nudgeTexts_.soft[NudgeKind.keepReasoning][0].canFind(
            "[SYSTEM NUDGE - NOT USER INPUT]"));

    a.resetModel(llmConf.codeModels[1]);

    // Wholesale swap: the model's block IS the entire policy.
    assert(a.nudges_ == modelNudges);
    // ...so the global recovery customization is gone (struct default back).
    assert(a.nudges_.recovery.hardStrikes == 1);
    // ...and the model's own soft template was eagerly loaded from promptDir_.
    assert(a.nudgeTexts_.soft[NudgeKind.keepReasoning][0] == "MODEL-NUDGE-MARKER");
}

// The trigger rule lives in prompt data, not code, so in-tree removal of the section would silently change the main agent's behavior. This guard loads the real llmfun/config/prompt/AGENT.md through the production getPrompt/getBasePrompt path (FlatVfs) and asserts the section heading and the exact tool name are present. A missing file makes getBasePrompt throw, which fails the test.
unittest {
    const agentPromptFile = "llmfun/config/prompt/AGENT.md";
    assert(agentPromptFile.exists,
            "in-tree AGENT.md missing; getBasePrompt would throw at startup (R12)");
    auto llmConf = makeAgentTestConfig("llmfun/config/prompt");
    auto prompt = llmConf.getPrompt(null, "AGENT.md");
    assert(prompt.canFind("# Dialogue History Retrieval"),
            "Task 8 trigger-rule section missing from the composed main-agent prompt (R12)");
    assert(prompt.canFind("queryDialogueHistory"),
            "Task 8 rule must name the queryDialogueHistory tool (R12)");
}

// The reasoning-history rule also lives in prompt data, not code, so in-tree removal of the section would silently change the main agent's behavior. Same guard shape as the dialogue test above: load the real llmfun/config/prompt/AGENT.md through the production getPrompt path and assert the section heading, the exact tool name, and the anti-anchoring warning are present.
unittest {
    const agentPromptFile = "llmfun/config/prompt/AGENT.md";
    assert(agentPromptFile.exists,
            "in-tree AGENT.md missing; getBasePrompt would throw at startup (R12)");
    auto llmConf = makeAgentTestConfig("llmfun/config/prompt");
    auto prompt = llmConf.getPrompt(null, "AGENT.md");
    assert(prompt.canFind("# Reasoning History Retrieval"),
            "Reasoning History Retrieval section missing from the composed main-agent prompt");
    assert(prompt.canFind("queryReasoningHistory"),
            "Reasoning rule must name the queryReasoningHistory tool");
    assert(prompt.canFind("PAST THOUGHTS, NOT ground truth"),
            "Reasoning rule must state that results are past thoughts, not ground truth");
}

// The five shipped nudge templates are prompt data, not code, so in-tree
// removal (of a file, or of the harness marker / tool name it must carry)
// would silently strip the nudge ladder of its functional traffic or let a
// nudge leak into the dialogue/trace projections. These guards load each real
// llmfun/config/prompt/NUDGE_*.md through the production readPromptFile path
// (FlatVfs) and assert exactly what S5 requires. A missing file makes
// readPromptFile throw, which fails the test.
unittest {
    foreach (name; [
        "NUDGE_KEEP_REASONING_SOFT.md", "NUDGE_KEEP_REASONING_HARD.md",
        "NUDGE_RECOVERY_SOFT.md", "NUDGE_RECOVERY_HARD.md", "NUDGE_COMPRESSION.md"
    ]) {
        const nudgeFile = "llmfun/config/prompt/" ~ name;
        assert(nudgeFile.exists, "in-tree nudge file " ~ name ~ " missing (S5)");
    }

    auto llmConf = makeAgentTestConfig("llmfun/config/prompt");

    // Hard nudges must name the exact tool the ladder demands.
    auto keepHard = llmConf.readPromptFile("NUDGE_KEEP_REASONING_HARD.md");
    assert(keepHard.canFind("taskDone"),
            "keep-reasoning hard nudge must name the taskDone tool (S5)");
    auto recoveryHard = llmConf.readPromptFile("NUDGE_RECOVERY_HARD.md");
    assert(recoveryHard.canFind("Call taskDone now."),
            "recovery hard nudge must tell the agent to call taskDone (S5)");

    // The compression nudge must name the requestCompression tool and carry
    // the harness marker, like the soft nudges.
    auto compression = llmConf.readPromptFile("NUDGE_COMPRESSION.md");
    assert(compression.canFind("requestCompression"),
            "compression nudge must name the requestCompression tool (S5)");
    assert(compression.canFind("[SYSTEM NUDGE - NOT USER INPUT]"),
            "compression nudge must carry the SYSTEM NUDGE marker (S5)");

    // Soft nudges must carry the harness markers that keep them out of the
    // dialogue/trace projections.
    auto keepSoft = llmConf.readPromptFile("NUDGE_KEEP_REASONING_SOFT.md");
    assert(keepSoft.canFind("[SYSTEM NUDGE - NOT USER INPUT]"),
            "keep-reasoning soft nudge must carry the SYSTEM NUDGE marker (S5)");
    auto recoverySoft = llmConf.readPromptFile("NUDGE_RECOVERY_SOFT.md");
    assert(recoverySoft.canFind("[SYSTEM RECOVERY - NOT USER INPUT]"),
            "recovery soft nudge must carry the SYSTEM RECOVERY marker (S5)");
}

version (unittest) {
    import llm.config : LlmConfig;

    /// Test seam for the runToCompletion loop: `Agent.process` is public and
    /// virtual (not final, not private), so a subclass can feed the loop canned
    /// ProcessResults without any HTTP endpoint. The canned results need only
    /// the fields the loop reads — status and hasToolCall.
    class CannedProcessAgent : Agent {
        ProcessResult[] canned;
        size_t served;

        this(string name, LlmConfig llmConf) {
            super(name, llmConf, null, null);
        }

        /// Wires a monitor so the handleToolCalls feedback gating can be
        /// exercised directly (the default ctors pass null, which disables the
        /// feedback warnings entirely).
        this(string name, LlmConfig llmConf, MetricMonitor monitor) {
            import my.filter : ReFilter;

            super(name, llmConf, null, monitor, null, ReFilter.init);
        }

        override ProcessResult process(bool delegate() interrupt) @trusted nothrow {
            return canned[served++];
        }
    }
}

// The default ladder through the real runToCompletion loop: strikes 1-2 emit the shipped
// soft keep-reasoning nudge (repeat-last), strike 3 the hard one, strike 4
// exhausts the default 2+1 ladder and fails the turn with
// Status.agentStuckInLoop. The CannedProcessAgent seam feeds the loop without
// any HTTP endpoint. Also carries the harness-traffic acceptance: the nudges
// are userQuery:false — invisible in the dialogue/trace projections, and they
// never open or fragment a turn.
unittest {
    import std.datetime : Clock;
    import std.file : mkdirRecurse, write;
    import std.format : format;

    auto now = Clock.currTime();
    auto tmpDir = format("llmfun_test/agent_escalation_%d_%d", now.toUnixTime(), now.stdTime);
    mkdirRecurse(tmpDir);
    scope (exit)
        cleanupAgentTestDir(tmpDir);
    write(tmpDir ~ "/SUMMARY.md", "Summarize text.");
    writeDefaultNudgeFiles(tmpDir);

    auto agent = new CannedProcessAgent("integration", makeAgentTestConfig(tmpDir));
    agent.addUserQuery("question"); // opens turn 1; nudges continue it
    agent.canned = [
        ProcessResult(status: ProcessResult.Status.needMoreThinking),
        ProcessResult(status: ProcessResult.Status.needMoreThinking),
        ProcessResult(status: ProcessResult.Status.needMoreThinking),
        ProcessResult(status: ProcessResult.Status.needMoreThinking)
    ];

    auto result = agent.runToCompletion();

    assert(result.status == ProcessResult.Status.agentStuckInLoop,
            "strike 4 exhausts the default 2+1 ladder and fails the turn");

    auto msgs = agent.chat.getMessages;
    assert(msgs.length == 4); // query + 3 nudges (strike 4 adds none)
    assert(msgs[1].match!((Message m) => m.content.canFind("[SYSTEM NUDGE - NOT USER INPUT]"),
            (_) => false), "strike 1: soft keep-reasoning nudge");
    assert(msgs[2].match!((Message m) => m.content.canFind("[SYSTEM NUDGE - NOT USER INPUT]"),
            (_) => false), "strike 2: same soft file (repeat-last)");
    assert(msgs[3].match!((Message m) => m.content.canFind("[SYSTEM OVERRIDE"),
            (_) => false), "strike 3: hard keep-reasoning nudge");
    foreach (m; msgs[1 .. $])
        assert(m.match!((Message m) => !m.isUserQuery, (_) => false),
                "nudges are harness traffic, not user queries");
    foreach (m; msgs[1 .. $])
        assert(turnIdOf(m) == 1, "nudges continue turn 1, never open one");

    assert(agent.chat.getDialogueHistory.length == 1, "only the real query");
    assert(agent.chat.getReasoningTrace.length == 0, "nudges are not trace");
    assert(agent.keepReasoningStrikes == 4, "the exhausted strike still counts");
    assert(agent.continueStrikes == 0);
}

// Wholesale per-model override: the model block restates only softStrikes:1
// — everything else (hardStrikes, file lists) falls back to struct defaults, so
// strike 1 uses the shipped soft nudge and strike 2 the shipped hard one.
unittest {
    import std.datetime : Clock;
    import std.file : mkdirRecurse, write;
    import std.format : format;

    import llm.config : CodeModelConfig, NudgeConfig;

    auto now = Clock.currTime();
    auto tmpDir = format("llmfun_test/agent_escalation_model_%d_%d", now.toUnixTime(), now.stdTime);
    mkdirRecurse(tmpDir);
    scope (exit)
        cleanupAgentTestDir(tmpDir);
    write(tmpDir ~ "/SUMMARY.md", "Summarize text.");
    writeDefaultNudgeFiles(tmpDir);

    auto llmConf = makeAgentTestConfig(tmpDir);
    CodeModelConfig modelCfg;
    modelCfg.modelName = "nudged-model";
    modelCfg.contextSize = 8192;
    NudgeConfig modelNudges;
    modelNudges.keepReasoning.softStrikes = 1;
    modelCfg.nudges = modelNudges.nullable;
    llmConf.codeModels ~= modelCfg;

    auto agent = new CannedProcessAgent("integration", llmConf);
    agent.resetModel(llmConf.codeModels[1]); // wholesale swap

    agent.canned = [
        ProcessResult(status: ProcessResult.Status.needMoreThinking),
        ProcessResult(status: ProcessResult.Status.needMoreThinking),
        ProcessResult(status: ProcessResult.Status.needMoreThinking)
    ];

    auto result = agent.runToCompletion();

    assert(result.status == ProcessResult.Status.agentStuckInLoop,
            "strike 3 exhausts the softStrikes:1 ladder (1 soft + 1 hard)");
    auto msgs = agent.chat.getMessages;
    assert(msgs.length == 2); // 2 nudges
    assert(msgs[0].match!((Message m) => m.content.canFind("[SYSTEM NUDGE - NOT USER INPUT]"),
            (_) => false), "strike 1: soft (per-model ladder)");
    assert(msgs[1].match!((Message m) => m.content.canFind("[SYSTEM OVERRIDE"),
            (_) => false), "strike 2: hard (phase transition)");
    assert(agent.keepReasoningStrikes == 3);
}

// `enabled: false` short-circuits to true — no counter increment: the
// loop runs on with no nudge injected and ends via the MaxConsecutiveSameStatus
// backstop (4 identical needMoreThinking results), not via ladder exhaustion.
// The fixture omits the keep-reasoning files entirely: if the disabled kind's
// ladder were touched, the missing-key AA access would throw.
unittest {
    import std.datetime : Clock;
    import std.file : mkdirRecurse, write;
    import std.format : format;

    auto now = Clock.currTime();
    auto tmpDir = format("llmfun_test/agent_escalation_disabled_%d_%d",
            now.toUnixTime(), now.stdTime);
    mkdirRecurse(tmpDir);
    scope (exit)
        cleanupAgentTestDir(tmpDir);
    write(tmpDir ~ "/SUMMARY.md", "Summarize text.");
    write(tmpDir ~ "/NUDGE_RECOVERY_SOFT.md", "soft");
    write(tmpDir ~ "/NUDGE_RECOVERY_HARD.md", "hard");
    write(tmpDir ~ "/NUDGE_COMPRESSION.md", "compression");

    auto llmConf = makeAgentTestConfig(tmpDir);
    llmConf.nudges.keepReasoning.enabled = false;

    auto agent = new CannedProcessAgent("integration", llmConf);
    agent.canned = [
        ProcessResult(status: ProcessResult.Status.needMoreThinking),
        ProcessResult(status: ProcessResult.Status.needMoreThinking),
        ProcessResult(status: ProcessResult.Status.needMoreThinking),
        ProcessResult(status: ProcessResult.Status.needMoreThinking)
    ];

    auto result = agent.runToCompletion();

    assert(result.status == ProcessResult.Status.agentStuckInLoop,
            "the turn ends via the loop-safety backstop");
    assert(agent.chat.getMessages.length == 0, "no nudge message was injected");
    assert(agent.keepReasoningStrikes == 0, "no counter increment");
    assert(agent.continueStrikes == 0);
}

// Pin: a pipeline-retry message added via addContinueMessage consumes no
// strikes and never routes through the ladder — the retry path bypasses the
// escalation mechanism entirely (caller-supplied text).
unittest {
    import std.datetime : Clock;
    import std.file : mkdirRecurse, write;
    import std.format : format;

    auto now = Clock.currTime();
    auto tmpDir = format("llmfun_test/agent_w3_bypass_%d_%d", now.toUnixTime(), now.stdTime);
    mkdirRecurse(tmpDir);
    scope (exit)
        cleanupAgentTestDir(tmpDir);
    write(tmpDir ~ "/SUMMARY.md", "Summarize text.");
    writeDefaultNudgeFiles(tmpDir);

    auto agent = new CannedProcessAgent("integration", makeAgentTestConfig(tmpDir));
    agent.addUserQuery("question"); // opens turn 1

    agent.addContinueMessage("You stopped without calling 'pipelineOutput'.");

    assert(agent.keepReasoningStrikes == 0 && agent.continueStrikes == 0,
            "the retry nudge consumes no strikes");
    auto msgs = agent.chat.getMessages;
    assert(msgs.length == 2); // query + retry nudge
    assert(msgs[1].match!((Message m) => m.content == "You stopped without calling 'pipelineOutput'.",
            (_) => false), "caller text verbatim, no template");
    assert(turnIdOf(msgs[1]) == 1, "the retry nudge continues the open turn");
    assert(agent.chat.getDialogueHistory.length == 1, "not in the dialogue projection");
    assert(agent.chat.getReasoningTrace.length == 0, "not in the trace projection");
}

// Regression: an ok round WITH tool calls is a fresh round — it injects no
// nudge and resets the strike counters (per-turn lifecycle), so a healthy
// multi-round turn never drifts toward ladder exhaustion. The soft marker on
// the second keep-reasoning nudge proves the reset: without it, strike 2 would
// emit the hard template.
unittest {
    import std.datetime : Clock;
    import std.file : mkdirRecurse, write;
    import std.format : format;

    auto now = Clock.currTime();
    auto tmpDir = format("llmfun_test/agent_ok_toolcall_%d_%d", now.toUnixTime(), now.stdTime);
    mkdirRecurse(tmpDir);
    scope (exit)
        cleanupAgentTestDir(tmpDir);
    write(tmpDir ~ "/SUMMARY.md", "Summarize text.");
    writeDefaultNudgeFiles(tmpDir);

    auto agent = new CannedProcessAgent("integration", makeAgentTestConfig(tmpDir));
    agent.addUserQuery("question"); // opens turn 1
    agent.canned = [
        ProcessResult(status: ProcessResult.Status.needMoreThinking), // strike 1: soft
        ProcessResult(status: ProcessResult.Status.ok, hasToolCall: true), // fresh round: reset
        ProcessResult(status: ProcessResult.Status.needMoreThinking), // strike 1 AGAIN: soft, not hard
        ProcessResult(status: ProcessResult.Status.networkFailure) // ends the turn
    ];

    auto result = agent.runToCompletion();

    assert(result.status == ProcessResult.Status.networkFailure,
            "the turn ends with the canned failure, not a nudge backstop");
    auto msgs = agent.chat.getMessages;
    assert(msgs.length == 3); // query + 2 keep-reasoning nudges (ok round adds none)
    assert(msgs[1].match!((Message m) => m.content.canFind("[SYSTEM NUDGE - NOT USER INPUT]"),
            (_) => false), "strike 1: soft keep-reasoning nudge");
    assert(msgs[2].match!((Message m) => m.content.canFind("[SYSTEM NUDGE - NOT USER INPUT]"),
            (_) => false), "strike reset by the ok round: soft again, not hard");
    assert(agent.keepReasoningStrikes == 1 && agent.continueStrikes == 0,
            "only the final needMoreThinking round consumed a strike");
}

// The ok-without-tool-call path drives the recovery ladder through the real
// loop: the nudge is injected, the counter advances, and the
// projections stay nudge-free.
unittest {
    import std.datetime : Clock;
    import std.file : mkdirRecurse, write;
    import std.format : format;

    auto now = Clock.currTime();
    auto tmpDir = format("llmfun_test/agent_ok_continue_%d_%d", now.toUnixTime(), now.stdTime);
    mkdirRecurse(tmpDir);
    scope (exit)
        cleanupAgentTestDir(tmpDir);
    write(tmpDir ~ "/SUMMARY.md", "Summarize text.");
    writeDefaultNudgeFiles(tmpDir);

    auto agent = new CannedProcessAgent("integration", makeAgentTestConfig(tmpDir));
    agent.addUserQuery("question"); // opens turn 1
    agent.canned = [
        ProcessResult(status: ProcessResult.Status.ok), // no tool call: recovery strike 1
        ProcessResult(status: ProcessResult.Status.networkFailure) // ends the turn
    ];

    auto result = agent.runToCompletion();

    assert(result.status == ProcessResult.Status.networkFailure,
            "the loop ends with the canned failure, not a nudge backstop");
    auto msgs = agent.chat.getMessages;
    assert(msgs.length == 2); // query + 1 recovery nudge
    assert(msgs[1].match!((Message m) => m.content.canFind("[SYSTEM RECOVERY - NOT USER INPUT]"),
            (_) => false), "ok without tool call: soft recovery nudge");
    assert(agent.continueStrikes == 1 && agent.keepReasoningStrikes == 0);
    assert(agent.chat.getDialogueHistory.length == 1, "nudge not in the dialogue projection");
    assert(agent.chat.getReasoningTrace.length == 0, "not in the trace projection");
    foreach (m; msgs[1 .. $])
        assert(m.match!((Message m) => !m.isUserQuery, (_) => false),
                "the nudge is harness traffic, not a user query");
    foreach (m; msgs[1 .. $])
        assert(turnIdOf(m) == 1, "the nudge continues the open turn");
}

// The compression nudge is config-gated end to end: below the configured
// threshold nothing fires; at/above it the shipped template is emitted with
// {{context_percent}} substituted (rendered %.1f, e.g. "83.0%"), and the
// one-shot compressNudgeSent keeps later rounds in the same compress cycle
// silent.
unittest {
    import std.array : replicate;
    import std.datetime : Clock;
    import std.file : mkdirRecurse, write;
    import std.format : format;

    auto now = Clock.currTime();
    auto tmpDir = format("llmfun_test/agent_compression_%d_%d", now.toUnixTime(), now.stdTime);
    mkdirRecurse(tmpDir);
    scope (exit)
        cleanupAgentTestDir(tmpDir);
    write(tmpDir ~ "/SUMMARY.md", "Summarize text.");
    writeDefaultNudgeFiles(tmpDir);

    // Below the threshold: no nudge.
    auto below = new CannedProcessAgent("integration", makeAgentTestConfig(tmpDir));
    below.addUserQuery("x".replicate(12_000)); // 6000/8192 = 73.2%
    below.syncContextFromChat(); // the loop's gates read prevStat
    below.canned = [ProcessResult(status: ProcessResult.Status.networkFailure)];
    below.runToCompletion();
    assert(below.chat.getMessages.length == 1, "below the threshold: no nudge");

    // At/above the threshold: the shipped template fires once with the
    // rendered percentage.
    auto agent = new CannedProcessAgent("integration", makeAgentTestConfig(tmpDir));
    agent.addUserQuery("x".replicate(13_600)); // 6800/8192 = 83.0%
    agent.syncContextFromChat();
    agent.canned = [ProcessResult(status: ProcessResult.Status.networkFailure)];
    auto result = agent.runToCompletion();
    assert(result.status == ProcessResult.Status.networkFailure,
            "the turn ends with the canned failure, not a compression backstop");
    auto msgs = agent.chat.getMessages;
    assert(msgs.length == 2); // query + compression nudge
    assert(msgs[1].match!((Message m) => m.content.canFind("[SYSTEM NUDGE - NOT USER INPUT]")
            && m.content.canFind("83.0%") && m.content.canFind("requestCompression"), (_) => false),
            "at/above threshold: shipped template with %.1f percent");
    assert(msgs[1].match!((Message m) => !m.content.canFind("{{"),
            (_) => false), "no placeholder survives substitution");

    // One-shot: further rounds in the same compress cycle stay silent.
    agent.canned = [ProcessResult(status: ProcessResult.Status.networkFailure)];
    agent.served = 0; // the canned index persists across runs
    agent.runToCompletion();
    agent.served = 0; // each run consumes one canned entry
    agent.runToCompletion();
    assert(agent.chat.getMessages.length == 2, "one-shot per compress cycle");
}

// The per-model compression threshold is a wholesale override: the
// model's own threshold governs. At the same 83% usage a model with 0.9 stays
// silent where the global default 0.8 fires, and a model with 0.6 fires
// earlier than the global default would.
unittest {
    import std.array : replicate;
    import std.datetime : Clock;
    import std.file : mkdirRecurse, write;
    import std.format : format;

    import llm.config : CodeModelConfig, NudgeConfig;

    auto now = Clock.currTime();
    auto tmpDir = format("llmfun_test/agent_compression_model_%d_%d", now.toUnixTime(), now.stdTime);
    mkdirRecurse(tmpDir);
    scope (exit)
        cleanupAgentTestDir(tmpDir);
    write(tmpDir ~ "/SUMMARY.md", "Summarize text.");
    writeDefaultNudgeFiles(tmpDir);

    auto llmConf = makeAgentTestConfig(tmpDir);
    CodeModelConfig modelCfg;
    modelCfg.modelName = "threshold-model";
    modelCfg.contextSize = 8192;
    NudgeConfig modelNudges;
    modelNudges.compression.threshold = 0.9;
    modelCfg.nudges = modelNudges.nullable;
    llmConf.codeModels ~= modelCfg;

    // threshold 0.9: silent at 83% (the global 0.8 would fire here).
    auto agent = new CannedProcessAgent("integration", llmConf);
    agent.resetModel(llmConf.codeModels[1]); // wholesale swap
    agent.addUserQuery("x".replicate(13_600)); // 83.0%
    agent.syncContextFromChat();
    agent.canned = [ProcessResult(status: ProcessResult.Status.networkFailure)];
    agent.runToCompletion();
    assert(agent.chat.getMessages.length == 1,
            "per-model threshold 0.9: silent at 83% where the global 0.8 fires");

    // threshold 0.6: fires at the same usage — earlier than the global 0.8.
    auto eager = new CannedProcessAgent("integration", makeAgentTestConfig(tmpDir));
    eager.addUserQuery("x".replicate(13_600));
    eager.syncContextFromChat();
    eager.canned = [ProcessResult(status: ProcessResult.Status.networkFailure)];
    eager.runToCompletion();
    assert(eager.chat.getMessages.length == 2,
            "per-model threshold 0.6 fires at 83% (the global 0.8 would not yet)");
    // Exact-at boundary (strict >): with threshold 0.75 the trigger point is
    // exactly 6144 tokens — at it the nudge stays silent, one token above
    // fires.
    CodeModelConfig boundCfg;
    boundCfg.modelName = "boundary-model";
    boundCfg.contextSize = 8192;
    NudgeConfig boundNudges;
    boundNudges.compression.threshold = 0.75;
    boundCfg.nudges = boundNudges.nullable;
    llmConf.codeModels ~= boundCfg;

    auto atBoundary = new CannedProcessAgent("integration", llmConf);
    atBoundary.resetModel(llmConf.codeModels[2]);
    atBoundary.addUserQuery("x".replicate(12_288)); // exactly 6144/8192 = 75.0%
    atBoundary.syncContextFromChat();
    atBoundary.canned = [
        ProcessResult(status: ProcessResult.Status.networkFailure)
    ];
    atBoundary.runToCompletion();
    assert(atBoundary.chat.getMessages.length == 1, "exactly at the threshold: no nudge (strict >)");

    auto pastBoundary = new CannedProcessAgent("integration", llmConf);
    pastBoundary.resetModel(llmConf.codeModels[2]);
    pastBoundary.addUserQuery("x".replicate(12_290)); // 6145/8192 tokens
    pastBoundary.syncContextFromChat();
    pastBoundary.canned = [
        ProcessResult(status: ProcessResult.Status.networkFailure)
    ];
    pastBoundary.runToCompletion();
    assert(pastBoundary.chat.getMessages.length == 2,
            "one token past the threshold: the nudge fires");
}

// `compression.enabled: false` silences the nudge at any usage: the
// guard returns before the threshold check, and loadNudgeTexts loads no
// template for the disabled kind (nudgeTexts_.compression stays empty — even a
// guard bug could not substitute anything).
unittest {
    import std.array : replicate;
    import std.datetime : Clock;
    import std.file : mkdirRecurse, write;
    import std.format : format;

    auto now = Clock.currTime();
    auto tmpDir = format("llmfun_test/agent_compression_off_%d_%d", now.toUnixTime(), now.stdTime);
    mkdirRecurse(tmpDir);
    scope (exit)
        cleanupAgentTestDir(tmpDir);
    write(tmpDir ~ "/SUMMARY.md", "Summarize text.");
    writeDefaultNudgeFiles(tmpDir);

    auto llmConf = makeAgentTestConfig(tmpDir);
    llmConf.nudges.compression.enabled = false;

    auto agent = new CannedProcessAgent("integration", llmConf);
    agent.addUserQuery("x".replicate(13_600)); // 83.0%
    agent.syncContextFromChat();
    agent.canned = [ProcessResult(status: ProcessResult.Status.networkFailure)];
    agent.runToCompletion();

    assert(agent.chat.getMessages.length == 1, "disabled compression: no nudge at any usage");
}

// Feedback warnings: gating only — the text stays owned by
// FeedbackEngine. The legacy constants are gone: intervalSecs and
// minToolCalls drive the two gates. The first-warning sentinel
// (toolCallWarnCounter == -1) fires regardless of minToolCalls once the
// interval has passed - the sentinel start is SysTime.init.
unittest {
    import std.datetime : Clock, SysTime;
    import std.file : mkdirRecurse, write;
    import std.format : format;
    import my.path : Path;
    import std.path : buildPath;

    auto now = Clock.currTime();
    auto tmpDir = format("llmfun_test/agent_feedback_%d_%d", now.toUnixTime(), now.stdTime);
    mkdirRecurse(tmpDir);
    scope (exit)
        cleanupAgentTestDir(tmpDir);
    write(tmpDir ~ "/SUMMARY.md", "Summarize text.");
    writeDefaultNudgeFiles(tmpDir);

    auto monitor = new MetricMonitor(buildPath(tmpDir, "metrics.jsonl").Path);

    size_t feedbackWarnings(CannedProcessAgent a) {
        size_t n;
        foreach (msg; a.chat.getMessages)
            n += msg.match!((Message m) => m.content.canFind("[SYSTEM MONITORING NOTE]")
                    ? 1 : 0, (_) => 0);
        return n;
    }

    StreamResponse.ToolCall[long] calls;
    calls[0] = StreamResponse.ToolCall(id: "1", name: "no_such_tool", arguments: "{}");

    // Sentinel: the first warning fires regardless of minToolCalls — the
    // interval has passed (lastToolCallWarning starts at SysTime.init).
    auto llmConf = makeAgentTestConfig(tmpDir);
    auto agent = new CannedProcessAgent("integration", llmConf, monitor);
    agent.handleToolCalls(null, calls);
    assert(agent.chat.getMessages.length == 3); // warning + tool call + tool response
    assert(feedbackWarnings(agent) == 1, "sentinel: the first warning fires");

    // Both gates closed by default (900 s interval, 50 min tool calls): the
    // second call stays warning-silent.
    agent.handleToolCalls(null, calls);
    assert(agent.chat.getMessages.length == 5);
    assert(feedbackWarnings(agent) == 1,
            "the second warning gates on intervalSecs AND minToolCalls");

    // minToolCalls gate alone blocks: intervalSecs 0 passes the clock gate
    // (rewound), but the counter is below the minimum.
    auto llmConfMin = makeAgentTestConfig(tmpDir);
    llmConfMin.nudges.feedback.intervalSecs = 0;
    auto gated = new CannedProcessAgent("integration", llmConfMin, monitor);
    gated.handleToolCalls(null, calls); // sentinel fires
    assert(feedbackWarnings(gated) == 1);
    gated.lastToolCallWarning = SysTime.init; // rewind: only minToolCalls gates now
    gated.handleToolCalls(null, calls);
    assert(feedbackWarnings(gated) == 1, "minToolCalls 50: the counter gate blocks");

    // minToolCalls boundary (strict >): with intervalSecs 0 the clock gate
    // always passes after the rewind, so the counter gate is exercised alone —
    // counter == minToolCalls is still blocked, minToolCalls + 1 fires.
    auto llmConfBound = makeAgentTestConfig(tmpDir);
    llmConfBound.nudges.feedback.intervalSecs = 0;
    llmConfBound.nudges.feedback.minToolCalls = 2;
    auto bound = new CannedProcessAgent("integration", llmConfBound, monitor);
    bound.handleToolCalls(null, calls); // sentinel fires
    assert(feedbackWarnings(bound) == 1);
    bound.lastToolCallWarning = SysTime.init; // keep the clock gate open
    foreach (i; 0 .. 2) // gates see counters 1, 2 — 2 == minToolCalls blocks
        bound.handleToolCalls(null, calls);
    assert(feedbackWarnings(bound) == 1, "counter == minToolCalls: equality blocks");
    bound.handleToolCalls(null, calls); // the gate sees 3 > 2: fires
    assert(feedbackWarnings(bound) == 2, "counter just above minToolCalls fires");

    // Both gates open (intervalSecs 0, minToolCalls 0): the second warning
    // fires (rewound start; the counter advanced past the minimum).
    auto llmConfOpen = makeAgentTestConfig(tmpDir);
    llmConfOpen.nudges.feedback.intervalSecs = 0;
    llmConfOpen.nudges.feedback.minToolCalls = 0;
    auto open = new CannedProcessAgent("integration", llmConfOpen, monitor);
    open.handleToolCalls(null, calls); // sentinel fires
    assert(feedbackWarnings(open) == 1);
    open.lastToolCallWarning = SysTime.init; // rewind
    open.handleToolCalls(null, calls);
    assert(feedbackWarnings(open) == 2, "intervalSecs 0 + minToolCalls 0: the second warning fires");

    // enabled: false silences the warnings at any usage.
    auto llmConfOff = makeAgentTestConfig(tmpDir);
    llmConfOff.nudges.feedback.enabled = false;
    auto off = new CannedProcessAgent("integration", llmConfOff, monitor);
    off.handleToolCalls(null, calls);
    assert(feedbackWarnings(off) == 0, "enabled: false — no warnings at all");
}
