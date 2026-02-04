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

## Cursor/Copilot Rules

### Cursor Rules
- No cursor rules found in .cursor/rules/ or .cursorrules files

### Copilot Rules
- No copilot instructions found in .github/copilot-instructions.md

This repository primarily contains shell scripts for Azure VM provisioning, with the following key files:
- `custom_data_nginx.sh`: Installs nginx
- `get_available_sizes.sh`: Fetches Azure VM sizes and pricing information
- `provision_vm.sh`: Creates VM with custom data and opens port 80