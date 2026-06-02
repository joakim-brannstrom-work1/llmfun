#!/usr/bin/env python3
"""LLM Evaluation Framework - Main Entry Point

A basic evaluation framework for testing llmfun agent responses.

Usage:
    python main.py --dataset datasets/test_cases.json
    python main.py --dataset datasets/ --output results.json
"""

import argparse
import sys
from pathlib import Path
from typing import List

from test_loader import TestCase, load_test_cases_from_file, load_test_dataset
from evaluator import evaluate_test_case, AgentResponse
from scorer import evaluate_batch, save_results


def run_evaluation(
    test_cases: List[TestCase],
    output_file: Path = None,
    verbose: bool = False,
    datasets_dir: Path = None
) -> dict:
    """Run evaluation on all test cases.
    
    Args:
        test_cases: List of test cases to evaluate
        output_file: Optional path to save results
        verbose: Print progress information
        datasets_dir: Base directory for datasets (for image path resolution)
        
    Returns:
        Dictionary with evaluation results
    """
    if verbose:
        print(f"Running evaluation on {len(test_cases)} test cases...")
    
    responses = []
    
    for i, test_case in enumerate(test_cases):
        if verbose:
            print(f"  [{i+1}/{len(test_cases)}] Evaluating {test_case.id}...")
        
        # Pass datasets_dir so evaluator can copy images to workarea
        response = evaluate_test_case(test_case, datasets_dir=datasets_dir)
        responses.append(response)
        
        if verbose:
            expected = test_case.ground_truth.expected_tools
            actual = response.tools_called
            print(f"      Expected: {expected}")
            print(f"      Actual:   {actual}")
    
    # Evaluate all results
    results = evaluate_batch(test_cases, responses)
    
    # Print summary (MVP format)
    print("\n" + "="*50)
    print("EVALUATION RESULTS (MVP)")
    print("="*50)
    print(f"Total test cases: {results['total_test_cases']}")
    print(f"Passed: {results['passed']}")
    print(f"Failed: {results['failed']}")
    print(f"Composite score: {results['composite_score']:.3f}")
    
    print("\nPer-category scores:")
    for cat, data in results['per_category'].items():
        print(f"  {cat}: {data['average_score']:.2%} ({data['passed_count']}/{data['total']})")
    
    # Save results if output file specified
    if output_file:
        save_results(results, output_file)
        print(f"\nResults saved to: {output_file}")
    
    return results


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="LLM Evaluation Framework for llmfun agent"
    )
    
    parser.add_argument(
        '--dataset', '-d',
        required=True,
        help='Path to test case JSON file or directory'
    )
    
    parser.add_argument(
        '--output', '-o',
        help='Path to save results JSON file'
    )
    
    parser.add_argument(
        '--verbose', '-v',
        action='store_true',
        help='Print verbose progress information'
    )
    
    parser.add_argument(
        '--category', '-c',
        help='Filter by specific category'
    )
    
    args = parser.parse_args()
    
    dataset_path = Path(args.dataset)
    
    # Load test cases
    if dataset_path.is_file():
        test_cases = load_test_cases_from_file(dataset_path)
    elif dataset_path.is_dir():
        test_cases = load_test_dataset(dataset_path)
    else:
        print(f"Error: {dataset_path} not found", file=sys.stderr)
        return 1
    
    # Filter by category if specified
    if args.category:
        test_cases = [tc for tc in test_cases if tc.category == args.category]
        if not test_cases:
            print(f"Warning: No test cases found for category '{args.category}'")
            return 1
    
    if not test_cases:
        print("Error: No test cases loaded", file=sys.stderr)
        return 1
    
    # Determine datasets directory for image path resolution
    if dataset_path.is_file():
        datasets_dir = dataset_path.parent
    else:
        datasets_dir = dataset_path
    
    # Run evaluation
    output_file = Path(args.output) if args.output else None
    results = run_evaluation(test_cases, output_file, args.verbose, datasets_dir)
    
    return 0


if __name__ == '__main__':
    sys.exit(main())