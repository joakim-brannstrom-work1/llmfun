"""Scoring module for evaluating LLM responses.

Calculates various metrics based on expected vs actual results.
"""

from dataclasses import dataclass
from typing import List, Dict, Tuple
import json
from pathlib import Path

from test_loader import TestCase, GroundTruth
from evaluator import AgentResponse


@dataclass
class Scores:
    """Scores for a single test case evaluation."""
    tool_selection_accuracy: float
    escalation_level_accuracy: float
    threat_detection_score: float
    composite_score: float
    is_correct: bool
    failure_type: str = ""


def calculate_tool_selection_accuracy(
    expected_tools: List[str], 
    actual_tools: List[str]
) -> float:
    """Calculate tool selection accuracy.
    
    Args:
        expected_tools: List of expected tool names
        actual_tools: List of actual tool names from agent
        
    Returns:
        Accuracy score from 0.0 to 1.0
    """
    if not expected_tools and not actual_tools:
        return 1.0
    
    if not expected_tools:
        return 0.0
    
    if not actual_tools:
        return 0.0
    
    expected_set = set(expected_tools)
    actual_set = set(actual_tools)
    
    # Exact match
    if expected_set == actual_set:
        return 1.0
    
    # Subset match (agent called more tools than expected - over-escalation)
    if expected_set.issubset(actual_set):
        overlap = len(expected_set & actual_set)
        union = len(expected_set | actual_set)
        return 0.7 * (overlap / union)
    
    # Superset match (agent called fewer tools than expected - under-escalation)
    if actual_set.issubset(expected_set):
        overlap = len(expected_set & actual_set)
        union = len(expected_set | actual_set)
        return 0.5 * (overlap / union)
    
    # Partial overlap
    overlap = len(expected_set & actual_set)
    union = len(expected_set | actual_set)
    
    if union == 0:
        return 0.0
    
    return 0.5 * (overlap / union)


def calculate_escalation_level_accuracy(
    expected_level: int, 
    actual_level: int
) -> float:
    """Calculate escalation level accuracy.
    
    Args:
        expected_level: Expected escalation level
        actual_level: Actual escalation level from agent
        
    Returns:
        Accuracy score from 0.0 to 1.0
    """
    if expected_level == actual_level:
        return 1.0
    
    diff = abs(expected_level - actual_level)
    
    if diff == 1:
        return 0.7
    elif diff == 2:
        return 0.4
    else:  # diff >= 3
        return 0.0


def calculate_threat_detection_score(
    expected_tools: List[str],
    actual_tools: List[str],
    threat_present: bool
) -> float:
    """Calculate threat detection score (TP/TN/FP/FN based).
    
    Args:
        expected_tools: Expected tools (empty = no threat)
        actual_tools: Actual tools from agent
        threat_present: Whether a threat actually exists in the test case
        
    Returns:
        Score with penalties for false positives/negatives
    """
    has_actual_response = len(actual_tools) > 0
    
    if threat_present and has_actual_response:
        # True Positive: Threat present and agent detected it
        return 1.0
    elif not threat_present and not has_actual_response:
        # True Negative: No threat and agent did nothing
        return 1.0
    elif not threat_present and has_actual_response:
        # False Positive: No threat but agent escalated (penalty)
        return -2.0
    else:  # threat_present and not has_actual_response
        # False Negative: Threat present but agent missed it (severe penalty)
        return -3.0


def calculate_composite_score(
    tool_selection: float,
    escalation_accuracy: float,
    threat_detection: float,
    weights: Dict[str, float] = None
) -> float:
    """Calculate composite score from individual metrics.
    
    MVP simplified weights:
    - 40% tool selection accuracy
    - 30% escalation level accuracy
    - 30% threat detection score
    
    Args:
        tool_selection: Tool selection accuracy
        escalation_accuracy: Escalation level accuracy
        threat_detection: Threat detection score
        weights: Optional custom weights
        
    Returns:
        Composite score from 0.0 to 1.0
    """
    if weights is None:
        weights = {
            'tool_selection': 0.40,
            'escalation': 0.30,
            'threat_detection': 0.30,
        }
    
    # Normalize threat detection from (-3, 1) to (0, 1)
    normalized_threat = (threat_detection + 3) / 4  # Maps -3->0, 1->1
    
    composite = (
        weights['tool_selection'] * tool_selection +
        weights['escalation'] * escalation_accuracy +
        weights['threat_detection'] * normalized_threat
    )
    
    return min(1.0, max(0.0, composite))


def evaluate_test_case(
    test_case: TestCase,
    response: AgentResponse
) -> Scores:
    """Evaluate a single test case.
    
    Args:
        test_case: The test case with expected results
        response: The agent's response
        
    Returns:
        Scores object with evaluation results
    """
    expected_tools = test_case.ground_truth.expected_tools
    expected_level = test_case.ground_truth.expected_escalation_level
    
    # Calculate individual metrics
    tool_selection = calculate_tool_selection_accuracy(
        expected_tools, 
        response.tools_called
    )
    
    escalation_accuracy = calculate_escalation_level_accuracy(
        expected_level,
        response.escalation_level
    )
    
    # Determine if threat is present
    threat_present = len(expected_tools) > 0
    
    threat_detection = calculate_threat_detection_score(
        expected_tools,
        response.tools_called,
        threat_present
    )
    
    # Calculate composite score
    composite = calculate_composite_score(
        tool_selection,
        escalation_accuracy,
        threat_detection
    )
    
    # MVP pass/fail criteria:
    # - Pass: Composite score >= 0.70
    # - Fail: Any high-threat case missed (FN)
    # Note: threat_level "high" means expected_tools includes humanOperator or callPatrol (level >= 4)
    is_high_threat = expected_level >= 4
    missed_high_threat = is_high_threat and not response.tools_called
    
    # Determine failure type
    failure_type = ""
    is_correct = composite >= 0.70 and not missed_high_threat
    
    if not is_correct:
        if missed_high_threat:
            failure_type = "missed_high_threat"
        elif not threat_present and response.tools_called:
            failure_type = "false_alarm"
        elif threat_present and not response.tools_called:
            failure_type = "missed_threat"
        elif tool_selection < 0.5:
            failure_type = "wrong_tool"
        elif escalation_accuracy < 0.5:
            failure_type = "wrong_escalation"
    
    return Scores(
        tool_selection_accuracy=tool_selection,
        escalation_level_accuracy=escalation_accuracy,
        threat_detection_score=threat_detection,
        composite_score=composite,
        is_correct=is_correct,
        failure_type=failure_type
    )


def evaluate_batch(
    test_cases: List[TestCase],
    responses: List[AgentResponse]
) -> Dict:
    """Evaluate a batch of test cases.
    
    Args:
        test_cases: List of test cases
        responses: List of corresponding agent responses
        
    Returns:
        Dictionary with aggregate scores
    """
    results = []
    
    for tc, resp in zip(test_cases, responses):
        scores = evaluate_test_case(tc, resp)
        results.append({
            'test_case_id': tc.id,
            'category': tc.category,
            'scores': scores,
            'expected_tools': tc.ground_truth.expected_tools,
            'actual_tools': resp.tools_called,
            'expected_level': tc.ground_truth.expected_escalation_level,
            'actual_level': resp.escalation_level
        })
    
    # Calculate aggregate statistics
    total = len(results)
    passed = sum(1 for r in results if r['scores'].is_correct)
    failed = total - passed
    
    tool_selections = [r['scores'].tool_selection_accuracy for r in results]
    escalations = [r['scores'].escalation_level_accuracy for r in results]
    composites = [r['scores'].composite_score for r in results]
    
    # Group by category
    categories = {}
    for r in results:
        cat = r['category']
        if cat not in categories:
            categories[cat] = {
                'total': 0,
                'passed': 0,
                'composite_scores': []
            }
        categories[cat]['total'] += 1
        if r['scores'].is_correct:
            categories[cat]['passed'] += 1
        categories[cat]['composite_scores'].append(r['scores'].composite_score)
    
    # Calculate category averages (use composite scores per MVP spec)
    for cat in categories:
        scores = categories[cat]['composite_scores']
        categories[cat]['average_score'] = sum(scores) / len(scores) if scores else 0
        categories[cat]['passed_count'] = categories[cat]['passed']
        categories[cat]['failed_count'] = categories[cat]['total'] - categories[cat]['passed']
        # Remove old keys
        del categories[cat]['passed']
    
    return {
        'total_test_cases': total,
        'passed': passed,
        'failed': failed,
        'composite_score': sum(composites) / total if total > 0 else 0,
        'per_case_results': results,
        'per_category': categories
    }


def save_results(results: Dict, output_file: Path):
    """Save evaluation results to a JSON file.
    
    MVP report format:
    - run_id: unique identifier for this run
    - timestamp: when the evaluation was run
    - total_test_cases, passed, failed counts
    - composite_score: overall score
    - per_category_scores: scores grouped by category
    - results: detailed per-test-case results
    
    Args:
        results: Results dictionary from evaluate_batch
        output_file: Path to output file
    """
    from datetime import datetime
    
    # Build per-category scores (MVP format)
    per_category_scores = {}
    for cat, data in results['per_category'].items():
        per_category_scores[cat] = data.get('average_score', 0.0)
    
    # Convert dataclass to dict for JSON serialization (MVP format)
    serializable_results = {
        'run_id': f"run_{datetime.now().strftime('%Y%m%d_%H%M%S')}",
        'timestamp': datetime.now().isoformat() + 'Z',
        'total_test_cases': results['total_test_cases'],
        'passed': results['passed'],
        'failed': results['failed'],
        'composite_score': results['composite_score'],
        'per_category_scores': per_category_scores,
        'results': []
    }
    
    for r in results['per_case_results']:
        serializable_results['results'].append({
            'test_case_id': r['test_case_id'],
            'category': r['category'],
            'expected_tools': r['expected_tools'],
            'actual_tools': r['actual_tools'],
            'expected_escalation': r['expected_level'],
            'actual_escalation': r['actual_level'],
            'tool_selection_score': r['scores'].tool_selection_accuracy,
            'escalation_score': r['scores'].escalation_level_accuracy,
            'threat_detection_score': r['scores'].threat_detection_score,
            'composite_score': r['scores'].composite_score,
            'passed': r['scores'].is_correct,
            'failure_type': r['scores'].failure_type
        })
    
    with open(output_file, 'w') as f:
        json.dump(serializable_results, f, indent=2)
