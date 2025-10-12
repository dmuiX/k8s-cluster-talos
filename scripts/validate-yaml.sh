#!/bin/bash
# Validate Kubernetes/Flux YAML files using kubeconform
# This is MUCH more reliable than VS Code YAML extension

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🔍 Validating YAML files with kubeconform..."

# Check if kubeconform is installed
if ! command -v kubeconform &> /dev/null; then
    echo -e "${YELLOW}kubeconform not found. Installing...${NC}"
    
    # Detect OS
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        wget -qO- https://github.com/yannh/kubeconform/releases/latest/download/kubeconform-linux-amd64.tar.gz | tar xz -C /tmp
        sudo mv /tmp/kubeconform /usr/local/bin/
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        brew install kubeconform
    fi
    
    echo -e "${GREEN}✓ kubeconform installed${NC}"
fi

# Validate files with strict mode and CRD support
kubeconform \
    -strict \
    -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    -summary \
    -output json \
    ../fluxcd.k8sdev.cloud/infra/controller/*.yml \
    ../fluxcd.k8sdev.cloud/apps/*.yml \
    ../argocd.k8sdev.cloud/apps/**/*.yaml 2>&1 | \
    jq -r '
        if .status == "statusError" then
            "❌ \(.filename): \(.msg)"
        elif .status == "statusValid" then
            "✅ \(.filename)"
        else
            .
        end
    '

EXIT_CODE=${PIPESTATUS[0]}

if [ $EXIT_CODE -eq 0 ]; then
    echo -e "\n${GREEN}✓ All YAML files are valid!${NC}"
else
    echo -e "\n${RED}✗ Validation failed!${NC}"
    exit 1
fi
