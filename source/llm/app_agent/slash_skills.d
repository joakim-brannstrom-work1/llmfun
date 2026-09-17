/// Skill-management slash command: /skills.
module llm.app_agent.slash_skills;

import std.algorithm : filter;
import std.array : appender, array, empty, join;
import std.conv : text;
import std.format : format;
import std.functional : toDelegate;

import llm.app_agent; // AgentApp (cyclic package import, same pattern as slash.d)
import llm.app_agent.slash;
import llmfun_tui; // TuiChatMessageType_* (C binding)

package void registerSkillsCommands(ref SlashCommandRegistry registry) {
    auto ignore = registry.register(SlashCommand("skills", [],
            ["   /skills            List available skills"], SlashArgMode.none,
            150, toDelegate(&skillsHandler)));
}

/// `/skills`: list the loaded skills (uses the `formatSkillsList` helper).
private AgentStatus skillsHandler(ref AgentApp app, string arg) {
    app.sendChatMessage(formatSkillsList(app), TuiChatMessageType_Assistant);
    return AgentStatus.active;
}

/// Format the loaded-skill list for `/skills`.
private string formatSkillsList(ref AgentApp app) {
    if (app.skillManager_ is null) {
        return "No skill manager initialized.";
    }

    auto skills = app.skillManager_.getManifest();
    if (skills.empty) {
        return "No skills are currently loaded.";
    }

    auto alwaysApplyCount = skills.filter!(skill => skill.alwaysApply).array.length;
    auto lines = appender!(string[])();
    lines.put("Available skills:");
    lines.put("");

    foreach (skill; skills) {
        auto tag = skill.alwaysApply ? " [always-apply]" : "";
        auto desc = skill.description.length > 80
            ? skill.description[0 .. 77] ~ "..." : skill.description;
        lines.put(format("  %-25s %s", skill.name ~ tag, desc));
    }

    lines.put("");
    lines.put(i"$(skills.length) skills available, $(alwaysApplyCount) always-apply".text);
    return lines[].join("\n");
}

unittest {
    import llm.app_config : UserConfig;
    import std.algorithm.searching : canFind;

    // AgentApp's constructor installs a blocked UiMessenger (W5); the
    // unknown-command path dereferences uiMsg, so a real instance is needed.
    auto app = AgentApp(UserConfig.AgentChatConfig.init);
    SlashCommandRegistry reg;
    registerSkillsCommands(reg);

    // SlashArgMode.none is asserted directly via the registry getter — the
    // primary guard. execute() with an arg would NOT discriminate here:
    // the handler ignores its arg, so both the handler path and the
    // unknown-command path return AgentStatus.active (the none-with-arg →
    // unknown rule itself is pinned by slash.d's stub registry test).
    // Bare /skills IS dispatched as a smoke test: it exercises the handler,
    // formatSkillsList's null-manager early return, and the blocked
    // messenger (no agent_/rag dependency).
    assert(reg.argModeOf("skills") == SlashArgMode.none);
    assert(reg.execute(app, "/skills") == AgentStatus.active);

    // Help line is the verbatim string
    auto help = reg.helpText();
    assert(help.canFind("   /skills            List available skills"));
}
