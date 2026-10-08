# Dispatch for Vim

Matches Dispatch's Ghostty and bat palette, with editor UI, syntax, diffs,
spelling, Markdown, and terminal-buffer colors. Includes a 256-color fallback.

Install from the repository root:

```sh
mkdir -p ~/.vim/colors
cp extras/vim/colors/dispatch.vim ~/.vim/colors/
```

Enable in Vim or add to `~/.vimrc`:

```vim
syntax enable
if has('termguicolors')
  set termguicolors
endif
colorscheme dispatch
```

Use `termguicolors` with a true-color terminal such as Ghostty for exact palette
colors. The colorscheme itself leaves that option to your configuration.
See Vim's [highlight documentation](https://vimhelp.org/syntax.txt.html#%3Ahighlight).
