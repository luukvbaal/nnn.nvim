# nnn.nvim

File manager for Neovim powered by [nnn](https://github.com/jarun/nnn).
![img](https://i.imgur.com/mtpBKUl.png)

## Install

Requires nnn to be installed, follow the [instructions](https://github.com/jarun/nnn/wiki/Usage#installation).

Then install the plugin using your plugin manager:

Install with [vim-plug](https://github.com/junegunn/vim-plug):
```vim
Plug 'luukvbaal/nnn.nvim'
call plug#end()

lua << EOF
require("nnn").setup()
EOF
```
Install with [packer](https://github.com/wbthomason/packer.nvim):
```lua
use {
	"luukvbaal/nnn.nvim",
	config = function() require("nnn").setup() end
}
```
## Usage
The plugin offers two possible modes of operation.
### Explorer Mode
Run command `:NnnExplorer` to open nnn in a side split simliar to `NERDTree`/`nvim-tree`.

In this mode, the plugin makes use of nnn's `-F` flag to listen for opened files. Pressing <kdb>Enter</kbd> on a file will open that file in a new buffer, while keeping the nnn window open.

Moreover, it is possible to [select](https://github.com/jarun/nnn/wiki/concepts#selection) multiple files before quitting nnn to add the selection to the buffer list, using the `-p` flag.
### Picker Mode
Run command `:NnnPicker` to open nnn in a floating window.

In this mode only the `-p` flag is active. Picker mode implies only a single selection will be made before quitting nnn and thus the floating window.
## Configuration
### Default options
```lua
local cfg = {
	explorer = {
		cmd = "nnn", -- command overrride (-p and -F1 flags are implied, -a flag is invalid!)
		width = 24, -- width of the vertical split
		session = "", -- or global/local/shared
	},
	picker = {
		cmd = "nnn", -- command override (-p flag is implied)
		style = {
			width = 0.9, -- width in percentage of the viewport
			height = 0.8, -- height in percentage of the viewport
			xoffset = 0.5, -- xoffset in percentage
			yoffset = 0.5, -- yoffset in percentage
			border = "single" -- border decoration e.g. "rounded"(:h nvim_open_win)
		},
		session = "", -- or global/local/shared
	},
	replace_netrw = nil, -- or explorer/picker
	mappings = {}, -- table containing mappings, see below
}
```
Edit (part of) this table to your preferences and pass it to the `setup()` function i.e.:
```lua
require("nnn").setup({
	picker = {
		cmd = "tmux new-session nnn -Pp",
		style = { border = "rounded" },
		session = "shared",
	}
	replace_netrw = "picker"
})
```

### Mappings
It is possible to map custom vim commands or lua functions to keys:
```lua
local function copy_to_clipboard(files)
	files = table.concat(files, "\n")
	vim.fn.setreg("+", files)
	print(files:gsub("\n", ", ") .. " copied to register")
end

local function cd_to_path(files)
	local dir = files[1]:match(".*/")
	local read = io.open(dir, "r")
	if read ~= nil then
		io.close(read)
		vim.cmd("execute 'cd " .. dir .. "'")
		print("working directory changed to: " .. dir)
	end
end

mappings = {
			{ "<C-t>", "tabedit" }, -- open file in tab
			{ "<C-s>", "split" }, -- open file in split
			{ "<C-v>", "vsplit" }, -- open file in vertical split
			{ "<C-w>", cd_to_path }, -- cd to file directory
			{ "<C-y>", { copy_to_clipboard, quit = false } }, -- copy file to clipboard
			{ "<S-y>", { copy_to_clipboard, quit = true } } } -- coply files to clipboard
```
When mapping a lua function, the mapping can be the function itself, or a table containing the function and a boolean indicating whether <kbd>Enter</kbd> or <kbd>q</kbd> will be pressed to execute the function. This is to facilitate both options in explorer mode.

Note that the `quit` boolean only affects explorer mode. With the above example:
* Explorer mode:
	- <kbd>Control-y</kbd> copy hovered file to clipboard
	- <kbd>Shift-y</kbd> quit and copy selected file(s) to clipboard
* Picker mode:
	- <kbd>Control-y</kbd>/<kbd>Shift-y</kbd> quit and copy selected file(s) to clipboard

### Session
You can enable persistent sessions in nnn(`-S` flag) by setting picker and explorer mode session to one of `""`(disabled), `"global"` or `"local"`.

Alternatively you can set the session `"shared"` to share the same session between both explorer and picker mode (setting either one to "shared" will make the session shared).

## Tips and tricks
### Git status
[Build](https://github.com/jarun/nnn/tree/master/patches#list-of-patches) and install nnn with the [gitstatus](https://github.com/jarun/nnn/blob/master/patches/gitstatus/mainline.diff) patch and add the `-G` flag to your command override to enable git status symbols.
![img](https://i.imgur.com/LLd8Oq5.png)
### preview-tui
Setting the command override for picker mode to e.g. `tmux new-session nnn -P<plugin-key>` will open `tmux` inside the picker window and can be used to open [`preview-tui`](https://github.com/jarun/nnn/blob/master/plugins/preview-tui) inside the floating window:
![img](https://i.imgur.com/OhfK12S.gif)
