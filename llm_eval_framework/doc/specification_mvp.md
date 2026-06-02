# LLM Evaluation Framework — MVP Specification

## BorderAgent: Simplified Evaluation Framework

This document defines a minimal viable product (MVP) for evaluating the BorderAgent LLM system. The goal is to get a working evaluation framework quickly, then expand as needed.

---

## 1. What We're Evaluating

The BorderAgent LLM is a **multimodal** system that:
- Uses built-in vision to analyze images from border surveillance cameras
- Receives CNN classification probabilities as supplementary data to enhance strategic decision-making
- Must decide on an appropriate action from a set of tools following a 5-level escalation protocol

### How llmfun Accesses Images

The llmfun agent uses the `loadImageApi` tool to read images from its workarea. During evaluation:
1. Test images are copied to `llmfun/workarea/`
2. The prompt instructs the agent to use `loadImageApi` to analyze the image from a specific path
3. The agent analyzes both the visual content AND CNN probabilities to make strategic decisions

### 1.1 Evaluation Dimensions

| Dimension | Description |
|-----------|-------------|
| **Threat Detection** | Correctly identify threats from image + CNN data |
| **Tool Selection** | Choose the right tool(s) for the situation |
| **Escalation Compliance** | Follow the 5-level escalation ladder correctly |

### 1.2 The Escalation Protocol

```
Level 1: Visible warning    → trackerLight
Level 2: Audible warning    → audibleWarning
Level 3: Visual strobe      → strobeLight
Level 4: Human operator     → humanOperator
Level 5: Call for patrol    → callPatrol
```

---

## 2. Test Dataset

### 2.1 Dataset Structure

Each test case is a JSON record:

```json
{
  "id": "test_001",
  "category": "no_threat",
  "image_path": "images/border_patrol/clear_001.jpg",
  "prompt": "Analyze this image from a border surveillance camera. Use loadImageApi to analyze the image from path 'images/border_patrol/clear_001.jpg'.",
  "cnn_probabilities": {
    "person": 0.02,
    "vehicle": 0.01,
    "animal": 0.05,
    "background": 0.92
  },
  "ground_truth": {
    "threat_level": "none",
    "expected_tools": [],
    "expected_escalation_level": 0
  },
  "metadata": {
    "description": "Clear background, no entities of interest"
  }
}
```

**Note:** The `image_path` field specifies where the test image is located. During evaluation:
- Images are copied to `llmfun/workarea/` so the agent can access them
- The `prompt` should include instructions to use `loadImageApi` with the image path
- This enables testing the multimodal capability of the LLM (vision + CNN probabilities)

### 2.2 Initial Test Categories

For the MVP, we start with 5 categories and 25-30 test cases:

| Category | Description | Count |
|----------|-------------|-------|
| `no_threat` | Clear background, no entities | 5 |
| `single_low_threat` | Single person, non-threatening | 5 |
| `single_high_threat` | Person with hostile indicators | 5 |
| `animal_false_positive` | Animals (not threats) | 5 |
| `persistent_threat` | Threat persisting over time | 5-10 |

---

## 3. Scoring Engine

### 3.1 Core Metrics (MVP)

We use **3 basic metrics** that are commonly used in LLM evaluations:

#### Metric 1: Tool Selection Accuracy

Did the LLM select the correct tool(s)?

```
Exact Match:        LLM tools == expected tools → 1.0
Subset Match:       expected ⊆ LLM tools → 0.7  (over-escalation)
Superset Match:     LLM tools ⊆ expected → 0.5  (under-escalation)
Partial Overlap:    |intersection| / |union| → 0.0-0.5
No Overlap:         → 0.0
```

#### Metric 2: Escalation Level Accuracy

Is the escalation level correct?

```
Exact Match:        level_diff == 0 → 1.0
Off by 1:           level_diff == 1 → 0.7
Off by 2:           level_diff == 2 → 0.4
Off by 3+:          level_diff >= 3 → 0.0
```

#### Metric 3: Threat Detection (TP/TN/FP/FN)

Binary classification: threat or no threat?

```
TP: Threat present, LLM detected → 1.0
TN: No threat, LLM did nothing   → 1.0
FP: No threat, LLM escalated     → -2.0 (penalty)
FN: Threat present, LLM missed   → -3.0 (penalty)
```

### 3.2 Composite Score

```
composite_score = (
  0.40 * tool_selection_accuracy +
  0.30 * escalation_level_accuracy +
  0.30 * threat_detection_score
)
```

Weights can be adjusted based on operational priorities.

### 3.3 Pass/Fail Criteria

```
Pass: Composite score ≥ 0.70
Fail: Any high-threat case missed (FN)
```

---

## 4. Evaluation Pipeline

### 4.1 Simple Flow

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│ Test Loader │───▶│  Evaluator  │───▶│   Scoring   │───▶│    Report   │
│ (JSON file) │    │ (call LLM)  │    │  (compute)  │    │  (JSON)     │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
```

### 4.2 Pipeline Steps

1. **Load Test Dataset** - Read JSON file with test cases
2. **For each test case:**
   - **Copy image to workarea**: Copy `image_path` to `llmfun/workarea/` so the agent can access it
   - **Build prompt**: Include instruction to use `loadImageApi` with the image path + CNN probabilities
   - **Call llmfun agent**: The multimodal LLM analyzes the image AND uses CNN probabilities
   - **Parse response**: Extract tools called from agent output
   - **Calculate scores**: Compare against ground truth
3. **Aggregate Results** - Compute composite score
4. **Generate Report** - Output JSON with results

**Example Prompt Construction:**
```
Analyze this image from a border surveillance camera. 
Use loadImageApi to analyze the image from path 'images/border_patrol/clear_001.jpg'.

CNN Classification Probabilities:
- person: 2.00%
- vehicle: 1.00%
- animal: 5.00%
- background: 92.00%

Based on your analysis, determine the appropriate action(s) using your available tools.
```

### 4.3 Response Parser

The LLM output must be parsed to extract structured decisions:

```
LLM Output → {
  "tools_called": ["trackerLight", ...],
  "escalation_level": inferred_from_tools,
  "reasoning": "string"
}
```

---

## 5. Output

### 5.1 Report Format

JSON file containing:

```json
{
  "run_id": "run_001",
  "timestamp": "2026-02-06T12:00:00Z",
  "total_test_cases": 25,
  "passed": 20,
  "failed": 5,
  "composite_score": 0.82,
  "per_category_scores": {
    "no_threat": 0.95,
    "single_low_threat": 0.80,
    "single_high_threat": 0.75,
    "animal_false_positive": 0.90,
    "persistent_threat": 0.70
  },
  "results": [
    {
      "test_case_id": "test_001",
      "category": "no_threat",
      "expected_tools": [],
      "actual_tools": [],
      "expected_escalation": 0,
      "actual_escalation": 0,
      "tool_selection_score": 1.0,
      "escalation_score": 1.0,
      "threat_detection_score": 1.0,
      "passed": true
    }
  ]
}
```

---

## 6. Future Development

This section outlines how to expand the framework once the MVP is working.

### Phase 1: Enhanced Testing

- [ ] **Adversarial test cases** - Weather (fog, rain, night), occlusion, low-resolution images, CNN probability conflicts
- [ ] **Temporal sequences** - Multi-step scenarios showing threat evolution over time
- [ ] **Larger dataset** - Expand to 100+ test cases across more categories
- [ ] **Vehicle category** - Add vehicle detection tests

### Phase 2: Advanced Metrics

- [ ] **Reasoning quality evaluation** - Use a stronger "Judge LLM" to evaluate if the LLM picked the right tool for the right reason (detects "lucky guesses")
- [ ] **Consistency scoring** - Run each test case multiple times (N=5) to measure variance
- [ ] **Latency tracking** - Measure response time; add p50/p95 targets
- [ ] **Per-category thresholds** - Different pass/fail criteria per category based on criticality

### Phase 3: Operational Features

- [ ] **Cost tracking** - Monitor token usage and API costs per run
- [ ] **Budget alerts** - Warn when approaching cost limits
- [ ] **Comparison reports** - Compare runs over time, detect regressions
- [ ] **Multiple output formats** - Add Markdown and HTML reports
- [ ] **Trend analysis** - Track score changes across dataset versions

### Phase 4: Security & Governance

- [ ] **RBAC** - Role-based access control (Admin, Evaluator, Viewer)
- [ ] **Audit logging** - Log all actions with timestamps and actors
- [ ] **Ground truth validation** - Peer review workflow for labels
- [ ] **Dataset versioning** - Track changes to test datasets
- [ ] **Prompt injection safeguards** - Protect against malicious inputs

### Additional Ideas

- [ ] **Benchmarking** - Compare multiple LLMs on same test set
- [ ] **A/B testing** - Test different prompts against each other
- [ ] **Real-time dashboard** - Live visualization of evaluation progress
- [ ] **CI/CD integration** - Run evaluations automatically on code changes
- [ ] **Regression detection** - Automatically flag score drops > 5%
- [ ] **Human feedback loop** - Allow evaluators to annotate and correct results

---

## Appendix: Glossary

| Term | Definition |
|------|-----------|
| BorderAgent | The LLM-based autonomous agent under evaluation |
| CNN Service | Pre-trained neural network that classifies images |
| Ground Truth | Expert-labeled expected response for each test case |
| TP/FP/TN/FN | True Positive / False Positive / True Negative / False Negative |
| Composite Score | Weighted aggregation of all evaluation metrics |

---

## Quick Start

```bash
cd llm_eval_framework
python main.py --dataset datasets/sample_tests.json --output results.json --verbose
```

See `doc/specification.md` for the full detailed specification.