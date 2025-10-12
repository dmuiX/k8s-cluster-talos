#!/bin/bash
# Script to add "additionalProperties: false" to CRD schemas to enable strict validation

set -e

SCHEMA_DIR="../.vscode/schemas"

echo "Making CRD schemas strict by adding 'additionalProperties: false'..."

# Function to add additionalProperties: false recursively to all objects in a JSON schema
make_strict() {
    local input_file="$1"
    local output_file="$2"
    
    echo "Processing: $input_file"
    
    # Use jq to recursively add "additionalProperties": false to all objects with "properties"
    jq 'walk(
        if type == "object" then
            if has("properties") and (has("additionalProperties") | not) then
                . + {"additionalProperties": false}
            else
                .
            end
        else
            .
        end
    )' "$input_file" > "$output_file"
    
    echo "  -> Created strict version: $output_file"
}

# Process all JSON schemas in the schema directory
cd "$(dirname "$0")"

if [ ! -d "$SCHEMA_DIR" ]; then
    echo "Error: Schema directory not found: $SCHEMA_DIR"
    exit 1
fi

for schema_file in "$SCHEMA_DIR"/*.json; do
    if [ -f "$schema_file" ]; then
        filename=$(basename "$schema_file" .json)
        strict_file="$SCHEMA_DIR/${filename}-strict.json"
        make_strict "$schema_file" "$strict_file"
    fi
done

echo ""
echo "✅ Done! Strict schemas created:"
ls -lh "$SCHEMA_DIR"/*-strict.json

echo ""
echo "Update your workspace settings to use the *-strict.json schemas for better validation!"
