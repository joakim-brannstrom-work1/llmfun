module llm.tool_call.pipeline;

import logger = std.logger;
import std.format : format;
import std.json : JSONValue;

import llm.tool_call;

mixin RegisterLlmFunctions;

interface PipelineControlContext {
    void setPipelineOutput(string output);
}

/// Tool for agents to communicate their output to downstream nodes.
/// This tool stores the output string in the pipeline's execution context
/// for edge propagation. It does NOT signal node completion (that is taskDone's role).
@Function("Stores the output of this node for downstream propagation in the pipeline. Use this to pass structured output to the next nodes.")
ExecuteFuncResult pipelineOutput(Context baseCtx, string output) @trusted {
    mixin(baseContextToSpecific!PipelineControlContext);
    ctx.setPipelineOutput(output);
    return ExecuteFuncResult(
            format!"Output stored (%s characters) for downstream propagation"(output.length), true);
}
