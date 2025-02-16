module llm.tools2.date;

import std.datetime : Clock;

import llm.tool_call;

mixin RegisterLlmFunctions!();

@Function("Get current date time as ISO 8601 string")
ExecuteFuncResult currentDateTime(Context ctx) {
    return ExecuteFuncResult(Clock.currTime.toISOExtString, success: true);
}
