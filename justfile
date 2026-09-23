# Threat-model skill: lint, tests, and evals. `just` lists the recipes.

judge := "claude-sonnet-5"

default:
    @just --list

# Lint the skill and test the eval checker
test:
    python3 tests/lint_skill.py
    python3 tests/test_check.py

# Regenerate a case's graders from its ground-truth.md
graders case:
    python3 evals/harness/graders.py evals/{{case}}

# Run a case in the container; variant is full, no-<agent>, a comma list, or all
eval case variant="full" runs="1" *args: (graders case)
    python3 evals/harness/run.py --variant {{variant}} -- --case {{case}} --runs {{runs}} --judge-model {{judge}} {{args}}

# Every variant, three runs each: the ablation
ablate case runs="3":
    just eval {{case}} all {{runs}}

# Re-run the structural checks on a results directory
check stamp:
    python3 evals/harness/check.py evals/results/{{stamp}}

# Rebuild the eval image
image:
    docker --context orbstack build -t threat-model-eval evals/docker
