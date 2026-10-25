module llm.skill;

import logger = std.logger;
import std.algorithm : filter, map, among;
import std.array : appender, join, Appender, empty;
import std.conv : to, text;
import std.file : exists, isDir, dirEntries, SpanMode, getSize, readText, rmdirRecurse;
import std.path : baseName, buildPath;
import std.range : array;
import std.regex : regex, matchFirst;
import std.string : strip, splitLines, split;
import std.typecons : Nullable, nullable;

import my.file : copyRecurse;
import my.path : AbsolutePath, Path;
import dyaml;

import llm.config : LlmConfig;
import llm.utility : computeContentHash;

SkillManager makeSkillManager(ref LlmConfig llmConf) {
    SkillManager rval;
    if (!llmConf.disableSkills) {
        try {
            rval = new SkillManager();
            rval.discover(llmConf.skillPaths.map!(a => AbsolutePath(a)).array);
        } catch (Exception e) {
            logger.errorf("Skill discovery failed: %s. Continuing without skills.", e.msg);
            rval = new SkillManager();
        }
    } else {
        rval = new SkillManager();
    }
    return rval;
}

struct Skill {
    string name;
    string description;
    string[] globs;
    bool alwaysApply;
    string version_;
    string license;
    string[] allowedTools;
    AbsolutePath dir;
    AbsolutePath skillMdPath;

    private string _cachedBody;

    /// Cached skill body (post-frontmatter content).
    string loadBody() {
        if (!_cachedBody.empty) {
            return _cachedBody;
        }
        _cachedBody = skillMdPath.readText.stripFrontmatter;
        return _cachedBody;
    }

    /// Uncached disk read. For debugging/reloading.
    string loadFullContent() const {
        return skillMdPath.readText;
    }
}

struct SkillResult {
    Skill skill;
    string error; // empty = success, non-empty = failure description
}

/// YAML frontmatter from SKILL.md.
struct SkillFrontmatter {
    string name;
    string description;
    string[] globs;
    bool alwaysApply; // defaults to false
    string version_;
    string license;
    string[] allowedTools;
    string[] parseErrors;
}

/// Semantic version struct.
struct SemVer {
    int[] value;

    int major() @safe pure nothrow const @nogc {
        if (value.length >= 1)
            return value[0];
        return 0;
    }

    int minor() @safe pure nothrow const @nogc {
        if (value.length >= 2)
            return value[1];
        return 0;
    }

    int patch() @safe pure nothrow const @nogc {
        if (value.length >= 3)
            return value[2];
        return 0;
    }

    bool valid() @safe pure nothrow const @nogc {
        return !value.empty;
    }
}

/// Parse a semantic version string. Handles X.Y.Z, X.Y, X formats.
/// Strips leading v/V prefix and pre-release suffixes at - or +.
/// Returns invalid SemVer (valid==false) on parse failure with a warning log.
SemVer parseSemVer(string verStr) @safe {
    auto s = verStr.strip;
    if (s.empty) {
        logger.warningf("Failed to parse version string: empty string");
        return SemVer.init;
    }

    if (s[0].among('v', 'V')) {
        s = s[1 .. $];
    }
    if (s.empty) {
        logger.warningf("Failed to parse version string: '%s' (empty after prefix strip)", verStr);
        return SemVer.init;
    }

    // Strip pre-release suffix at - or +
    foreach (i, c; s) {
        if (c == '-' || c == '+') {
            s = s[0 .. i];
            break;
        }
    }

    SemVer rval;
    foreach (p; s.split('.')) {
        try {
            rval.value ~= p.to!int;
        } catch (Exception e) {
            logger.warningf("Failed to parse version string: '%s' part '%s': %s", verStr, p, e.msg);
            return SemVer.init;
        }
    }

    return rval;
}

/// Compare two version strings.
/// Returns -1 (source older), 0 (equal), or +1 (source newer).
/// Edge cases:
///   - Both empty → 0
///   - Source empty, dest not → -1
///   - Source not empty, dest empty → +1
///   - Source unparseable → 0 (skip)
///   - Dest unparseable → +1 (copy)
int compareVersions(string sourceVersion, string destVersion) @safe {
    if (sourceVersion.empty && destVersion.empty) {
        return 0;
    }

    if (sourceVersion.empty) {
        return -1;
    }

    if (destVersion.empty) {
        return +1;
    }

    auto src = parseSemVer(sourceVersion);
    auto dst = parseSemVer(destVersion);

    if (!src.valid) {
        return 0;
    }

    if (!dst.valid) {
        return +1;
    }

    if (src.major != dst.major)
        return src.major > dst.major ? 1 : -1;
    if (src.minor != dst.minor)
        return src.minor > dst.minor ? 1 : -1;
    if (src.patch != dst.patch)
        return src.patch > dst.patch ? 1 : -1;

    return 0;
}

@(
        "parseSemVer accepts X.Y.Z, partial forms, v/V prefixes, pre-release and build suffixes, and rejects invalid forms")
unittest {
    // Basic format: X.Y.Z
    auto v1 = parseSemVer("1.2.3");
    assert(v1.valid);
    assert(v1.major == 1);
    assert(v1.minor == 2);
    assert(v1.patch == 3);

    // Partial format: X.Y
    auto v2 = parseSemVer("1.2");
    assert(v2.valid);
    assert(v2.major == 1);
    assert(v2.minor == 2);
    assert(v2.patch == 0);

    // Partial format: X
    auto v3 = parseSemVer("1");
    assert(v3.valid);
    assert(v3.major == 1);
    assert(v3.minor == 0);
    assert(v3.patch == 0);

    // Leading v prefix
    auto v4 = parseSemVer("v1.0.0");
    assert(v4.valid);
    assert(v4.major == 1);
    assert(v4.minor == 0);
    assert(v4.patch == 0);

    // Leading V prefix
    auto v5 = parseSemVer("V2.3.4");
    assert(v5.valid);
    assert(v5.major == 2);
    assert(v5.minor == 3);
    assert(v5.patch == 4);

    // Pre-release suffix at -
    auto v6 = parseSemVer("1.0.0-beta.1");
    assert(v6.valid);
    assert(v6.major == 1);
    assert(v6.minor == 0);
    assert(v6.patch == 0);

    // Pre-release suffix at +
    auto v7 = parseSemVer("1.0.0+build123");
    assert(v7.valid);
    assert(v7.major == 1);
    assert(v7.minor == 0);
    assert(v7.patch == 0);

    // Extra segments beyond major.minor.patch are ignored
    auto v8 = parseSemVer("1.2.3.4");
    assert(v8.valid);
    assert(v8.major == 1);
    assert(v8.minor == 2);
    assert(v8.patch == 3);

    // Unparseable returns invalid
    auto v9 = parseSemVer("abc");
    assert(!v9.valid);

    // Empty string returns invalid
    auto v10 = parseSemVer("");
    assert(!v10.valid);

    // Lone v prefix returns invalid
    auto v11 = parseSemVer("v");
    assert(!v11.valid);

    // Trailing dot returns invalid
    auto v12 = parseSemVer("1.2.3.");
    assert(!v12.valid);

    // Leading minus treated as pre-release delimiter, returns invalid
    auto v13 = parseSemVer("-1.2.3");
    assert(!v13.valid);
}

@(
        "compareVersions orders newer, older, and equal versions, handling empty and unparseable operands per the contract")
unittest {
    // Equal versions
    assert(compareVersions("1.0.0", "1.0.0") == 0);

    // Newer source
    assert(compareVersions("2.0.0", "1.0.0") == 1);
    assert(compareVersions("1.1.0", "1.0.0") == 1);
    assert(compareVersions("1.0.1", "1.0.0") == 1);

    // Older source
    assert(compareVersions("1.0.0", "2.0.0") == -1);
    assert(compareVersions("1.0.0", "1.1.0") == -1);
    assert(compareVersions("1.0.0", "1.0.1") == -1);

    // Both empty
    assert(compareVersions("", "") == 0);

    // Dest empty, source not -> source is "newer"
    assert(compareVersions("1.0.0", "") == +1);

    // Source empty, dest not -> source is "older"
    assert(compareVersions("", "1.0.0") == -1);

    // Source unparseable -> skip (0)
    assert(compareVersions("abc", "1.0.0") == 0);

    // Dest unparseable -> copy (+1)
    assert(compareVersions("1.0.0", "abc") == +1);

    // Both unparseable -> skip (0)
    assert(compareVersions("abc", "xyz") == 0);

    // Leading v prefix stripped
    assert(compareVersions("v1.0.0", "1.0.0") == 0);

    // Pre-release suffix stripped
    assert(compareVersions("1.0.0-beta", "1.0.0") == 0);

    // Partial versions equal
    assert(compareVersions("1.0.0", "1.0") == 0);
    assert(compareVersions("1", "1.0.0") == 0);

    // Extra segments ignored
    assert(compareVersions("1.2.3.4", "1.2.3") == 0);
}

/// Thrown when a skill is not found.
class SkillNotFoundException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

/// Extract YAML between `---` delimiters. Opening `---` must be first line.
/// Returns "" if no frontmatter. Stops at first `---` line in YAML content.
string extractYamlFrontMatter(string content) {
    auto lines = content.splitLines;

    if (lines.empty || lines[0].strip != "---") {
        return "";
    }

    string[] yamlLines;
    foreach (line; lines[1 .. $]) {
        auto trimmed = line.strip;
        if (trimmed == "---") {
            return yamlLines.join("\n");
        }
        yamlLines ~= line;
    }

    return "";
}

/// Parse YAML frontmatter. Populates parseErrors on failure (logged at warning).
SkillFrontmatter parseFrontmatter(string content) {
    auto fm = SkillFrontmatter();

    auto yamlBlock = extractYamlFrontMatter(content);
    if (yamlBlock.empty) {
        return fm;
    }

    try {
        auto node = Loader.fromString(yamlBlock).load();

        if (node.containsKey("name"))
            fm.name = node["name"].as!string;

        if (node.containsKey("description"))
            fm.description = node["description"].as!string;

        if (node.containsKey("alwaysApply"))
            fm.alwaysApply = node["alwaysApply"].as!bool;

        if (node.containsKey("version"))
            fm.version_ = node["version"].as!string;

        if (node.containsKey("license"))
            fm.license = node["license"].as!string;

        if (node.containsKey("globs")) {
            foreach (string item; node["globs"])
                fm.globs ~= item;
        }

        if (node.containsKey("allowed-tools")) {
            foreach (string item; node["allowed-tools"])
                fm.allowedTools ~= item;
        }
    } catch (Exception e) {
        logger.warningf("Failed to parse skill frontmatter: %s", e.msg);
        fm.parseErrors ~= e.msg;
    }

    return fm;
}

/// Remove YAML frontmatter, returning trimmed body. Stops at first `---` in YAML.
string stripFrontmatter(string content) {
    auto lines = content.splitLines;
    bool foundOpening = false;
    bool foundClosing = false;
    size_t startIdx = 0;

    foreach (i, line; lines) {
        auto trimmed = line.strip;
        if (!foundOpening) {
            if (trimmed == "---") {
                foundOpening = true;
            }
        } else if (!foundClosing) {
            if (trimmed == "---") {
                foundClosing = true;
                startIdx = i + 1;
            }
        }
    }

    if (!foundOpening || !foundClosing) {
        return content.strip;
    }

    auto bodyLines = lines[startIdx .. $];
    return bodyLines.join("\n").strip;
}

class SkillManager {
    private {
        Skill[string] skills; // name -> Skill, first wins
        string manifestCache;
        size_t skippedCount;
    }

    /// Discover skills from search paths. Clears previous skills (idempotent).
    void discover(AbsolutePath[] searchPaths) {
        skills = null;
        manifestCache = null;
        skippedCount = 0;

        try {
            bool[string] scanned;

            foreach (path; searchPaths.filter!(a => a.exists && a.isDir)) {
                if (path !in scanned) {
                    logger.tracef("Scanning '%s' for skills", path);
                    scanDirectory(path);
                    scanned[path] = true;
                }
            }

            foreach (path; searchPaths.filter!(a => !a.exists || !a.isDir)) {
                logger.tracef(
                        "Unable to read skills from '%s' because either the path do not exist or it isn't a directory",
                        path);
            }
        } catch (Exception e) {
            logger.errorf("Error during skill discovery: %s", e.msg);
            // Non-critical; continue without skills
            return;
        }

        auto alwaysApplyCount = skills.values.filter!(s => s.alwaysApply).array.length;
        logger.infof("Discovered %d skills (%d always-apply, %d skipped)",
                skills.length, alwaysApplyCount, skippedCount);
    }

    private void scanDirectory(Path path) {
        try {
            foreach (entry; dirEntries(path.toString, SpanMode.shallow)) {
                if (!entry.isDir) {
                    continue;
                }

                auto skillMdPath = AbsolutePath(buildPath(entry.name, "SKILL.md"));
                if (!exists(skillMdPath.toString)) {
                    continue;
                }

                auto result = parseSkillMd(skillMdPath);
                if (!result.error.empty) {
                    logger.warningf("Skipping skill at %s: %s", skillMdPath, result.error);
                    skippedCount++;
                    continue;
                }

                if (result.skill.name in skills) {
                    logger.warningf("Duplicate skill name '%s' at %s (first occurrence at %s wins)",
                            result.skill.name, skillMdPath, skills[result.skill.name].skillMdPath);
                    skippedCount++;
                    continue;
                }

                skills[result.skill.name] = result.skill;
            }
        } catch (Exception e) {
            logger.warningf("Error scanning directory %s: %s", path, e.msg);
        }
    }

    private SkillResult parseSkillMd(AbsolutePath skillMdPath) {
        /// Validate skill name: 1-64 lowercase alphanumeric chars with hyphens (no leading/trailing/consecutive).
        bool isValidName(string name) {
            if (name.length > 64) {
                return false;
            }

            static auto namePattern = regex(r"^[a-z0-9]+(-[a-z0-9]+)*$");
            return cast(bool) matchFirst(name, namePattern);
        }

        enum size_t maxSize = 1_048_576; // 1MB
        auto fileSize = getSize(skillMdPath.toString);
        if (fileSize > maxSize) {
            return SkillResult(Skill.init, i"SKILL.md too large: $(fileSize) bytes (max $(maxSize))"
                    .text);
        }

        auto content = readText(skillMdPath.toString);
        auto fm = parseFrontmatter(content);

        if (fm.name.empty) {
            return SkillResult(Skill.init, "missing required 'name' field");
        }
        if (fm.description.empty) {
            return SkillResult(Skill.init, "missing required 'description' field");
        }

        if (!isValidName(fm.name)) {
            return SkillResult(Skill.init, i"invalid skill name '$(fm.name)': must be 1-64 lowercase alphanumeric chars with hyphens (no leading/trailing/consecutive hyphens)"
                    .text);
        }

        // Non-fatal warning only
        auto parentDir = skillMdPath.dirName;
        auto dirBaseName = parentDir.toString.baseName;
        if (dirBaseName != fm.name) {
            logger.warningf("Skill directory name '%s' does not match skill name '%s' (at %s)",
                    dirBaseName, fm.name, skillMdPath);
        }

        auto skill = Skill();
        skill.name = fm.name;
        skill.description = fm.description;
        skill.globs = fm.globs;
        skill.alwaysApply = fm.alwaysApply;
        skill.version_ = fm.version_;
        skill.license = fm.license;
        skill.allowedTools = fm.allowedTools;
        skill.dir = parentDir;
        skill.skillMdPath = skillMdPath;

        return SkillResult(skill, "");
    }

    /// Discovered skills. Order not guaranteed.
    Skill[] getManifest() {
        return skills.values.array;
    }

    Skill[] getAlwaysApplySkills() @safe {
        return skills.values.filter!(s => s.alwaysApply).array;
    }

    /// Load cached skill body by name. Throws SkillNotFoundException if missing.
    string loadSkillBody(string name) {
        if (name !in skills) {
            throw new SkillNotFoundException(i"Skill not found: $(name)".text);
        }
        return skills[name].loadBody();
    }

    /// Frontmatter version of a discovered skill. Throws
    /// SkillNotFoundException when no skill with that name is loaded.
    string skillVersion(string name) {
        if (name !in skills) {
            throw new SkillNotFoundException(i"Skill not found: $(name)".text);
        }
        return skills[name].version_;
    }

    /// Verify that destDir contains an exact copy of sourceDir after a
    /// copyRecurse call. Walks both trees recursively (files only, relative
    /// paths reported in sorted order) and throws Exception listing missing,
    /// extra, and content-mismatched files on any mismatch. Every file's
    /// content is hashed (computeContentHash) and the hashes compared, so a
    /// same-size partial copy is caught like any other. Files must be UTF-8
    /// text; anything else fails verification loudly. An unreadable entry
    /// during the walk counts as a mismatch (fail loudly, not silently).
    /// Returns the number of files verified (the source tree's file
    /// count) on success.
    private size_t verifyCopiedTree(Path sourceDir, Path destDir) {
        long[string] srcHashes; // relative path -> content hash, source tree
        long[string] dstHashes; // relative path -> content hash, destination tree

        void collectHashes(string root, ref long[string] hashes) {
            foreach (entry; dirEntries(root, SpanMode.depth).filter!(a => !a.isDir)) {
                hashes[entry.name[root.length + 1 .. $]] = computeContentHash(readText(entry.name));
            }
        }

        try {
            collectHashes(sourceDir, srcHashes);
            collectHashes(destDir, dstHashes);
        } catch (Exception e) {
            throw new Exception(text("Skill copy verification could not read the source or copied tree: ",
                    e.msg, ". Fix the filesystem access and re-run the loadSkill call."));
        }

        string[] missing;
        string[] extra;
        string[] contentMismatched;

        foreach (rel, hash; srcHashes) {
            if (rel !in dstHashes) {
                missing ~= rel;
            } else if (dstHashes[rel] != hash) {
                contentMismatched ~= rel;
            }
        }
        foreach (rel; dstHashes.keys.filter!(a => a !in srcHashes)) {
            extra ~= rel;
        }

        import std.algorithm : sort;

        missing.sort();
        extra.sort();
        contentMismatched.sort();

        if (missing.empty && extra.empty && contentMismatched.empty) {
            return srcHashes.length;
        }

        auto ap = appender!string();
        ap.put(text("Skill copy verification failed: destination tree '",
                destDir, "' does not match source tree '", sourceDir, "'."));
        if (!missing.empty) {
            ap.put(" Missing: ");
            ap.put(missing.join(", "));
        }
        if (!extra.empty) {
            ap.put(" Unexpected extra: ");
            ap.put(extra.join(", "));
        }
        if (!contentMismatched.empty) {
            ap.put(" Content mismatch: ");
            ap.put(contentMismatched.join(", "));
        }
        ap.put(text(" The destination was left partially updated (overwrite) or removed (fresh destination); remove any leftover destination tree and re-run the loadSkill call to retry."));

        throw new Exception(ap[]);
    }

    /// Copy skill dir to destDir (idempotent). Returns skill body.
    /// The skill's frontmatter version is available to the caller via
    /// skillVersion().
    /// Throws: SkillNotFoundException, Exception (empty destDir, wrong skill,
    /// malformed SKILL.md, copy verification mismatch).
    /// Error taxonomy: copy/verification failures here surface to the agent as
    /// errorType "copy_verification_mismatch" (loadSkill does NOT route
    /// through classifyEditError).
    string loadSkill(string name, Path destDir, bool overwrite) {
        if (name !in skills) {
            throw new SkillNotFoundException(i"Skill not found: $(name)".text);
        }
        if (destDir.empty || destDir.strip.empty) {
            throw new Exception("destDir must not be empty");
        }

        auto skill = skills[name];

        bool freshlyCopied;
        if (!exists(destDir)) {
            scope (failure) {
                if (exists(destDir)) {
                    try {
                        rmdirRecurse(destDir);
                        logger.warningf("Removed partial skill copy at %s after copy/verification failure",
                                destDir);
                    } catch (Exception e) {
                        logger.warningf("Failed to remove partial skill copy at %s: %s",
                                destDir, e.msg);
                    }
                }
            }
            copyRecurse(skill.dir, destDir);
            verifyCopiedTree(skill.dir, destDir);
            logger.tracef("Copied skill '%s' to %s", name, destDir);
            freshlyCopied = true;
        }

        const existingSkillMd = buildPath(destDir, "SKILL.md");

        void verifySkill() {
            if (!exists(existingSkillMd)) {
                throw new Exception(i"Destination '$(destDir)' exists but does not contain a valid SKILL.md. The parameter destDir should be $(
                        destDir)/$(name)".text);
            }

            const existingContent = readText(existingSkillMd);
            const existingFm = parseFrontmatter(existingContent);
            if (!existingFm.parseErrors.empty) {
                throw new Exception(i"Cannot verify existing skill at '$(destDir)': SKILL.md parse error: $(
                        existingFm.parseErrors.join(", "))".text);
            }
            if (!existingFm.name.empty && existingFm.name != name) {
                throw new Exception(i"Destination '$(destDir)' contains skill '$(existingFm.name)', not '$(
                        name)'".text);
            }
        }

        // Same skill at destination - compare versions
        const existingFm = parseFrontmatter(readText(existingSkillMd));
        const cmp = compareVersions(skill.version_, existingFm.version_);
        if (cmp > 0 || overwrite) {
            if (freshlyCopied) {
                // The fresh-destination branch above already produced a
                // verified tree; re-copying it would be pure waste.
                logger.tracef("Skill '%s' was already copied fresh to %s, skipping redundant copy",
                        name, destDir);
            } else {
                copyRecurse(skill.dir, destDir);
                const copiedFiles = verifyCopiedTree(skill.dir, destDir);
                logger.tracef("Overwrite copied %d files from '%s' to %s",
                        copiedFiles, skill.dir, destDir);
                logger.infof("Overwrote skill '%s' at %s", name, destDir);
            }
        } else {
            logger.tracef("Skill '%s' already present at %s with version %s (source version %s), skipping copy",
                    name, destDir, existingFm.version_, skill.version_);
        }

        verifySkill();

        return skill.loadBody();
    }

    /// Cached XML manifest. maxEntries=0 means unlimited. No truncation notice if clipped.
    string getManifestXml(long maxEntries) {
        import std.algorithm : sort;

        if (!manifestCache.empty) {
            return manifestCache;
        }

        auto allSkills = skills.values.array;
        long count;
        auto skillsToInclude = allSkills;
        if (maxEntries > 0 && allSkills.length > cast(size_t) maxEntries) {
            skillsToInclude = allSkills[0 .. cast(size_t) maxEntries];
            count = cast(long) maxEntries;
        } else {
            count = cast(long) allSkills.length;
        }

        auto ap = appender!string();
        ap.put("\n\n\n");
        ap.put("[SKILLS]\n");
        ap.put("Use the loadSkill tool to load the full instructions for any skill when its description matches the current task.\n");
        ap.put("\n");
        foreach (skill; skillsToInclude.sort!((a, b) => a.name < b.name)) {
            ap.put(i"- $(skill.name): $(skill.description)\n\n".text);
        }

        manifestCache = ap[];
        return manifestCache;
    }
}

/// Markdown block of always-apply skill bodies. Token budget via ApproxTokenSize.
/// maxTokens<=0 means unlimited (warned once). Appends warning if skills omitted.
string buildAlwaysApplyBlock(Skill[] alwaysApply, long maxTokens) {
    import llm.config : ApproxTokenSize;

    if (alwaysApply.empty) {
        return null;
    }

    bool unlimited = maxTokens <= 0;
    static bool unlimitedWarned;
    if (unlimited && !unlimitedWarned) {
        unlimitedWarned = true;
        logger.warningf("maxAlwaysApplyTokens is %d, treating as unlimited. Consider setting a positive value to prevent context exhaustion.",
                maxTokens);
    }

    auto ap = appender!string();
    long totalTokens = 0;
    size_t omittedCount = 0;

    foreach (skill; alwaysApply) {
        auto body = skill.loadBody();
        auto block = i"## Skill: $(skill.name)\n$(body)\n\n".text;
        auto estimatedTokens = cast(long)(block.length / ApproxTokenSize);

        if (!unlimited && totalTokens + estimatedTokens > maxTokens) {
            omittedCount++;
            logger.warningf("Omitting always-apply skill '%s' due to token budget (limit: %d tokens, would add ~%d)",
                    skill.name, maxTokens, estimatedTokens);
            continue;
        }

        ap.put(block);
        if (!unlimited) {
            totalTokens += estimatedTokens;
        }
    }

    if (omittedCount > 0) {
        ap.put("[Warning: ");
        ap.put(i"$(omittedCount) always-apply skills omitted due to token budget (limit: $(
                maxTokens) tokens). Remaining skills are still available via loadSkill.".text);
        ap.put("]\n");
    }

    return ap[];
}

@("skillVersion returns the frontmatter version and throws for unknown names")
unittest {
    auto mgr = new SkillManager();
    auto skill = Skill();
    skill.name = "code-task";
    skill.description = "test skill";
    skill.version_ = "1.2.3";
    mgr.skills[skill.name] = skill;

    assert(mgr.skillVersion("code-task") == "1.2.3");

    skill.version_ = "";
    mgr.skills[skill.name] = skill;
    assert(mgr.skillVersion("code-task").empty);

    bool threw;
    try {
        mgr.skillVersion("no-such-skill");
    } catch (SkillNotFoundException e) {
        threw = true;
    }
    assert(threw);
}

version (unittest) {

    /// Write `content` to `path`, creating parent directories. Test helper.
    private void writeSkillFile(string path, string content) {
        import std.file : mkdirRecurse, write;
        import std.path : dirName;

        mkdirRecurse(dirName(path));
        write(path, content);
    }

    /// Relative paths (sorted) of all files under `root`. Test helper. Assumes
    /// `root` has no trailing separator (true for all call sites), so the slice
    /// strips exactly the root prefix plus one separator.
    private string[] listFilesRelative(string root) {
        import std.algorithm : filter, map, sort;
        import std.array : array;
        import std.file : dirEntries, isDir, SpanMode;

        return dirEntries(root, SpanMode.depth).filter!(a => !a.isDir)
            .map!(a => a.name[root.length + 1 .. $])
            .array
            .sort().array;
    }

}

@("loadSkill overwrite=true replaces the whole tree: references/ and scripts/ land, no stale v1 content, no leftover backup dir")
unittest {
    import std.algorithm : canFind;
    import llm.test_util : testArea;

    auto area = testArea("t3_overwrite");
    scope (exit)
        area.cleanup();

    // Source skill v1: SKILL.md + notes.md only.
    auto srcDir = buildPath(area.toString, "src");
    writeSkillFile(buildPath(srcDir, "SKILL.md"),
            "---\nname: regress-skill-a\nversion: 1.0.0\ndescription: regression\n---\n\nv1 body\n");
    writeSkillFile(buildPath(srcDir, "notes.md"), "v1 notes\n");

    auto mgr = new SkillManager();
    mgr.discover([AbsolutePath(area.toString)]);

    auto destDir = Path(buildPath(area.toString, "skills", "regress-skill-a"));
    const v1Body = mgr.loadSkill("regress-skill-a", destDir, false);
    assert(v1Body.canFind("v1 body"));
    assert(!exists(buildPath(destDir.toString, "references")));

    // v2: same relative-path set plus references/ and scripts/, every file's
    // content changed.
    writeSkillFile(buildPath(srcDir, "SKILL.md"),
            "---\nname: regress-skill-a\nversion: 2.0.0\ndescription: regression\n---\n\nv2 body\n");
    writeSkillFile(buildPath(srcDir, "notes.md"), "v2 notes\n");
    writeSkillFile(buildPath(srcDir, "references", "rules.md"), "v2 rules\n");
    writeSkillFile(buildPath(srcDir, "scripts", "run.sh"), "v2 script\n");

    const v2Body = mgr.loadSkill("regress-skill-a", destDir, true);

    // The v2 body is returned, not the stale v1 body.
    assert(v2Body.canFind("v2 body"));
    assert(!v2Body.canFind("v1 body"));
    // references/ and scripts/ are present at the destination.
    assert(readText(buildPath(destDir.toString, "references", "rules.md")) == "v2 rules\n");
    assert(readText(buildPath(destDir.toString, "scripts", "run.sh")) == "v2 script\n");
    // No stale old-version content survives at the destination.
    assert(readText(buildPath(destDir.toString, "notes.md")) == "v2 notes\n");
    assert(!readText(buildPath(destDir.toString, "SKILL.md")).canFind("v1 body"));
    assert(listFilesRelative(destDir.toString) == [
        "SKILL.md", "notes.md", "references/rules.md", "scripts/run.sh"
    ]);
    // The pre-rework implementation renamed destDir onto a leftover backup
    // dir; assert none exists now.
    assert(!exists(destDir.toString ~ ".llmfun_backup"));

    // A second overwrite must also succeed: the old code renamed the
    // destination onto the leftover backup dir, which fails once that dir
    // exists.
    const v2Body2 = mgr.loadSkill("regress-skill-a", destDir, true);
    assert(v2Body2.canFind("v2 body"));
    assert(listFilesRelative(destDir.toString) == [
        "SKILL.md", "notes.md", "references/rules.md", "scripts/run.sh"
    ]);
}

@("verifyCopiedTree throws on an overwrite-path mismatch: names the extra file and the retry step; destDir is kept for retry")
unittest {
    import std.algorithm : canFind;
    import llm.test_util : testArea;

    auto area = testArea("t3_extra");
    scope (exit)
        area.cleanup();

    // Source skill v1.
    auto srcDir = buildPath(area.toString, "src-a");
    writeSkillFile(buildPath(srcDir, "SKILL.md"),
            "---\nname: regress-skill-a\nversion: 1.0.0\ndescription: regression\n---\n\nv1 body\n");
    writeSkillFile(buildPath(srcDir, "notes.md"), "v1 notes\n");

    auto mgr = new SkillManager();
    mgr.discover([AbsolutePath(area.toString)]);

    auto destDir = Path(buildPath(area.toString, "skills", "regress-skill-a"));
    mgr.loadSkill("regress-skill-a", destDir, false);

    // Inject a mismatch at the destination: an extra file the source does not
    // have. copyRecurse never touches it, so only the post-copy verification
    // can catch it (a post-copy destination injection is the only reachable
    // window between copyRecurse and verifyCopiedTree on the overwrite path;
    // deleting or corrupting a copied file is not an injection - copyRecurse
    // re-copies/re-writes every source file before verification runs, and the
    // Missing/Content-mismatch branches are unreachable through loadSkill).
    writeSkillFile(buildPath(destDir.toString, "extra.txt"), "injected\n");

    // The verification failure is loud, names the mismatched file, and says
    // what to do next.
    bool threw;
    string msg;
    try {
        mgr.loadSkill("regress-skill-a", destDir, true);
    } catch (Exception e) {
        threw = true;
        msg = e.msg;
    }
    assert(threw);
    assert(msg.canFind("Unexpected extra"));
    assert(msg.canFind("extra.txt"));
    assert(msg.canFind("re-run the loadSkill call"));
    // The overwrite path does NOT remove the destination tree (in contrast to
    // the fresh-destination failure path): the leftover tree is exactly what
    // the error message tells the agent to remove before re-running.
    assert(exists(destDir));
    assert(exists(buildPath(destDir.toString, "SKILL.md")));
}
