# YAML Schema Validation Troubleshooting

## Clearing YAML Extension Cache

The Red Hat YAML extension caches schemas, which can cause issues when schemas are updated.

### Method 1: Clear Cache Directory
```bash
# Remove the YAML extension cache
rm -rf ~/.vscode/extensions/redhat.vscode-yaml-*/out/server/
# Or for VSCode variants
rm -rf ~/.vscode-server/extensions/redhat.vscode-yaml-*/out/server/
```

### Method 2: VS Code Settings to Reduce Caching Issues
Add to your settings:
```json
{
    "yaml.schemaStore.enable": false,
    "yaml.customTags": [],
    "yaml.maxItemsComputed": 5000
}
```

### Method 3: Force Schema Refresh
1. Open Command Palette (`Ctrl+Shift+P`)
2. Run: `Developer: Reload Window`
3. If that doesn't work: `Developer: Reload Window Without Extensions Cache`

### Method 4: Disable/Re-enable Extension
1. Open Extensions view
2. Find "YAML" by Red Hat
3. Click "Disable"
4. Wait a moment
5. Click "Enable"

### Method 5: Use File URI with Timestamp (Hack)
When schemas change frequently, you can add a query parameter:
```json
{
    "yaml.schemas": {
        "file:///path/to/schema.json?v=20251006": ["**/*.yml"]
    }
}
```
Change the timestamp when you update the schema.

## Best Practices

1. **Use file:// URLs for local schemas** - They're faster and avoid network caching
2. **Reload window after schema changes** - Always reload after updating schemas
3. **Use strict schemas** - Set `additionalProperties: false` to catch typos
4. **Keep schemas in version control** - Include `.vscode/schemas/` in git

## Verifying Schema is Applied

Check the status bar at the bottom of VS Code when editing a YAML file.
It should show the schema name. Click it to see which schema is active.

## Regenerating Strict Schemas

When CRDs are updated in your cluster:
```bash
cd /path/to/k8s-cluster-talos
./scripts/make-schemas-strict.sh
# Then reload VS Code window
```
