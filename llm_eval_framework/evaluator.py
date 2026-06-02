"""Evaluator module for calling llmfun agent and parsing responses.

This module handles:
- Calling the llmfun agent with prompts from test cases
- Parsing the agent's response to extract tools called
- Handling the chat history format
"""

import subprocess
import json
import re
import time
from dataclasses import dataclass
from typing import List, Optional, Dict
from pathlib import Path

# Tool to escalation level mapping
TOOL_ESCALATION_MAP = {
    "trackerLight": 1,
    "audibleWarning": 2,
    "strobeLight": 3,
    "humanOperator": 4,
    "callPatrol": 5,
}


@dataclass
class AgentResponse:
    """Response from the llmfun agent."""
    raw_output: str
    tools_called: List[str]
    escalation_level: int
    reasoning: str
    latency_ms: float


def call_llmfun_agent(prompt: str, history_file: Optional[Path] = None) -> AgentResponse:
    """Call the llmfun agent with a prompt.
    
    Args:
        prompt: The prompt to send to the agent
        history_file: Optional path to chat history JSON file
        
    Returns:
        AgentResponse object with parsed output
    """
    start_time = time.time()
    
    # Build the command
    cmd = ["llmfun", "agent", "-p", prompt]
    
    # If history file is provided, we could load it and pass context
    # For now, we just use the prompt directly
    
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=60
        )
        
        latency_ms = (time.time() - start_time) * 1000
        
        if result.returncode != 0:
            # Agent returned an error
            return AgentResponse(
                raw_output=result.stderr,
                tools_called=[],
                escalation_level=0,
                reasoning=f"Error: {result.stderr}",
                latency_ms=latency_ms
            )
        
        output = result.stdout
        
    except subprocess.TimeoutExpired:
        latency_ms = (time.time() - start_time) * 1000
        return AgentResponse(
            raw_output="",
            tools_called=[],
            escalation_level=0,
            reasoning="Timeout after 60 seconds",
            latency_ms=latency_ms
        )
    except Exception as e:
        latency_ms = (time.time() - start_time) * 1000
        return AgentResponse(
            raw_output="",
            tools_called=[],
            escalation_level=0,
            reasoning=f"Exception: {str(e)}",
            latency_ms=latency_ms
        )
    
    # Parse the response to extract tools
    tools_called = parse_tools_from_response(output)
    escalation_level = calculate_escalation_level(tools_called)
    reasoning = extract_reasoning(output)
    
    return AgentResponse(
        raw_output=output,
        tools_called=tools_called,
        escalation_level=escalation_level,
        reasoning=reasoning,
        latency_ms=latency_ms
    )


def parse_tools_from_response(response: str) -> List[str]:
    """Parse the agent response to extract tool names.
    
    Looks for patterns like:
    - "Calling tool: trackerLight"
    - "tool_call: audibleWarning"
    - Or any known tool names in the response
    
    Args:
        response: Raw output from the agent
        
    Returns:
        List of tool names found in the response
    """
    tools_found = []
    
    # Known tools to look for
    known_tools = list(TOOL_ESCALATION_MAP.keys())
    
    # Pattern 1: Look for explicit tool calls
    tool_patterns = [
        r'(?:calling|call|invoking|execute|using)\s+(?:tool\s+)?(\w+)',
        r'tool[:\s]+(\w+)',
        r'(\w+)\s+\(tool\)',
    ]
    
    for pattern in tool_patterns:
        matches = re.findall(pattern, response, re.IGNORECASE)
        for match in matches:
            if match in known_tools:
                if match not in tools_found:
                    tools_found.append(match)
    
    # Pattern 2: Direct mention of tool names
    for tool in known_tools:
        if tool.lower() in response.lower():
            if tool not in tools_found:
                tools_found.append(tool)
    
    return tools_found


def calculate_escalation_level(tools_called: List[str]) -> int:
    """Calculate the escalation level based on tools called.
    
    The escalation level is the maximum level among all tools called.
    
    Args:
        tools_called: List of tool names
        
    Returns:
        Escalation level (0 if no tools called)
    """
    if not tools_called:
        return 0
    
    max_level = 0
    for tool in tools_called:
        level = TOOL_ESCALATION_MAP.get(tool, 0)
        if level > max_level:
            max_level = level
    
    return max_level


def extract_reasoning(response: str) -> str:
    """Extract reasoning from the agent response.
    
    Args:
        response: Raw output from the agent
        
    Returns:
        Extracted reasoning text
    """
    # Look for reasoning patterns
    patterns = [
        r'reasoning[:\s]*(.+?)(?:\n\n|\n[A-Z]|$)',
        r'thought[:\s]*(.+?)(?:\n\n|\n[A-Z]|$)',
        r'analysis[:\s]*(.+?)(?:\n\n|\n[A-Z]|$)',
    ]
    
    for pattern in patterns:
        match = re.search(pattern, response, re.IGNORECASE | re.DOTALL)
        if match:
            return match.group(1).strip()
    
    # If no explicit reasoning found, return first few sentences
    sentences = response.split('.')
    if sentences:
        return sentences[0].strip() + '.'
    
    return response[:200]  # Return first 200 chars as fallback


def load_chat_history(history_file: Path) -> List[Dict[str, str]]:
    """Load chat history from a JSON file.
    
    Args:
        history_file: Path to the history JSON file
        
    Returns:
        List of message dictionaries with 'content' and 'role' keys
    """
    with open(history_file, 'r') as f:
        data = json.load(f)
    
    return data.get('messages', [])


def evaluate_test_case(test_case, history_file: Optional[Path] = None) -> AgentResponse:
    """Evaluate a single test case.
    
    Args:
        test_case: TestCase object
        history_file: Optional path to chat history
        
    Returns:
        AgentResponse from the evaluation
    """
    # Build the prompt from test case
    prompt = build_prompt(test_case)
    
    # Call the agent
    return call_llmfun_agent(prompt, history_file)


def build_prompt(test_case) -> str:
    """Build the prompt for a test case.
    
    Args:
        test_case: TestCase object
        
    Returns:
        Formatted prompt string
    """
    # Start with the test case prompt
    prompt = test_case.prompt
    
    # Add CNN probabilities if available
    if test_case.cnn_probabilities:
        probs_str = "\nCNN Classification Probabilities:\n"
        for cls, prob in test_case.cnn_probabilities.items():
            probs_str += f"- {cls}: {prob:.2%}\n"
        prompt = prompt + probs_str
    
    return prompt