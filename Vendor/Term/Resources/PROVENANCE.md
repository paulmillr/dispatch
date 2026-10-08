# Ghostty resources

`ghostty/` is what Dispatch bundles as its terminal resources: Ghostty's shell integration and
its themes, as Ghostty's own build installs them (`zig-out/share/ghostty`, `*.md` files excluded),
at Ghostty commit 31bdcd5a79639bbac97c1a94e0f41d0f5ff84ca2.

- `shell-integration/`: `src/shell-integration` of ghostty-org/ghostty at commit
  31bdcd5a79639bbac97c1a94e0f41d0f5ff84ca2 (MIT, `ghostty/LICENSE`).
- `themes/`: https://deps.files.ghostty.org/ghostty-themes-release-20260824-153547-75c93ee.tgz
  (SHA-256 b1fd1f31057f97c1274db03c6ce44960837a1a41f52275cbc64aee2e6e34eb9e, Zig package hash
  N-V-__8AAGZkBACH0haGC9R-hfNPYWxu16hr-ydEsolad9GV: the `iterm2_themes` dependency of that revision),
  generated from iTerm2-Color-Schemes (https://github.com/mbadolato/iTerm2-Color-Schemes, MIT).
- `LICENSE`: Ghostty's license at that commit.

To refresh after changing the pinned revision: copy `src/shell-integration` (without `*.md`) from
the new revision, unpack its `iterm2_themes` package (without `*.md`) into `themes/`, and update
this file.
