module llm.tool_call.skill;

import logger = std.logger;
import std.array : empty;
import std.conv : text;
import std.file : exists;
import std.string : strip;

import my.path : AbsolutePath;

import llm.skill;
import llm.tool_call.utility;
import llm.tool_call;

mixin RegisterLlmFunctions!();

interface SkillContext : Context {
    SkillManager getSkillManager();
    AbsolutePath workArea();
    bool isPathInsideWorkArea(AbsolutePath path);
}

struct LoadSkillParams {
    @ParamDescription("The name of the skill to load")
    string skillName;

    @ParamDescription(
            "Destination directory path inside the sandbox where the skill will be copied")
    string destDir;

    @ParamOptional @ParamDescription(
            "Force overwrite existing skill regardless of version (default: false)")
    bool overwrite;
}

/// First line and body of the successful loadSkill response. The first
/// line carries the source skill's frontmatter version so a stale-copy
/// load is detectable in one line; a skill whose frontmatter has
/// no version field renders as "(version unknown)" so the format is stable.
private pure string loadSkillSuccessMessage(string skillName, string version_,
        string destDir, string body) {
    const versionToken = version_.empty ? "unknown" : version_;
    return i"Skill loaded: $(skillName) (version $(versionToken))\nCopied to: $(destDir)\n\n$(body)"
        .text;
}

@("loadSkill success message first line carries the skill version")
unittest {
    import std.algorithm : canFind, endsWith, startsWith;

    // Versioned skill: the first line carries the frontmatter version.
    auto versioned = loadSkillSuccessMessage("code-task", "1.2.3", "skills/code-task", "body");
    assert(versioned.startsWith("Skill loaded: code-task (version 1.2.3)\n"));
    assert(versioned.canFind("Copied to: skills/code-task"));
    assert(versioned.endsWith("body"));

    // Versionless skill: stable "(version unknown)" token instead of omission.
    auto versionless = loadSkillSuccessMessage("code-task", "", "skills/code-task", "body");
    assert(versionless.startsWith("Skill loaded: code-task (version unknown)\n"));
    assert(versionless.canFind("Copied to: skills/code-task"));
    assert(versionless.endsWith("body"));
}

@Function("Load a skill by copying it into the workarea. "
        ~ "Use this when a skill's name or description matches the current task. "
        ~ "Copies the entire skill directory (SKILL.md, references/, scripts/, assets/) "
        ~ "to the destination. Returns the full SKILL.md body.")
ExecuteFuncResult loadSkill(Context baseCtx, LoadSkillParams params) {
    mixin(baseContextToSpecific!SkillContext);

    auto fallbackLoad() {
        try {
            // fallback to only loading the body but not the full skill
            auto mgr = ctx.getSkillManager();
            if (mgr is null) {
                return ExecuteFuncResult("error: skill manager not available", success: false);
            }
            auto body = mgr.loadSkillBody(params.skillName);
            return ExecuteFuncResult(i"Skill loaded: $(params.skillName)\nFailed to copy skill to: $(
                    params.destDir)\n\n$(body)".text, success: true);
        } catch (Exception e) {
            return ExecuteFuncResult(i"error: loading skill '$(params.skillName): $(e.msg)".text,
                    success: false);
        }
    };

    if (params.skillName.strip.empty) {
        return ExecuteFuncResult("error: empty parameter skillName", success: false);
    }

    if (!ctx.workArea.exists) {
        return fallbackLoad();
    }

    auto destDir_ = pathToWorkarea(ctx, params.destDir);
    if (!destDir_.valid) {
        return ExecuteFuncResult(destDir_.errorMsg, success: false);
    }

    auto mgr = ctx.getSkillManager();
    if (mgr is null) {
        return ExecuteFuncResult("error: skill manager not available", success: false);
    }

    string body;
    try {
        body = mgr.loadSkill(params.skillName, destDir_, params.overwrite);
    } catch (Exception e) {
        logger.trace(e.msg);
        return fallbackLoad();
    }

    // Fetched outside the try/catch above so a skillVersion failure would
    // surface as a loud error instead of a masked fallback "success" after the
    // copy has already succeeded. It cannot throw today: loadSkill throws
    // SkillNotFoundException unless the name is in skills.
    const version_ = mgr.skillVersion(params.skillName);
    if (body.length > 4096) {
        // TODO: should count grapheme so chinese letters work correctly
        body = i"$(body[0 .. 4096])\n\n... (truncated, skill is $(body.length) bytes total)".text;
    }
    return ExecuteFuncResult(loadSkillSuccessMessage(params.skillName,
            version_, params.destDir, body), success: true);
}
