---
name: add-keymap
description: Guided workflow for adding a new keymap to the Neovim configuration
---

# Add Keymap

Walk through adding a new keymap:

1. Ask what action the user wants to bind
2. Query existing keymaps via nvim_get_keymaps to find conflicts
3. Suggest available keys that fit the user's convention
4. Determine which file the keymap belongs in (mappings.lua, a plugin file, or ftplugin)
5. Write the keymap using vim.keymap.set with a desc field
6. Offer to hot-reload via nvim_exec_lua
7. Verify the keymap is active by querying keymaps again
