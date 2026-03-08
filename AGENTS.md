# AGENTS.md

Guidelines for agentic coding agents operating in this repository.

## Repository Overview

Azure VM automation scripts:
- `provision_vm.sh`: Creates Azure VM with nginx, supports CLI arguments
- `get_available_sizes.sh`: Fetches VM sizes and pricing from Azure APIs
- `custom_data_nginx.sh`: User data script for VM boot (installs nginx)
- `delete_resource_group.sh`: Safely deletes resource groups with confirmation

## Build/Lint/Test Commands

### Lint
```bash
bash -n script.sh                    # Check syntax
shellcheck script.sh                 # Best practices (if available)
```

### Test
```bash
bash -x script.sh                    # Debug execution
DEBUG=true ./script.sh               # Enable debug logging
./script.sh --help                   # Show usage
./get_available_sizes.sh northeurope | head -20
```

## Shell Script Guidelines

### Script Structure
- Shebang: `#!/usr/bin/env bash` (portable)
- Error handling: `set -euo pipefail` (line 2)
- Header comment block with script purpose
- `readonly` for constants, `local` for function variables
- Call `main "$@"` at script end

### Error Handling
```bash
set -euo pipefail

log_info() { echo "$*"; }
log_error() { echo "ERROR: $*" >&2; }
log_debug() { [[ "${DEBUG:-}" == "true" ]] && echo "DEBUG: $*" >&2; }

if ! command; then
  log_error "Failed to execute command"
  return 1
fi

cleanup() { rm -f "${TEMP_FILES[@]}" 2>/dev/null; }
trap cleanup EXIT
```

### Variable Usage
- Constants: `readonly VARIABLE_NAME="value"` (UPPER_SNAKE_CASE)
- Local variables: `local variable_name=""` (snake_case)
- Always quote: `"$VAR"` never `$VAR`
- Array for temp files: `declare -a TEMP_FILES=()`

### Functions
- Name: `snake_case` with descriptive verbs
- Use `local` for all function variables
- Return exit codes (0 success, non-zero failure)
- Single responsibility: One task per function

## Code Style

### Naming Conventions
| Element | Convention | Example |
|---------|------------|---------|
| Constants | `UPPER_SNAKE_CASE` | `readonly DEFAULT_LOCATION="northeurope"` |
| Variables | `snake_case` | `local vm_ip=""` |
| Functions | `snake_case` | `create_resource_group()` |
| Files | `snake_case.sh` | `provision_vm.sh` |

### Comments
- Header: Script purpose, usage, examples
- Functions: Brief description of purpose
- Complex logic: Explain why, not what
- Use `>&2` for stderr output

### Security
- Never hardcode secrets or credentials
- Use environment variables for sensitive data
- Validate all user input
- Set permissions: `chmod 755 script.sh`

## Azure CLI Usage

```bash
# Check Azure login
if ! az account show &> /dev/null; then
  log_error "Not logged in to Azure"
  exit 1
fi

# Use --query for structured output
az vm show -g "$RG" -n "$VM" --query publicIps -o tsv

# Handle JSON with jq
az vm list-skus ... -o json | jq -r '.[].name'

# Use timeouts for long operations
timeout 600 az vm list-skus --all
```

### Resource Management
- Always specify `--resource-group` and `--location`
- Use `--no-wait` for async operations
- Check resource existence before operations
- Clean up temp files with `trap`

## Text Processing

### JSON with jq
```bash
jq -r --arg loc "$location" '
  .[] | select(.locations[]? == $loc) | .name
' file.json
```

### Temp Files
```bash
create_temp_file() {
  local temp_file=$(mktemp "/tmp/${1}_XXXXXX")
  TEMP_FILES+=("$temp_file")
  echo "$temp_file"
}
```

## Development Workflow

### Before Committing
```bash
bash -n *.sh           # Check syntax
shellcheck *.sh        # Run ShellCheck
./script.sh --help     # Test usage
git diff               # Review changes
```

### Debugging
```bash
bash -x script.sh              # Full trace
DEBUG=true ./script.sh         # Debug logging
set -x; command; set +x        # Targeted debug
```

### Testing Azure Scripts
- Use temporary resource groups
- Test in non-production subscriptions
- Always verify cleanup works

## Common Patterns

### Argument Parsing
```bash
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -g|--resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) log_error "Unknown option: $1"; exit 1 ;;
    esac
  done
}
```

### Dependency Check
```bash
check_dependencies() {
  for dep in jq curl az; do
    command -v "$dep" &> /dev/null || { log_error "$dep required"; exit 1; }
  done
}
```
