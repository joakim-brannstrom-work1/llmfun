# LLM Evaluation Framework — BorderAgent

## Description of LLM usage

The LLM receive as input:
1. an image
2. the image classification from a CNN. Four classes so the input to the LLM is the probability for each class.

The LLM is one with vision support.

The LLM has as static data the following:
1. in the system prompt there is a scenario such as "border patrol". This contains what the LLM's task is.
2. Tools suitable for the scenario such as the "border patrol" then it have tools like "audibleWarning".

The LLM shall on this input, both dynamic (images) and static, device a strategy. Typical expectaions on the output strategy would be:
1. Nothing inteterinst found in the image. Do nothing.
2. A low target threat is found (such as only one). Use a low lethal tool such as activating trackerLight.
3. A low target threat that has persisted by the border for an extended time. Increase the use of lethal tools such as audibleWarning or strobeLight.
4. Multiple high level threats are detected immediately use the tool "callPatrol" and "humanOperator"

## Framework Requirements

The framework shall be able to answer how the LLM perform.

## 0. Glossary

| Term | Definition |
|------|-----------|
| BorderAgent | The LLM-based autonomous agent under evaluation, responsible for border surveillance decisions |
| CNN Service | Pre-trained convolutional neural network that classifies images into 4 categories (person, vehicle, animal, background) |
| trackerLight | Tool: Activates a visible tracking light on the target (escalation level 1) |
| audibleWarning | Tool: Emits an audible warning sound (escalation level 2) |
| strobeLight | Tool: Activates a visual strobe light warning (escalation level 3) |
| humanOperator | Tool: Alerts a human operator to the situation (escalation level 4) |
| callPatrol | Tool: Dispatches a physical patrol unit (escalation level 5) | 
| Escalation Protocol | 5-level decision ladder from least to most severe response |
| Ground Truth | Expert-labeled expected response for each test case |
| Temporal Sequence | Multi-step test case simulating a threat persisting over time |
| Composite Score | Weighted aggregation of all individual evaluation metrics |
| FP/FN | False Positive (false alarm) / False Negative (missed threat) |

## 1. System Overview

This document defines a comprehensive evaluation framework for the BorderAgent LLM system. The LLM receives an image and CNN classification probabilities, and must decide on an appropriate action from a set of tools following a 5-level escalation protocol.

### 1.1 What We Are Evaluating

| Dimension | Description |
|-----------|-------------|
| Threat Detection | Correctly identify threats from image + CNN data | 
| Escalation Compliance | Follow the 5-level escalation ladder correctly |
| Tool Selection | Choose the right tool(s) for the situation | 
| Temporal Reasoning | Escalate appropriately for persistent threats over time |
| Multi-Threat Handling | Prioritize and respond to multiple simultaneous threats |
| False Positive Control | Avoid unnecessary escalation for benign inputs |
| Consistency | Produce stable, repeatable decisions for similar inputs |
| Latency | Response time within operational bounds |

### 1.2 Non-Functional Requirements

| Requirement | Target | Notes |
|-------------|--------|-------|
| **Availability** | Manually started | Evaluation is started by a human operator |
| **Reproducibility** | Full run provenance | Every run captures: dataset version, prompt version, LLM config, scoring weights |
| **Data Volume** | 300-500 test cases, growing | Dataset versioned on disk or git (text files); not an important point for now |
| **Scalability** | 1500+ LLM calls/run (with consistency runs) | No parallel execution; target < 24h per full evaluation |
| **Security** | Not important | |
| **Error Tolerance** | Partial results on failure | Single test case failure does not invalidate entire run | 

### 1.3 Technology Stack

 | Component | Technology | Rationale |
 |-----------|-----------|-----------|
 | Language | Python 3.11+ | Rich ML/evaluation ecosystem |
 | LLM Client | llmfun agent CLI | Calls `llmfun agent -p '<prompt>'` |
 | Data Storage | JSON files | Simple test case format |
 | Results Storage | JSON files | Machine-readable results |

### 1.4 Implementation Status

A basic Python evaluation framework has been implemented in `llm_eval_framework/`:

```
llm_eval_framework/
├── __init__.py          # Package initialization
├── main.py              # CLI entry point
├── test_loader.py       # Load test cases from JSON
├── evaluator.py         # Call llmfun agent and parse responses
├── scorer.py            # Calculate scores and generate reports
└── datasets/
    └── sample_tests.json  # Sample test cases
```

**Usage:**
```bash
cd llm_eval_framework
python main.py --dataset datasets/sample_tests.json --output results.json --verbose
```

## 2. The Escalation Protocol (Ground Truth Reference)

```
Level 1: Visible warning    → trackerLight
Level 2: Audible warning    → audibleWarning
Level 3: Visual strobe      → strobeLight
Level 4: Human operator     → humanOperator
Level 5: Call for patrol    → callPatrol
```

## 3. Architecture

### 3.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       EVALUATION ORCHESTRATOR                           │
│                                                                         │
│  ┌──────────────┐   ┌──────────────┐   ┌────────────────┐              │
│  │  Test Dataset │   │  Test Runner │   │   Scoring      │              │
│  │  Manager     │──▶│  Engine      │──▶│   Engine       │              │
│  └──────────────┘   └──────┬───────┘   └────────────────┘              │
│         │                   │                    │                      │
│         │              ┌────┴─────┐              │                      │
│         │              │          │              │                      │
│         │              │ Executor │              │                      │
│         │              │          │              │                      │
│         │              └────┬─────┘              │                      │
│         │                   │                    ▼                      │
│         │              ┌────┴─────┐   ┌────────────────┐               │
│         │              │  LLM     │   │   Report       │               │
│         │              │  Under   │   │   Generator    │               │
│         │              │  Test    │   └────────────────┘               │
│         │              └──────────┘                                    │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                    SUPPORTING SERVICES                           │   │
│  │                                                                  │   │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌───────────┐ │   │
│  │  │  Prompt     │ │  Config     │ │  Ground     │ │  Error    │ │   │
│  │  │  Manager    │ │  Manager    │ │  Truth      │ │  Handler  │ │   │
│  │  │  (versioned)│ │  (LLM params)│ │  Validator  │ │  (retry,  │ │   │
│  │  └─────────────┘ └─────────────┘ └─────────────┘ └──fallback)┘ │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
         │              │                    │                    │
         ▼              ▼                    ▼                    ▼
┌────────────────┐ ┌──────────────┐  ┌────────────────┐  ┌────────────┐
│                │ │  CNN Service │  │  Metrics       │  │  Audit     │
│  Image Store   │ │  (cached     │  │                │  │  Log       │
│  (at rest +    │ │   probs)     │  │  (scores,      │  │  (who,     │
│   in transit)  │ └──────────────┘  │   trends, cost)│  │   when,    │
└────────────────┘                   └────────────────┘  │   what)    │
                                                         └────────────┘
```

### 3.2 Architecture Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Execution Model | Single threaded execution | LLM API calls are I/O-bound but GPU-limited |
| Temporal Sequences | Sequential within chain | Each step depends on prior conversation state|
| Prompt Storage | Versioned JSON in Git | Prompts are the primary tuning lever; versioning enables attribution of performance changes |
| Configuration Management | JSON config with run-level override | LLM params (model, temperature, max_tokens) captured per-run for full reproducibility | 
| Error Handling | Retry with exponential backoff + partial results | Single API failure should not invalidate entire evaluation; retry handles transient errors |
| Data Storage | Git LFS for images, JSON for manifests, SQLite for results | Version control for datasets; queryable results for trend analysis |

---

## 4. Test Dataset Design

### 4.1 Dataset Structure

Each test case is a structured record:

```json
{
  "id": "test_001",
  "category": "single_low_threat",
  "image_path": "images/border_patrol/solo_walker_01.jpg",
  "cnn_probabilities": {
    "class_person": 0.82,
    "class_vehicle": 0.05,
    "class_animal": 0.10,
    "class_background": 0.03
  },
  "ground_truth": {
    "threat_level": "low",
    "threat_count": 1,
    "expected_tools": ["trackerLight"],
    "expected_escalation_level": 1,
    "is_persistent": false,
    "time_at_border_seconds": 0
  },
  "metadata": {
    "description": "Single person walking near border marker",
    "lighting": "daylight",
    "weather": "clear",
    "occlusion": "none"
  }
}
```

### 4.2 Test Categories

| Category | Description | Count Target |
|----------|-------------|-------------|
| `no_threat` | Clear background, no entities of interest | 50 | 
| `single_low_threat` | Single person, non-threatening posture | 50 | 
| `single_medium_threat` | Single person with suspicious behavior | 30 | 
| `single_high_threat` | Single person with clear hostile indicators | 20 |
| `multi_low_threat` | 2-3 persons, non-threatening | 30 | 
| `multi_high_threat` | 3+ persons, threatening indicators | 20 | 
| `persistent_low` | Low threat that has been at border for extended time | 20 |
| `persistent_high` | High threat persisting at border | 15 |
| `animal_false_positive` | Animals that might be confused for persons | 20 |
| `vehicle` | Vehicles near border | 20 |
| `adversarial` | Edge cases: fog, night, occlusion, low-res, misleading CNN probabilities, conflicting image/CNN data, extremely low-confidence CNN outputs | 35 |
| `temporal_escalation` | Sequences showing threat over time | 10 sequences |

**Total**: ~330+ individual test cases + 10 temporal sequences

### 4.3 Adversarial Test Cases (Expanded)

The adversarial category includes specialized sub-categories:

| Sub-category | Description | Count |
|-------------|-------------|-------|
| `adversarial_weather` | Fog, heavy rain, night, extreme low-light | 8 |
| `adversarial_occlusion` | Partially hidden subjects, dense foliage | 5 |
| `adversarial_low_res` | Blurry, pixelated, or distant images | 5 | 
| `adversarial_cnn_conflict` | CNN probabilities conflict with image content (e.g., CNN says "animal" but image shows person) | 5 |
| `adversarial_low_confidence` | CNN outputs very low confidence across all classes (< 30% max) | 5 |
| `adversarial_misleading` | Images designed to trigger false positives (e.g., mannequins, shadows, reflections) | 7 |

### 4.4 Temporal Test Sequences

For evaluating persistent threat handling, test cases are organized into sequences:

```json
{
  "sequence_id": "seq_001",
  "description": "Single person lingering at border for 30 minutes",
  "steps": [
    {
      "step": 1,
      "time_elapsed_seconds": 0,
      "image_path": "sequences/seq_001/step_01.jpg",
      "cnn_probabilities": { ... },
      "expected_tools": ["trackerLight"],
      "expected_escalation_level": 1
    },
    {
      "step": 2,
      "time_elapsed_seconds": 300,
      "image_path": "sequences/seq_001/step_02.jpg",
      "cnn_probabilities": { ... },
      "expected_tools": ["audibleWarning"],
      "expected_escalation_level": 2
    },
    {
      "step": 3,
      "time_elapsed_seconds": 900,
      "image_path": "sequences/seq_001/step_03.jpg",
      "cnn_probabilities": { ... },
      "expected_tools": ["strobeLight"],
      "expected_escalation_level": 3
    }
  ]
}
```

---

## 4. Scoring Engine

### 4.1 Metric Definitions

#### 4.1.1 Tool Selection Accuracy (Primary Metric)

Measures whether the LLM selected the correct tool(s).

```
Exact Match:        LLM tools == expected tools → 1.0
Subset Match:       expected ⊆ LLM tools → 0.7  (over-escalation penalty)
Superset Match:     LLM tools ⊆ expected → 0.5  (under-escalation penalty)
Partial Overlap:    |intersection| / |union| → 0.0-0.5
No Overlap:         → 0.0
```

#### 4.1.2 Escalation Level Accuracy

Measures whether the escalation level is correct.

```
Exact Match:        level_diff == 0 → 1.0
Off by 1:           level_diff == 1 → 0.7
Off by 2:           level_diff == 2 → 0.4
Off by 3+:          level_diff >= 3 → 0.0
```

#### 4.1.3 Threat Detection Accuracy

Binary classification: did the LLM detect a threat when one exists, and not detect when none exists?

```
TP: Threat present, LLM detected → 1.0
TN: No threat, LLM did nothing   → 1.0
FP: No threat, LLM escalated     → -2.0 (penalty for false alarm)
FN: Threat present, LLM missed   → -3.0 (penalty for miss)
```

#### 4.1.4 Temporal Escalation Score

For temporal sequences, measures correct escalation over time.

```
For each step in sequence:
  score_step = escalation_level_accuracy(step)
  temporal_score = mean(score_step for all steps)
  
Penalty for de-escalation when threat persists: -0.5 per step ```

#### 4.1.5 Consistency Score

Run each test case N times (N=5 recommended). Measure variance.

```
consistency = 1.0 - (std_dev(tool_selection_scores) / mean(tool_selection_scores)) ```

#### 4.1.6 Latency

```
latency_ms = time_to_first_token_ms + time_to_completion_ms
target_p50 < 2000ms
target_p95 < 5000ms
```

**Latency Score Normalization** (for composite formula):

```
latency_score = max(0, 1 - (latency_ms / target_p95)) ```

This maps raw latency to a 0-1 scale where:
- latency_ms = 0 → latency_score = 1.0
- latency_ms = target_p95 (5000ms) → latency_score = 0.0
- latency_ms > target_p95 → latency_score = 0.0 (clamped)

#### 4.1.7 Reasoning Quality (LLM-as-a-Judge)

An LLM can pick the right tool for the wrong reason (a "lucky guess"), which is dangerous in a security context. This metric evaluates the quality of the LLM's reasoning using a stronger "Judge LLM".

**Metric Components:**

| Component | Description | Scoring |
|-----------|-------------|---------|
| Logical Consistency | Does the reasoning logically lead to the chosen tool? | 0-1 |
| Evidence Grounding | Did the LLM mention specific CNN probabilities or visual cues? | 0-1 |

**Scoring:**
- 0: Hallucinated/Irrelevant reasoning
- 0.5: Partially grounded reasoning
- 1.0: Perfectly grounded reasoning

**Judge LLM Prompt:**
```
Evaluate the following LLM response for a border surveillance task.

Chosen tool: {tool}
Reasoning: {reasoning}
CNN probabilities: {cnn_probs}
Image description: {image_description}

Questions:
1. Does the reasoning logically justify the chosen tool? Score 0-1.
2. Did the reasoning reference specific evidence (CNN probabilities, visual cues)? Score 0-1.

Return: {"logical_consistency": X, "evidence_grounding": Y}
```

**Reasoning Score Calculation:**
```
reasoning_score = (logical_consistency + evidence_grounding) / 2
```

### 4.2 Composite Score

```
composite_score = (
  0.25 * tool_selection_accuracy +
  0.20 * escalation_level_accuracy +
  0.20 * threat_detection_accuracy +
  0.15 * temporal_escalation_score +
  0.10 * reasoning_quality +
  0.05 * consistency_score +
  0.05 * latency_score
)
```

Weights are configurable. The default weights prioritize safety-critical metrics (tool selection, escalation, threat detection, and reasoning quality for security context).

### 4.3 Per-Category Scores

In addition to the overall composite score, compute scores per test category:

| Category | Why It Matters |
|----------|---------------|
| `no_threat` | False alarm rate — critical for operational cost | 
| `single_low_threat` | Most common scenario — baseline performance | 
| `multi_high_threat` | Worst-case scenario — safety-critical | 
| `persistent_*` | Temporal reasoning — advanced capability | 
| `adversarial` | Robustness — real-world conditions |

---

## 5. Evaluation Pipeline

### 5.1 Pipeline Steps

```
Step 1: Load test dataset (JSON manifest + images)
         │
         ▼
Step 2: For each test case (or batch):
         │  ├─ Load image
         │  ├─ Construct prompt (system prompt + image + CNN probs)
         │  ├─ Call LLM
         │  └─ Parse LLM response → extracted tools, escalation level
         │
         ▼
Step 3: Score each response against ground truth
         │  ├─ Tool selection accuracy
         │  ├─ Escalation level accuracy
         │  ├─ Threat detection (TP/TN/FP/FN)
         │  └─ Latency measurement
         │
         ▼
Step 4: For temporal sequences:
         │  ├─ Process sequence steps in order
         │  ├─ Pass conversation history between steps
         │  └─ Score temporal escalation
         │
         ▼
Step 5: Compute aggregate metrics
         │  ├─ Per-category scores
         │  ├─ Composite score
         │  ├─ Confusion matrices
         │  └─ Consistency analysis (if N > 1)
         │
         ▼
Step 6: Generate report
         │  ├─ Summary dashboard
         │  ├─ Per-test-case breakdown
         │  ├─ Failure analysis
         │  └─ Comparison with previous runs (if available) ```

### 5.2 Response Parser

The LLM output must be parsed to extract structured decisions. The parser handles:

```
LLM Output → {
  "tools_called": ["trackerLight", ...],
  "reasoning": "string",
  "escalation_level": inferred_from_tools,
  "confidence": extracted_if_present
}
```

**Escalation level inference from tools:**

| Tool | Escalation Level |
|------|-----------------|
| trackerLight | 1 |
| audibleWarning | 2 |
| strobeLight | 3 |
| humanOperator | 4 |
| callPatrol | 5 |

When multiple tools are called, the escalation level is the **maximum** level among called tools.

### 5.3 Batch Processing

For efficiency:
- Process test cases in batches of 10-50
- Use async/parallel LLM calls where supported
- Cache CNN probabilities (pre-computed)
- Store intermediate results for debugging

---

## 6. Data Models

### 6.1 Test Case Schema

```python
class TestCase(BaseModel):
    id: str
    category: str
    image_path: str
    cnn_probabilities: Dict[str, float]
    ground_truth: GroundTruth
    metadata: Optional[Dict] = {}

class GroundTruth(BaseModel):
    threat_level: Literal["none", "low", "medium", "high"]
    threat_count: int
    expected_tools: List[str]
    expected_escalation_level: int
    is_persistent: bool = False
    time_at_border_seconds: int = 0
    acceptable_alternatives: Optional[List[List[str]]] = None ```

### 6.2 Evaluation Result Schema

```python
class EvaluationResult(BaseModel):
    test_case_id: str
    category: str
    llm_response: str
    parsed_decision: ParsedDecision
    scores: Scores
    latency_ms: float
    timestamp: datetime

class ParsedDecision(BaseModel):
    tools_called: List[str]
    escalation_level: int
    reasoning: str

class Scores(BaseModel):
    tool_selection_accuracy: float
    escalation_level_accuracy: float
    threat_detection: float  # TP/TN/FP/FN score
    composite: float
```

### 6.3 Evaluation Report Schema

```python
class EvaluationReport(BaseModel):
    run_id: str
    timestamp: datetime
    llm_config: Dict  # model, temperature, etc.
    total_test_cases: int
    overall_scores: OverallScores
    per_category_scores: Dict[str, CategoryScores]
    confusion_matrix: Dict[str, int]  # TP, TN, FP, FN
    latency_stats: LatencyStats
    failures: List[FailureRecord]
    consistency_scores: Optional[Dict[str, float]]

class OverallScores(BaseModel):
    composite: float
    tool_selection_accuracy: float
    escalation_level_accuracy: float
    threat_detection_accuracy: float
    temporal_escalation_score: float
    consistency_score: float
    latency_score: float

class FailureRecord(BaseModel):
    test_case_id: str
    category: str
    expected_tools: List[str]
    actual_tools: List[str]
    expected_escalation: int
    actual_escalation: int
    llm_response: str
    failure_type: Literal["over_escalation", "under_escalation", "wrong_tool", "missed_threat", "false_alarm"] ```

---

## 7. Component Design

### 7.1 Component: Dataset Manager

**Responsibilities:**
- Load test case manifests from JSON
- Validate dataset completeness
- Organize test cases by category
- Provide temporal sequences for multi-step evaluation
- Support dataset versioning

**Interface:**
```
load_dataset(path: str) -> List[TestCase]
load_sequences(path: str) -> List[TestSequence]
get_cases_by_category(category: str) -> List[TestCase]
validate_dataset() -> List[ValidationIssue] ```

### 7.2 Component: Test Runner Engine

**Responsibilities:**
- Construct prompts from test cases
- Invoke the LLM under test
- Parse LLM responses into structured decisions
- Measure latency
- Handle errors and retries

**Interface:**
```
run_single(test_case: TestCase, llm_client: LLMClient) -> EvaluationResult
run_batch(test_cases: List[TestCase], llm_client: LLMClient) -> List[EvaluationResult]
run_sequence(sequence: TestSequence, llm_client: LLMClient) -> List[EvaluationResult] ```

### 7.3 Component: Scoring Engine

**Responsibilities:**
- Compute all individual metric scores
- Compute composite score with configurable weights
- Generate confusion matrices
- Compute consistency scores across multiple runs

**Interface:**
```
score_response(result: EvaluationResult) -> Scores
compute_composite(results: List[EvaluationResult], weights: Dict) -> OverallScores
compute_confusion_matrix(results: List[EvaluationResult]) -> Dict
compute_consistency(results_by_case: Dict[str, List[EvaluationResult]]) -> Dict ```

### 7.4 Component: Report Generator

**Responsibilities:**
- Aggregate results into human-readable reports
- Generate comparison reports between evaluation runs
- Export results in multiple formats (JSON, Markdown, CSV)
- Highlight regressions and improvements

**Interface:**
```
generate_report(results: List[EvaluationResult]) -> EvaluationReport
generate_comparison(prev: EvaluationReport, curr: EvaluationReport) -> ComparisonReport
export_json(report: EvaluationReport, path: str)
export_markdown(report: EvaluationReport, path: str) ```

### 7.5 Component: LLM Client Adapter

**Responsibilities:**
- Abstract the LLM backend (OpenAI, Anthropic, local, etc.)
- Support vision-enabled LLM calls
- Handle authentication and rate limiting
- Provide consistent response format

**Interface:**
```
call_with_vision(system_prompt: str, image: Image, user_text: str) -> LLMResponse
 configure(model: str, temperature: float, max_tokens: int)  ```

### 7.6 Component: Prompt Manager

**Responsibilities:**
- Store and version system prompts and user prompt templates
- Select correct prompt version for evaluation runs
- Track prompt changes and their impact on evaluation scores

**Interface:**
```
get_prompt(version: str) -> Prompt
list_versions() -> List[PromptVersion]
create_version(content: str, label: str) -> PromptVersion
diff_versions(v1: str, v2: str) -> DiffResult ```

### 7.7 Component: Config Manager

**Responsibilities:**
- Manage LLM configuration parameters (model, temperature, max_tokens, etc.)
- Capture full run configuration for reproducibility
- Support per-run config overrides

**Interface:**
```
get_config(run_id: str) -> RunConfig
save_config(run_id: str, config: RunConfig)
list_configs() -> List[RunConfigSummary] ```

### 7.8 Component: Ground Truth Validator

**Responsibilities:**
- Validate ground truth labels against domain rules
- Track peer review status for each test case
- Flag cases with reviewer disagreements
- Version ground truth alongside test datasets

**Interface:**
```
validate_case(test_case: TestCase) -> ValidationResult
flag_for_review(test_case_id: str, reason: str)
get_disagreement_rate() -> float
get_review_status(test_case_id: str) -> ReviewStatus ```

### 7.9 Component: Cost Tracker

**Responsibilities:**
- Track token usage and API costs per test case and per run
- Enforce budget limits with configurable alerts
- Provide cost optimization recommendations

**Interface:**
```
record_cost(run_id: str, test_case_id: str, input_tokens: int, output_tokens: int, cost_usd: float)
get_run_cost(run_id: str) -> CostSummary
get_cumulative_cost() -> CumulativeCost
check_budget(run_cost: float) -> BudgetStatus ```
configure(model: str, temperature: float, max_tokens: int) ```

---

## 8. Prompt Construction

### 8.1 User Prompt Template

```
Analyze the following image and CNN classification results.

CNN Classification Probabilities:
- {class_1}: {prob_1:.2%}
- {class_2}: {prob_2:.2%}
- {class_3}: {prob_3:.2%}
- {class_4}: {prob_4:.2%}

[Image attached]

Based on your analysis, determine the appropriate action(s) using your available tools.
```

### 8.2 Temporal Sequence Prompt

For temporal sequences, the conversation history is preserved between steps. Each step adds:

```
Additional context: The subject has been at the border location for {elapsed_time} seconds.
Current image: [new image]
Current CNN probabilities: {updated probs}

Re-evaluate the situation and determine if your action needs to change.
```

### 8.3 Evaluation-Specific Modifications

During evaluation, the system prompt remains **unchanged** from production. This ensures the evaluation reflects real behavior. The only addition is an optional request for structured output to aid parsing:

```
After deciding on your action, state your chosen tool(s) clearly.
```

---

## 9. Iterative Improvement Workflow

### 9.1 Evaluation Loop

```
┌─────────────┐
│  Baseline   │  Run initial evaluation
│  Evaluation │
└──────┬──────┘
       ▼
┌─────────────┐
│  Analyze    │  Identify failure patterns
│  Failures   │  (e.g., always under-escalates multi-threat)
└──────┬──────┘
       ▼
┌─────────────┐
│  Modify     │  Change prompt, add examples, adjust tools
│  LLM Config │
└──────┬──────┘
       ▼
┌─────────────┐
│  Re-Run     │  Evaluate with same dataset
│  Evaluation │
└──────┬──────┘
       ▼
┌─────────────┐
│  Compare    │  Did composite score improve?
│  Results    │  Any regressions in other categories?
└──────┬──────┘
       │
       ▼  (if not satisfactory)
   [loop back]
```

### 9.2 What to Modify

| Leverage Point | Examples |
|---------------|----------|
| System Prompt | Clarify escalation rules, add examples, adjust tone | 
| Tool Descriptions | Make tool effects clearer, add prerequisites | 
| Prompt Template | Reorder information, add emphasis on safety |
| CNN Integration | Adjust how probabilities are presented |
| Temperature | Lower for more deterministic behavior |
| Few-Shot Examples | Add example scenarios to prompt |

### 9.3 Regression Detection

Each evaluation run is versioned. Comparison reports highlight:
- Categories where score dropped by > 5%
- New failure modes introduced
- Changes in false positive / false negative rates

---

## 10. Directory Structure

```
evaluation/
├── config/
│   ├── scoring_weights.json      # Configurable metric weights
│   └── llm_config.json           # LLM under test configuration
├── datasets/
│   ├── v1/                       # Versioned datasets
│   │   ├── manifest.json         # Test case index
│   │   └── categories/
│   │       ├── no_threat/
│   │       ├── single_low_threat/
│   │       └── ...
│   └── sequences/
│       ├── seq_001.json          # Temporal sequence definitions
│       └── ...
├── src/
│   ├── dataset_manager.py
│   ├── test_runner.py
│   ├── scoring_engine.py
│   ├── report_generator.py
│   ├── llm_client.py
│   └── response_parser.py
├── results/
│   ├── run_20240101_001/
│   │   ├── report.json
│   │   ├── report.md
│   │   ├── per_case.json
│   │   └── failures.json
│   └── ...
├── tests/
│   ├── test_scoring_engine.py
│   ├── test_response_parser.py
│   └── test_dataset_manager.py
└── main.py                       # Entry point
```

---

## 11. Thresholds and Pass/Fail Criteria

### 11.1 Minimum Acceptable Scores

| Metric | Minimum Threshold | Rationale |
|--------|------------------|-----------|
| Composite Score | ≥ 0.70 | Overall quality gate |
| Threat Detection (no_threat category) | ≥ 0.90 FP rate | Low false alarm rate required |
| Threat Detection (multi_high_threat) | ≥ 0.95 recall | Must not miss high threats |
| Escalation Level Accuracy | ≥ 0.75 | Correct escalation is safety-critical |
| Latency P95 | < 5000ms | Operational responsiveness |
| Consistency | ≥ 0.80 | Predictable behavior |

### 11.2 Category-Specific Gates

```
no_threat:              FP rate < 0.10  (90%+ true negative rate)
single_low_threat:      Exact tool match ≥ 0.80
single_high_threat:     Recall ≥ 0.95
multi_high_threat:      Recall ≥ 0.95, no under-escalation
persistent_*:           Temporal escalation score ≥ 0.70
adversarial:            Composite ≥ 0.60  (lower bar for edge cases)
```

### 11.3 Blocking Failures

The following are **automatic failures** regardless of composite score:
- Any `multi_high_threat` case where no action is taken (FN)
- Any `no_threat` case with `callPatrol` or `humanOperator` called (severe FP)
- Consistency score < 0.50 (unreliable behavior)

---

## 13. Security

### 13.1 Data Protection

| Concern | Measure |
|---------|---------|
| Images at rest | AES-256 encryption in object storage |
| Images in transit | TLS 1.3 for all data transfers |
| Encryption keys | Managed via HashiCorp Vault or cloud KMS |
| Key rotation | Automatic rotation every 90 days |

### 13.2 Access Control

| Role | Permissions |
|------|-------------|
| **Admin** | Full access: manage datasets, run evaluations, view all 
| results, modify system config |
| **Evaluator** | Run evaluations, view results, cannot modify datasets 
| or system config |
| **Viewer** | Read-only access to evaluation reports and dashboard | 
| **Dataset Curator** | Create/modify test cases and ground truth 
| labels, cannot run evaluations |

### 13.3 Audit Logging

All actions logged with:
- Timestamp (ISO 8601)
- Actor (user/service account)
- Action type (run_evaluation, modify_dataset, view_report, etc.)
- Resource affected (dataset version, run ID, etc.)
- Outcome (success/failure)

### 13.4 Prompt Injection Safeguards

| Measure | Description |
|---------|-------------|
| Input sanitization | Strip or escape any injected instructions in test data metadata |
| System prompt isolation | System prompt never includes user-provided content |
| Output validation | Parse LLM output against known tool names; reject unexpected actions |
| Adversarial test cases | Dedicated category testing LLM resilience to misleading inputs |

---

## 14. Error Handling and Fault Tolerance

### 14.1 Error Categories and Handling

| Error Type | Strategy | Fallback |
|------------|----------|----------|
| LLM API timeout | Retry with exponential backoff (max 3 retries, base 1s, max 30s) | Mark test case as failed; continue with remaining cases |
| LLM API rate limit | Respect Retry-After header; queue remaining calls | Resume when rate limit clears |
| LLM API error (5xx) | Retry with exponential backoff | Mark as failed after max retries |
| LLM API error (4xx) | Log and skip (likely bad request) | Flag for manual review |
| Missing image file | Skip test case; log warning | Include in report as "skipped" |
| Corrupted image | Skip test case; log error | Flag for dataset maintenance |
| CNN service unavailable | Use cached probabilities (pre-computed) | If no cache, skip test case |
| Invalid JSON in dataset | Skip test case; log error | Continue with remaining cases |
| Response parse failure | Fallback regex-based extraction | If still fails, mark as "unparseable" |

### 14.2 Partial Results

- Evaluation runs always produce a report, even if some test cases fail
- Failed/skipped test cases are clearly marked in the report
- Scores exclude failed/skipped cases from denominators
- Run metadata includes: total cases, passed, failed, skipped counts
- Minimum viable run: at least 50% of test cases must succeed for report to be considered valid

### 14.3 Retry Configuration

```json
{
  "max_retries": 3,
  "base_delay_ms": 1000,
  "max_delay_ms": 30000,
  "backoff_multiplier": 2,
  "retry_on": ["timeout", "5xx_error", "rate_limit"],
  "abort_on": ["4xx_error", "missing_data", "parse_error"] }
```

---

## 15. Cost Tracking and Optimization

### 15.1 Cost Metrics

| Metric | Tracked Per | Display |
|--------|-------------|---------|
| Input tokens | Per test case, per run | report |
| Output tokens | Per test case, per run | report |
| API calls | Per run | report |

### 15.2 Cost Optimization Strategies

| Strategy | Description | Impact |
|----------|-------------|--------|
| Response caching | Cache LLM responses for unchanged test cases (same 
| image + same prompt + same LLM config) | Eliminates redundant calls 
| between runs | Batch processing | Group independent test cases into 
| parallel batches | Reduces wall-clock time, not cost | Early 
| termination | For consistency runs, stop early if score variance is 
| clearly low | Reduces calls for stable test cases | Cheaper model 
| screening | Use a cheaper model for initial pass; only re-evaluate 
| ambiguous cases with the target model | 50-70% cost reduction for 
| clear-cut cases |

### 15.3 Budget Alerts

```json
{
  "budget_per_run_usd": 50.00,
  "budget_monthly_usd": 500.00,
  "alert_threshold_percent": 80,
  "alert_channels": ["email", "slack"]
}
```

---

## 16. Ground Truth Governance

### 16.1 Creation Process

1. **Initial label**: Dataset curator assigns ground truth based on scenario description 2. **Peer review**: Second curator validates label 3. **Domain expert review**: For contentious or edge cases, domain expert provides final label 4. **Version commit**: Approved labels committed to dataset version in Git

### 16.2 Update Process

1. **Change request**: Curator or evaluator files change request with justification 2. **Review**: Domain expert reviews change request 3. **Approval**: Change approved or rejected with rationale 4. **Version bump**: Approved changes create new dataset version (e.g., v1.1 → v1.2) 5. **Re-evaluation**: Previous runs re-scored against new ground truth (for comparison)

### 16.3 Disagreement Tracking

- Track cases where multiple reviewers disagree
- High-disagreement cases flagged for domain expert resolution
- Disagreement rate reported as a dataset quality metric

---

## 18. Report Generation

### 18.1 Output Formats

The evaluation framework produces reports in the following formats:

| Format | Description |
|--------|-------------|
| JSON | Machine-readable results for programmatic access |
| Markdown | Human-readable summary report |
| HTML | Interactive report with visualizations |

### 18.2 Report Contents

Each evaluation run produces:
- Summary dashboard with composite scores
- Per-test-case breakdown
- Failure analysis with detailed error information
- Comparison with previous runs (if available)
- Cost tracking summary

### 18.3 Data Retention

| Data | Retention |
|------|-----------|
| Full evaluation results | Indefinite (JSON files) |
| LLM raw responses | 90 days |
| Audit logs | 1 year |

---

## 19. Implementation Tasks (Updated)

### P0 — Core Infrastructure

1. **Implement Dataset Manager**
   - Acceptance: Loads JSON manifest, validates structure, groups by category
   - Dependencies: None

2. **Implement Response Parser**
   - Acceptance: Extracts tools_called, escalation_level from LLM output strings; includes fallback regex extraction
   - Dependencies: None

4. **Implement Scoring Engine**
   - Acceptance: Computes all 6 metric scores (with latency normalization), composite score, confusion matrix
   - Dependencies: Task 2 (Response Parser)

5. **Implement Error Handler**
   - Acceptance: Handles all error categories per §14.1; produces partial results on failure
   - Dependencies: None

### P1 — Evaluation Pipeline

6. **Implement Test Runner Engine (with parallel execution)**
   - Acceptance: Runs single and batch evaluations with async parallel execution; semaphore-based rate limiting
   - Dependencies: Tasks 1, 3, 4, 5

7. **Implement Report Generator**
   - Acceptance: Produces JSON and Markdown reports with all metrics, including cost tracking
   - Dependencies: Task 4

8. **Implement Comparison Report**
   - Acceptance: Compares two evaluation runs, highlights changes, detects regressions
   - Dependencies: Task 7

### P2 — Security and Governance

10. **Implement RBAC and Audit Logging**
    - Acceptance: Role-based access control; all actions logged per §13.3
    - Dependencies: None

11. **Implement Ground Truth Validator**
    - Acceptance: Peer review workflow; disagreement tracking; versioned ground truth
    - Dependencies: Task 1

### P3 — Dataset Creation

13. **Create Initial Test Dataset (v1)**
    - Acceptance: 300+ test cases across all categories, with ground truth; includes adversarial cases per §3.2
    - Dependencies: None (parallel work)

14. **Create Temporal Test Sequences**
    - Acceptance: 10+ sequences with 3-5 steps each
    - Dependencies: Task 13

### P4 — Advanced Features

15. **Implement Consistency Analysis**
    - Acceptance: Runs each test N times, computes variance metrics; early termination for stable cases
    - Dependencies: Task 6

---

## 20. Notes

- **Security is non-negotiable**: Border surveillance data is sensitive. Implement encryption and access control from day one, not as an afterthought.
- **Cost awareness**: Track costs from the first run. Use caching and optimization strategies to keep evaluation costs manageable during active development.
- **Error resilience is critical**: The system must produce useful results even when individual test cases fail. Never let one failure invalidate an entire evaluation.
- **Metric weights are tunable**: Adjust weights based on operational priorities. Safety-critical categories (high threat detection) should carry more weight.
- **Reasoning quality matters**: The new reasoning quality metric (LLM-as-a-Judge) helps detect "lucky guesses" where the LLM picks the right tool for the wrong reason.
