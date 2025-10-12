#!/bin/bash
# Pre-commit hook to validate YAML files
# Install: ln -s ../../scripts/pre-commit.sh .git/hooks/pre-commit

# Only validate staged YAML files
YAML_FILES=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.(ya?ml)$' || true)

if [ -z "$YAML_FILES" ]; then
    exit 0
fi

echo "🔍 Validating YAML files..."

# Run kubeconform if available
if command -v kubeconform &> /dev/null; then
    for file in $YAML_FILES; do
        if [[ -f "$file" ]]; then
            kubeconform \
                -strict \
                -ignore-missing-schemas \
                -schema-location default \
                -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
                "$file"
            
            if [ $? -ne 0 ]; then
                echo "❌ Validation failed for $file"
                echo "Fix the errors above or skip validation with: git commit --no-verify"
                exit 1
            fi
        fi
    done
    echo "✅ All YAML files validated successfully"
else
    echo "⚠️  kubeconform not installed - skipping validation"
    echo "   Install: https://github.com/yannh/kubeconform"
fi

exit 0
