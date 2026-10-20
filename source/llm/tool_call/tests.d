/// Unit tests for initParams parameter decoding.
module llm.tool_call.tests;

import std.algorithm : canFind;
import std.array : empty;
import std.json : JSONValue, parseJSON;

import llm.tool_call : Context, ExecuteFuncResult, Function, ParamOptional, initParams, toParams;

/// Sample params struct used by the initParams unit tests (was private in llm/tool_call/package.d; moved here since only these tests use it).
struct TestCmdParams {
    string[] command;
    @ParamOptional string cwd;
}

unittest {
    // Double-encoded array: a string containing JSON array integers must produce a hint that names the fix instead of a bare type-mismatch error.
    auto json = parseJSON(`{"command": "[1, 2]"}`);
    auto params = initParams!TestCmdParams(json, toParams!TestCmdParams);
    assert(params.errorMsg.length > 0);
    assert(params.errorMsg.canFind("array of strings"), params.errorMsg);
    assert(params.errorMsg.canFind("command"), params.errorMsg);
}

unittest {
    // Double-encoded array: a string containing JSON array text should decode the json array to a D string array
    auto json = parseJSON(`{"command": "[\"cd\", \"llmfun\"]"}`);
    auto params = initParams!TestCmdParams(json, toParams!TestCmdParams);
    assert(params.errorMsg.empty);
    assert(params.value.command[0] == "cd");
    assert(params.value.command[1] == "llmfun");
}

unittest {
    // A real array converts without error.
    auto okJson = parseJSON(`{"command": ["cd", "llmfun"]}`);
    auto okParams = initParams!TestCmdParams(okJson, toParams!TestCmdParams);
    assert(okParams.errorMsg.length == 0, okParams.errorMsg);
    assert(okParams.value.command == ["cd", "llmfun"]);
}

unittest {
    // A plain string (not JSON) for an array parameter gets the generic received/expected message.
    auto strJson = parseJSON(`{"command": "cd llmfun"}`);
    auto strParams = initParams!TestCmdParams(strJson, toParams!TestCmdParams);
    assert(strParams.errorMsg.canFind("received string"), strParams.errorMsg);
    assert(strParams.errorMsg.canFind("string[]"), strParams.errorMsg);
}

/// Empty params struct for the tags fixtures (nothing to decode).
struct TagsFixtureParams {
}

/// Fixture with a bare @Function UDA (the UDA has no tags channel); registered
/// by the unittests below via addFunction.
/// The resulting module-global registry entry is a deliberate, benign test leak (addFunction dedupes by name).
@Function("tags fixture tool") private void tagsUdaFixture(Context ctx, TagsFixtureParams params) {
}

/// (Context, JSONValue)-shaped callback matching the RegFunction.callback type.
private ExecuteFuncResult tagsFixtureRawCallback(Context ctx, JSONValue args) {
    return ExecuteFuncResult("ok", true);
}

unittest {
    // Registration leaves runtime tags empty: the UDA carries no tags, so a
    // registered RegFunction defaults to the empty tags array (only MCP
    // registration fills it).
    import std.algorithm : filter;
    import std.array : array;
    import std.conv : text;
    import std.traits : getUDAs;

    import llm.tool_call : RegFunction, addFunction, getFunctions, toParams;
    import llm.utility : toSnakeCase;

    enum uda = getUDAs!(tagsUdaFixture, Function)[0];
    addFunction(RegFunction(name: "tags_uda_fixture_tool", nameSnakeCase: toSnakeCase("tags_uda_fixture_tool"), desc: uda.desc,
            params: toParams!TagsFixtureParams, callback: &tagsFixtureRawCallback));
    auto hits = getFunctions.filter!(f => f.name == "tags_uda_fixture_tool").array;
    assert(hits.length == 1);
    assert(hits[0].tags.empty, text(hits[0].tags));
}

unittest {
    // Duplicate-name registration warns and ignores: first registration wins (order-proof).
    import std.algorithm : filter;
    import std.array : array;
    import std.conv : text;
    import std.traits : getUDAs;

    import llm.tool_call : RegFunction, addFunction, getFunctions, toParams;
    import llm.utility : toSnakeCase;

    enum uda = getUDAs!(tagsUdaFixture, Function)[0];
    addFunction(RegFunction(name: "tags_dup_probe", nameSnakeCase: toSnakeCase("tags_dup_probe"), desc: uda.desc,
            params: toParams!TagsFixtureParams, callback: &tagsFixtureRawCallback, tags: [
                "first"
    ]));
    addFunction(RegFunction(name: "tags_dup_probe", nameSnakeCase: toSnakeCase("tags_dup_probe"), desc: "other", params: toParams!TagsFixtureParams,
            callback: &tagsFixtureRawCallback, tags: ["second"]));
    auto hits = getFunctions.filter!(f => f.name == "tags_dup_probe").array;
    assert(hits.length == 1, "duplicate addFunction must be ignored");
    assert(hits[0].tags == ["first"], text(hits[0].tags));
}

unittest {
    // Snake-collision registration warns and ignores: the D names differ but
    // the snake (model-facing, dispatch) names collide - first registration
    // wins. Unique task2_ prefix: the global registry is shared module state
    // across the test binary (same deliberate-leak convention as the tags
    // fixtures above).
    import std.algorithm : filter;
    import std.array : array;

    import llm.tool_call : RegFunction, addFunction, getFunctions, toParams;

    addFunction(RegFunction(name: "task2_queryBestMatch", desc: "task2 snake probe", nameSnakeCase: "task2_query_best_match",
            params: toParams!TagsFixtureParams, callback: &tagsFixtureRawCallback));
    addFunction(RegFunction(name: "task2_query_Best_Match", desc: "task2 snake probe 2", nameSnakeCase: "task2_query_best_match",
            params: toParams!TagsFixtureParams, callback: &tagsFixtureRawCallback));
    auto hits = getFunctions.filter!(f => f.nameSnakeCase == "task2_query_best_match").array;
    assert(hits.length == 1, "snake-collision addFunction must be ignored");
    assert(hits[0].name == "task2_queryBestMatch");
}

@("toSnakeCase contract vectors")
unittest {
    import std.algorithm : filter;
    import std.array : array;

    import llm.tool_call : getFunctions;
    import llm.utility : toSnakeCase;

    // The 19 required vectors, verbatim from the task spec: 16 conversions
    // + the identity set {already_snake, my-tool, ""}.
    string[][] vectors = [
        ["taskDone", "task_done"], ["queryBestMatch", "query_best_match"],
        ["listRAGDatabases", "list_rag_databases"],
        ["removeTopicFromRAG", "remove_topic_from_rag"],
        ["pipelineOutput", "pipeline_output"], [
            "listToolTags", "list_tool_tags"
        ], ["loadImageApi", "load_image_api"], ["md5HashFile", "md5_hash_file"],
        ["base64Encode", "base64_encode"], ["md5Hash", "md5_hash"],
        ["already_snake", "already_snake"], ["my-tool", "my-tool"],
        ["mixed_Bar", "mixed_bar"], ["Foo", "foo"], ["ABC", "abc"], [
            "aBc", "a_bc"
        ], ["foo2Bar", "foo2_bar"], ["HTTP2", "http2"], ["", ""],
    ];
    foreach (v; vectors)
        assert(toSnakeCase(v[0]) == v[1], v[0] ~ " -> " ~ toSnakeCase(v[0]) ~ " (want " ~ v[1] ~ ")");

    // Idempotency over the whole table: the output charset has no uppercase,
    // so a second application hits the identity rule.
    foreach (v; vectors) {
        const once = toSnakeCase(v[0]);
        assert(toSnakeCase(once) == once, once ~ " is not idempotent");
    }

    // Registry spot-check: the mixin-registered tools in the test binary
    // carry the converted nameSnakeCase (conversion live, not stub identity).
    auto tdone = getFunctions.filter!(f => f.name == "taskDone").array;
    assert(tdone.length == 1, "taskDone missing from the test-binary registry");
    assert(tdone[0].nameSnakeCase == "task_done", tdone[0].nameSnakeCase);
    auto pout = getFunctions.filter!(f => f.name == "pipelineOutput").array;
    assert(pout.length == 1, "pipelineOutput missing from the test-binary registry");
    assert(pout[0].nameSnakeCase == "pipeline_output", pout[0].nameSnakeCase);
}
