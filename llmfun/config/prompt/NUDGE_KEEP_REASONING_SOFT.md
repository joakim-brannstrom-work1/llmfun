[SYSTEM NUDGE - NOT USER INPUT]
You stopped generating without calling a tool.

You have two possible states (choose ONLY ONE):
1. BLOCKED: You asked a question or need user input.
2. COMPLETE: You have fully solved the user's request.

EXECUTION RULES:
- If BLOCKED: Call taskDone immediately with your question.
- If COMPLETE: Call taskDone immediately with your final answer.

IMPORTANT: Do NOT describe your state in plain text. Your very next output MUST be a tool call (taskDone) or your next reasoning step/tool call. If you need to continue working, just output the next tool call right now.