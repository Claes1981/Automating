# AGENTS.md

This file contains guidelines for agentic coding agents operating in this repository.

## Build/Lint/Test Commands

### Build Commands
- `npm run build` - Build the application
- `make build` - Alternative build command if Makefile is present

### Lint Commands
- `npm run lint` - Run linter
- `eslint .` - ESLint for JavaScript/TypeScript files
- `prettier --check .` - Prettier code formatting check

### Test Commands
- `npm test` - Run all tests
- `npm run test:watch` - Run tests in watch mode
- `npm run test:coverage` - Run tests with coverage report
- For running a single test: `npm run test -- --testNamePattern="test name"` or `jest --testNamePattern="test name"`

## Code Style Guidelines

### Imports
- Use consistent import ordering (standard library, external dependencies, local imports)
- Prefer named imports over default imports when possible
- Group imports by category with blank lines between groups

### Formatting
- Use Prettier for code formatting
- Follow 2-space indentation
- No trailing whitespace
- Unix line endings (LF)

### Types
- TypeScript files should have proper type annotations
- Use interfaces for object shapes
- Prefer readonly arrays and objects when possible
- Use union types for flexible values

### Naming Conventions
- camelCase for variables and functions
- PascalCase for class names
- UPPER_SNAKE_CASE for constants
- Descriptive names over short abbreviations
- Prefix private members with underscore (_)

### Error Handling
- Use try/catch blocks for asynchronous operations
- Handle errors gracefully with meaningful error messages
- Implement proper logging for errors
- Avoid empty catch blocks

### General Principles
- Keep functions small and focused
- Prefer functional programming where appropriate
- Write tests for new features
- Follow the existing codebase patterns
- Use descriptive commit messages

## Shell Script Guidelines

### Script Structure
- Always start with a shebang (e.g., `#!/bin/bash` or `#!/usr/bin/env bash`)
- Include a usage statement or help message for complex scripts
- Use consistent indentation (2 or 4 spaces)
- Separate logical sections with comments

### Variable Usage
- Use uppercase for environment variables and constants
- Use lowercase with underscores for local variables
- Quote all variable expansions to prevent word splitting
- Declare variables with `local` in functions

### Error Handling
- Check command exit status with `if ! command; then ...` or `command || exit 1`
- Use `set -e` to exit on error (with caution)
- Use `set -u` to fail on undefined variables
- Provide meaningful error messages

### Functions
- Use functions to encapsulate reusable logic
- Document function purpose with comments
- Return exit codes (0 for success, non-zero for failure)
- Use `local` for function variables

### Best Practices
- Make scripts executable with `chmod +x script.sh`
- Use `#!/usr/bin/env bash` for portability
- Validate input parameters
- Use `jq` for JSON processing
- Use `awk` for text processing and calculations
- Use `sed` for text substitution

### Azure CLI Usage
- Use `az` commands with proper resource group and location parameters
- Store common parameters in variables at the top of the script
- Use `--query` and `-o` flags for structured output
- Handle JSON output with `jq` for complex parsing

## Cursor/Copilot Rules

### Cursor Rules
- No cursor rules found in .cursor/rules/ or .cursorrules files

### Copilot Rules
- No copilot instructions found in .github/copilot-instructions.md

## Repository Overview

This repository primarily contains shell scripts for Azure VM provisioning, with the following key files:
- `custom_data_nginx.sh`: Installs nginx
- `get_available_sizes.sh`: Fetches Azure VM sizes and pricing information
- `provision_vm.sh`: Creates VM with custom data and opens port 80

## Development Workflow

### Git Commands
- Use `git status` to check working tree status
- Use `git diff` to review changes before committing
- Use `git log` to review commit history
- Follow conventional commit message format

### Debugging
- Use `bash -x script.sh` for debugging shell scripts
- Use `set -x` and `set +x` within scripts for targeted debugging
- Use `echo` statements for simple debugging
- Use `strace` for system call tracing when needed

### Documentation
- Keep README files up to date
- Document script usage with comments
- Include example usage in script headers
- Document environment variables and parameters

## Security Best Practices

### General
- Never commit secrets or credentials
- Use environment variables for sensitive data
- Validate all user input
- Use secure permissions for scripts (755 for executable scripts)

### Azure Security
- Use managed identities where possible
- Avoid hardcoding subscription IDs or resource names
- Use Azure Key Vault for secrets management
- Follow principle of least privilege for Azure permissions

## Testing

### Script Testing
- Test scripts in a non-production environment first
- Validate output with sample data
- Test error conditions and edge cases
- Use temporary resource groups for testing Azure scripts

### Integration Testing
- Test end-to-end workflows
- Validate resource creation and configuration
- Test cleanup procedures
- Verify cost estimates match actual usage

## Examples

### Good Shell Script Practices
```bash
#!/usr/bin/env bash

# Script: example.sh
# Description: Example of well-structured shell script
# Usage: ./example.sh [options]

set -euo pipefail

# Constants
DEFAULT_REGION="northeurope"

# Variables
region="${1:-$DEFAULT_REGION}"

# Functions
function log_error() {
    echo "ERROR: $1" >&2
    exit 1
}

function validate_region() {
    if ! az account list-locations --query "[?name=='$1'].name" | grep -q "$1"; then
        log_error "Invalid region: $1"
    fi
}

# Main execution
validate_region "$region"
echo "Using region: $region"
```

### Bad Shell Script Practices
```bash
#!/bin/bash

# No error handling
# No variable quoting
# Inconsistent indentation

resource_group=MyGroup
vm_name=MyVM

az group create --name $resource_group --location westus
az vm create --resource-group $resource_group --name $vm_name --image UbuntuLTS
```

## Troubleshooting

### Common Issues
- **Permission denied**: Ensure scripts are executable (`chmod +x script.sh`)
- **Command not found**: Check PATH or use full paths to commands
- **JSON parsing errors**: Validate JSON output with `jq .`
- **Azure CLI errors**: Check authentication with `az login`
- **Network issues**: Verify connectivity to Azure endpoints

### Debugging Commands
- `bash -n script.sh` - Check syntax without executing
- `bash -x script.sh` - Execute with debug output
- `az login --use-device-code` - Authenticate interactively
- `az account show` - Verify current subscription
- `az vm list` - List existing VMs

## Performance Considerations

### Script Optimization
- Cache expensive operations (e.g., Azure API calls)
- Use efficient text processing tools (`awk`, `sed`, `grep`)
- Avoid unnecessary loops and nested commands
- Use `jq` for selective JSON field extraction

### Azure Cost Optimization
- Use smaller VM sizes for testing
- Set time limits for test resources
- Use spot instances for non-critical workloads
- Clean up resources after testing

## Contributing

### Code Reviews
- Review for security best practices
- Check error handling completeness
- Validate Azure resource naming conventions
- Ensure proper documentation

### Pull Requests
- Include description of changes
- Link to related issues
- Provide testing instructions
- Document breaking changes

### Code of Conduct
- Be respectful and constructive in reviews
- Assume positive intent
- Focus on code quality, not personal preferences
- Provide actionable feedback
