"""LLM Evaluation Framework

A basic evaluation framework for testing llmfun agent responses.
"""

__version__ = "0.1.0"

from .test_loader import TestCase, GroundTruth, load_test_cases_from_file
from .evaluator import AgentResponse, evaluate_test_case, call_llmfun_agent
from .scorer import Scores, evaluate_batch, save_results

__all__ = [
    'TestCase',
    'GroundTruth', 
    'AgentResponse',
    'Scores',
    'load_test_cases_from_file',
    'evaluate_test_case',
    'call_llmfun_agent',
    'evaluate_batch',
    'save_results',
]