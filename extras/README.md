# Extras

Dispatch themes and companion files for other applications:

- [Ghostty](ghostty/): `dispatch` and `dispatch-black`, the source palettes bundled
  into Dispatch during the Xcode build. Copy either file to
  `~/.config/ghostty/themes/` and set `theme = dispatch` or `theme = dispatch-black`
  in Ghostty's configuration.
- [bat / batcat](bat/README.md): syntax highlighting with the Dispatch palette.
- [Vim](vim/README.md): syntax highlighting and editor colors.

Edit the Ghostty palettes here. The app build copies them into its resources;
the bat and Vim ports are maintained separately in their native formats.
