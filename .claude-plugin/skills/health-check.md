---
name: health-check
description: Run diagnostics on the Neovim configuration
---

# Health Check

Run a comprehensive health check:

1. Query loaded plugins — check for load errors
2. Query LSP state — verify expected servers are attached
3. Query treesitter — check parser availability for common filetypes
4. Read the config files — look for common issues (deprecated APIs, typos)
5. Check for keymap conflicts across all modes
6. Verify the Python provider is configured correctly
7. Present a summary with issues found and suggestions
