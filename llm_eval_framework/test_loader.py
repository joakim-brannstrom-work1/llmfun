"""Test case loader for the LLM evaluation framework.

Loads test cases from JSON files.
"""

import json
from dataclasses import dataclass
from typing import List, Optional, Dict
from pathlib import Path


@dataclass
class GroundTruth:
    """Expected result for a test case."""
    threat_level: str
    threat_count: int
    expected_tools: List[str]
    expected_escalation_level: int
    is_persistent: bool = False
    time_at_border_seconds: int = 0


@dataclass
class TestCase:
    """A single test case for evaluation."""
    id: str
    category: str
    image_path: str  # Path to the test image (relative to datasets directory)
    prompt: str
    cnn_probabilities: Dict[str, float]
    ground_truth: GroundTruth
    metadata: Optional[Dict] = None


def load_test_cases_from_file(filepath: Path) -> List[TestCase]:
    """Load test cases from a JSON file.
    
    Args:
        filepath: Path to the JSON test case file
        
    Returns:
        List of TestCase objects
    """
    with open(filepath, 'r') as f:
        data = json.load(f)
    
    test_cases = []
    
    # Handle both single test case and list of test cases
    if isinstance(data, list):
        cases_data = data
    else:
        cases_data = [data]
    
    for case_data in cases_data:
        gt_data = case_data.get('ground_truth', case_data.get('expected', {}))
        ground_truth = GroundTruth(
            threat_level=gt_data.get('threat_level', 'none'),
            threat_count=gt_data.get('threat_count', 0),
            expected_tools=gt_data.get('expected_tools', []),
            expected_escalation_level=gt_data.get('expected_escalation_level', 0),
            is_persistent=gt_data.get('is_persistent', False),
            time_at_border_seconds=gt_data.get('time_at_border_seconds', 0)
        )
        
        test_case = TestCase(
            id=case_data.get('id', ''),
            category=case_data.get('category', 'unknown'),
            image_path=case_data.get('image_path', ''),
            prompt=case_data.get('prompt', case_data.get('user_prompt', '')),
            cnn_probabilities=case_data.get('cnn_probabilities', {}),
            ground_truth=ground_truth,
            metadata=case_data.get('metadata')
        )
        test_cases.append(test_case)
    
    return test_cases


def load_test_dataset(dataset_dir: Path) -> List[TestCase]:
    """Load all test cases from a dataset directory.
    
    Args:
        dataset_dir: Directory containing JSON test case files
        
    Returns:
        List of all TestCase objects found
    """
    all_cases = []
    
    for json_file in dataset_dir.glob('*.json'):
        cases = load_test_cases_from_file(json_file)
        all_cases.extend(cases)
    
    return all_cases


def get_cases_by_category(test_cases: List[TestCase], category: str) -> List[TestCase]:
    """Filter test cases by category.
    
    Args:
        test_cases: List of test cases
        category: Category to filter by
        
    Returns:
        Filtered list of test cases
    """
    return [tc for tc in test_cases if tc.category == category]