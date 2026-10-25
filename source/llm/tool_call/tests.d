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

@(
        "double-encoded array: a string holding JSON array integers yields a fix hint naming the parameter")
unittest {
    auto json = parseJSON(`{"command": "[1, 2]"}`);
    auto params = initParams!TestCmdParams(json, toParams!TestCmdParams);
    assert(params.errorMsg.length > 0);
    assert(params.errorMsg.canFind("array of strings"), params.errorMsg);
    assert(params.errorMsg.canFind("command"), params.errorMsg);
}

@("double-encoded array: a string holding JSON array text decodes to a D string array")
unittest {
    auto json = parseJSON(`{"command": "[\"cd\", \"llmfun\"]"}`);
    auto params = initParams!TestCmdParams(json, toParams!TestCmdParams);
    assert(params.errorMsg.empty);
    assert(params.value.command[0] == "cd");
    assert(params.value.command[1] == "llmfun");
}

@("a real JSON array converts without error")
unittest {
    auto okJson = parseJSON(`{"command": ["cd", "llmfun"]}`);
    auto okParams = initParams!TestCmdParams(okJson, toParams!TestCmdParams);
    assert(okParams.errorMsg.length == 0, okParams.errorMsg);
    assert(okParams.value.command == ["cd", "llmfun"]);
}

@("a plain string for an array parameter gets the generic received/expected message")
unittest {
    auto strJson = parseJSON(`{"command": "cd llmfun"}`);
    auto strParams = initParams!TestCmdParams(strJson, toParams!TestCmdParams);
    assert(strParams.errorMsg.canFind("received string"), strParams.errorMsg);
    assert(strParams.errorMsg.canFind("string[]"), strParams.errorMsg);
}

struct TagsFixtureParams {
}

@Function("tags fixture tool") private void tagsUdaFixture(Context ctx, TagsFixtureParams params) {
}

/// (Context, JSONValue)-shaped callback matching the RegFunction.callback type.
private ExecuteFuncResult tagsFixtureRawCallback(Context ctx, JSONValue args) {
    return ExecuteFuncResult("ok", true);
}

@("registration with a bare Function UDA leaves runtime tags empty")
unittest {
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

@("duplicate-name registration warns and is ignored: the first registration wins")
unittest {
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

@(
        "snake-collision registration warns and is ignored: same snake name, different D names, first wins")
unittest {
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
