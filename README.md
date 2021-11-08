# nnn.nvim

File manager for Neovim powered by [nnn](https://github.com/jarun/nnn).

<!-- panvimdoc-ignore-start -->

![img](https://user-images.githubusercontent.com/31730729/140781823-6810811c-9bd8-4ade-a1fe-5f225cb53c76.png)

<!-- panvimdoc-ignore-end -->

## Install

Requires nnn to be installed, follow the [instructions](https://github.com/jarun/nnn/wiki/Usage#installation).

**NOTE:** Explorer mode requires nnn version v4.3.
If your distribution doesn't provide version v4.3 from its repositories, install one of the provided [static binaries](https://github.com/jarun/nnn/releases/tag/v4.3), [OBS packages](https://software.opensuse.org//download.html?project=home%3Astig124%3Annn&package=nnn) or [build from source](https://github.com/jarun/nnn/wiki/Usage#from-source).

<!-- panvimdoc-ignore-start -->

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

<!-- panvimdoc-ignore-end -->

## Usage

The plugin offers two possible modes of operation.

### Explorer Mode

Run command `:NnnExplorer` to open nnn in a vertical split simliar to `NERDTree`/`nvim-tree`.

In this mode, the plugin makes use of nnn's `-F` flag to listen for opened files. Pressing <kdb>Enter</kbd> on a file will open that file in a new buffer, while keeping the nnn window open.

[Select](https://github.com/jarun/nnn/wiki/concepts#selection) multiple files before pressing <kbd>Enter</kbd> to open multiple files simultaneously(excluding the hovered file).

### Picker Mode

Run command `:NnnPicker` to open nnn in a floating window.

In this mode only the `-p` flag is active. Picker mode implies only a single selection will be made before quitting nnn and thus the floating window.

### Bindings

Bind `NnnExplorer/NnnPicker` to toggle the plugin on/off in normal and terminal mode. The commands accept a path as optional argument. To always open nnn in the directory of the currently active buffer, use `%:p:h` as argument:

```vim
tnoremap <C-A-n> <cmd>NnnExplorer<CR>
nnoremap <C-A-n> <cmd>NnnExplorer %:p:h<CR>
tnoremap <C-A-p> <cmd>NnnPicker<CR>
nnoremap <C-A-p> <cmd>NnnPicker<CR>
```

## Configuration

### Default options

```lua
local cfg = {
	explorer = {
		cmd = "nnn",       -- command overrride (-F1 flag is implied, -a flag is invalid!)
		width = 24,        -- width of the vertical split
		side = "topleft",  -- or "botright", location of the explorer window
		session = "",      -- or "global" / "local" / "shared"
		tabs = true,       -- seperate nnn instance per tab
	},
	picker = {
		cmd = "nnn",       -- command override (-p flag is implied)
		style = {
			width = 0.9,     -- width in percentage of the viewport
			height = 0.8,    -- height in percentage of the viewport
			xoffset = 0.5,   -- xoffset in percentage
			yoffset = 0.5,   -- yoffset in percentage
			border = "single"-- border decoration for example "rounded"(:h nvim_open_win)
		},
		session = "",      -- or "global" / "local" / "shared"
	},
	auto_open = {
		setup = nil,       -- or "explorer" / "picker", auto open on setup function
		tabpage = nil,     -- or "explorer" / "picker", auto open when opening new tabpage
		empty = false,     -- only auto open on empty buffer
		ft_ignore = {      -- dont auto open for these filetypes
			"gitcommit",
		}
	},
	auto_close = false,  -- close tabpage/nvim when nnn is last window
	replace_netrw = nil, -- or "explorer" / "picker"
	mappings = {},       -- table containing mappings, see below
	windownav = {        -- window movement mappings to navigate out of nnn
		left = "<C-w>h",
		right = "<C-w>l"
	},
}
```

Edit (part of) this table to your preferences and pass it to the `setup()` function i.e.:

```lua
require("nnn").setup({
	picker = {
		cmd = "tmux new-session nnn -Pp",
		style = { border = "rounded" },
		session = "shared",
	},
	replace_netrw = "picker",
	window_nav = "<C-l>"
})
```

### Mappings

It's possible to map custom lua functions to keys which are passed the selected file or active nnn selection.
A set of builtin functions is provided which can be used as follows:

```lua
	local builtin = require("nnn").builtin
	mappings = {
		{ "<C-t>", builtin.open_in_tab },       -- open file(s) in tab
		{ "<C-s>", builtin.open_in_split },     -- open file(s) in split
		{ "<C-v>", builtin.open_in_vsplit },    -- open file(s) in vertical split
		{ "<C-p>", builtin.open_in_preview },   -- open file in preview split keeping nnn focused
		{ "<C-y>", builtin.copy_to_clipboard }, -- copy file(s) to clipboard
		{ "<C-w>", builtin.cd_to_path },        -- cd to file directory
		{ "<C-e>", builtin.populate_cmdline },  -- populate cmdline (:) with file(s)
	}
```

To create your own function mapping follow the function signature of the builtin functions which are passed a table of file names.

Note that in both picker and explorer mode, the mapping will execute on the nnn selection if it exists.

### Session

You can enable persistent sessions in nnn(`-S` flag) by setting picker and explorer mode session to one of `""`(disabled), `"global"` or `"local"`.

Alternatively you can set the session `"shared"` to share the same session between both explorer and picker mode (setting either one to "shared" will make the session shared).

### Colors

[Three](Three) highlight groups `NnnNormal`, `NnnNormalNC` and `NnnFloatBorder` are available to configure the colors for the active, inactive and picker window borders respectively.

## Tips and tricks

### Git status

[Build](https://github.com/jarun/nnn/tree/master/patches#list-of-patches) and install nnn with the [gitstatus](https://github.com/jarun/nnn/blob/master/patches/gitstatus/mainline.diff) patch and add the `-G` flag to your command override to enable git status symbols.

<!-- panvimdoc-ignore-start -->

![img](https://user-images.githubusercontent.com/31730729/140726345-0d4005e4-0ed3-494f-9c51-bdac19f277f3.png)

<!-- panvimdoc-ignore-end -->

### preview-tui

Setting the command override for picker mode to for example `tmux new-session nnn -P<plugin-key>` will open `tmux` inside the picker window and can be used to open [`preview-tui`](https://github.com/jarun/nnn/blob/master/plugins/preview-tui) inside the floating window:

<!-- panvimdoc-ignore-start -->

![img](https://user-images.githubusercontent.com/31730729/140781363-fc81ccd0-c4f3-4cb8-a771-1c221dee603f.gif)

<!-- panvimdoc-ignore-end -->
