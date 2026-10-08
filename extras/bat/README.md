# Dispatch for bat

Matches `extras/ghostty/dispatch` and the syntax palette in
`design/Syntax highlight.dc.html`: charcoal background, magenta keywords,
green strings, gold numbers, blue functions, lavender types, and muted comments.

Install from the repository root:

```sh
mkdir -p "$(bat --config-dir)/themes"
cp extras/bat/dispatch.tmTheme "$(bat --config-dir)/themes/"
bat cache --build
bat --theme=dispatch README.md
```

Use `batcat` in place of `bat` on systems with that executable name. To make
the theme the default, add `--theme="dispatch"` to bat's config file or set
`BAT_THEME=dispatch` in your shell environment.

After editing the theme, copy it again and rebuild the cache. See bat's
[custom-theme documentation](https://github.com/sharkdp/bat/blob/master/README.md#adding-new-themes).
