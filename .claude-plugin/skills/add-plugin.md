---
name: add-plugin
description: Guided workflow for installing and configuring a new Neovim plugin
---

# Add Plugin

Walk through adding a new Neovim plugin:

1. Confirm the plugin name and purpose
2. Check if a similar plugin is already installed via nvim_get_loaded_plugins
3. Research the plugin's README for configuration options
4. Create a new file in lua/plugins/<plugin-name>.lua with the lazy.nvim spec
5. Include sensible defaults and keymaps
6. Explain any dependencies that need to be installed
7. Instruct the user to restart Neovim or run :Lazy sync
