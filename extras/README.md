# Extras

`pi/` holds two Pi extensions for OpenRouter and OpenCode Go limits. They are not in use yet: Dispatch's bundled Pi
bridge does not ask them, so installing one does nothing. `node --test extras/pi/limits.test.mjs` runs their tests.

Dispatch themes for other applications. Edit the Ghostty palettes here: the app build copies them into its
resources. The bat and Vim ports are maintained separately in their native formats and match the Ghostty palette and
the syntax palette in `design/Syntax highlight.dc.html`.

## Ghostty

`ghostty/dispatch` and `ghostty/dispatch-black`. Copy either to `~/.config/ghostty/themes/` and set
`theme = dispatch` or `theme = dispatch-black`. `ghostty/dispatch-night` (dispatch-black at about 60%) and
`ghostty/dispatch-darkroom` (dim red only) are the iPhone's night schemes, which the Mac does not bundle; they work in
Ghostty the same way.

## bat / batcat

From the repository root (`batcat` where that is the executable's name):

```sh
mkdir -p "$(bat --config-dir)/themes"
cp extras/bat/dispatch.tmTheme "$(bat --config-dir)/themes/"
bat cache --build
bat --theme=dispatch README.md
```

Make it the default with `--theme="dispatch"` in bat's config file or `BAT_THEME=dispatch`. After editing the theme,
copy it again and rebuild the cache ([custom themes](https://github.com/sharkdp/bat/blob/master/README.md#adding-new-themes)).

## Vim

Editor UI, syntax, diffs, spelling, Markdown and terminal-buffer colors, with a 256-color fallback.

```sh
mkdir -p ~/.vim/colors && cp extras/vim/colors/dispatch.vim ~/.vim/colors/
```

```vim
syntax enable
if has('termguicolors')
  set termguicolors
endif
colorscheme dispatch
```

`termguicolors` with a true-color terminal such as Ghostty gives the exact palette; the colorscheme leaves that
option to your configuration ([highlight](https://vimhelp.org/syntax.txt.html#%3Ahighlight)).
