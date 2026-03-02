# AGENTS.md

This file contains guidelines for agentic coding agents operating in this repository.

## Repository Overview

This repository contains shell scripts for Azure VM provisioning and management:
- `provision_vm.sh`: Creates Azure VM with custom data and opens port 80
- `get_available_sizes.sh`: Fetches VM sizes and pricing for a location
- `custom_data_nginx.sh`: User data script that installs nginx on VM boot
- `delete_resource_group.sh`: Cleans up Azure resource group

## Build/Lint/Test Commands

### Lint Commands
- `bash -n script.sh` - Check script syntax without executing
- `shellcheck script.sh` - Run ShellCheck for best practices (if available)

### Test Commands
- `bash -x script.sh` - Execute script with debug output
- `./test_pricing.sh` - Test Azure pricing API connectivity
- Run scripts in dry-run mode first (add `--dry-run` flags where supported)

## Shell Script Guidelines

### Script Structure
- Always start with `#!/usr/bin/env bash` for portability
- Include usage statement or help message for scripts with parameters
- Use consistent 4-space indentation
- Separate logical sections with comments

### Error Handling
- Use `set -euo pipefail` at the top of every script
- Check command exit status: `if ! command; then ...` or `command || exit 1`
- Redirect errors to stderr: `echo "ERROR: $1" >&2`
- Create reusable `log_error()` function for consistent error handling

### Variable Usage
- Uppercase for constants: `RESOURCE_GROUP="MyGroup"`
- Lowercase with underscores for local variables: `local vm_ip=""`
- Always quote variable expansions: `"$VAR"` not `$VAR`
- Use `local` for function-scoped variables

### Functions
- Use functions to encapsulate reusable logic
- Return exit codes (0 for success, non-zero for failure)
- Document function purpose in comments
- Call `main` function at the end of scripts

### Azure CLI Usage
- Use `az` commands with proper resource group and location parameters
- Use `--query` and `-o` flags for structured output
- Handle JSON output with `jq` for complex parsing
- Example: `az vm show -g "$RG" -n "$VM" --query publicIps -o tsv`

### Text Processing
- Use `jq` for JSON manipulation
- Use `awk` for column-based text processing
- Use `sed` for simple substitutions
- Use `sort -u` for deduplication

## Code Style

### Naming Conventions
- Variables: `snake_case` for local, `UPPER_SNAKE_CASE` for constants
- Functions: `snake_case` with descriptive names
- Descriptive names over abbreviations

### Comments
- Document script purpose, usage, and parameters in header
- Comment non-obvious logic
- Use `>&2` for debug/error messages to stderr

### Security
- Never commit secrets or credentials
- Use environment variables for sensitive data
- Validate all user input
- Use secure permissions: `chmod 755 script.sh`

## Development Workflow

### Git Commands
- `git status` - Check working tree status
- `git diff` - Review changes before committing
- `git log` - Review commit history
- Follow conventional commit messages

### Debugging
- `bash -x script.sh` - Full debug trace
- `set -x` / `set +x` - Targeted debug sections
- Add `echo` statements for variable inspection
- Use `strace` for system call tracing

### Testing
- Test in non-production environments first
- Use temporary resource groups for Azure testing
- Validate output with sample data
- Always test cleanup procedures

## Troubleshooting

### Common Issues
- **Permission denied**: Run `chmod +x script.sh`
- **Command not found**: Check PATH or use full paths
- **JSON parsing errors**: Validate with `jq .`
- **Azure CLI errors**: Run `az login` and `az account show`

### Azure Commands
- `az login --use-device-code` - Authenticate interactively
- `az account show` - Verify current subscription
- `az vm list` - List existing VMs
- `az group delete --name RG --yes --no-wait` - Delete resource group

## Examples

### Well-Structured Script
```bash
#!/usr/bin/env bash
set -euo pipefail

# Constants
RESOURCE_GROUP="MyGroup"

# Functions
log_error() {
    echo "ERROR: $1" >&2
    exit 1
}

create_resource_group() {
    if ! az group create --name "$RESOURCE_GROUP" --location "$LOCATION"; then
        log_error "Failed to create resource group"
    fi
}

main() {
    create_resource_group
}

main
```

### Bad Practices to Avoid
```bash
#!/bin/bash
# Missing error handling, unquoted variables

az group create --name $resource_group --location westus
```

## Contributing

### Code Reviews
- Check error handling completeness
- Validate Azure resource naming conventions
- Ensure proper documentation

### Pull Requests
- Include description of changes
- Provide testing instructions
- Document breaking changes