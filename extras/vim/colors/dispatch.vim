" Dispatch — matches the app, Ghostty, and bat palette.
" Palette: extras/ghostty/dispatch
" Syntax: design/Syntax highlight.dc.html

set background=dark
highlight clear
if exists("syntax_on")
  syntax reset
endif
let g:colors_name = "dispatch"

" Exact RGB colors with termguicolors; nearest xterm-256 colors otherwise.
highlight Normal guifg=#c9c9ce guibg=#0d0d0f gui=NONE ctermfg=251 ctermbg=233 cterm=NONE
highlight NormalNC guifg=#c9c9ce guibg=#0d0d0f gui=NONE ctermfg=251 ctermbg=233 cterm=NONE
highlight Comment guifg=#5c5c64 guibg=NONE gui=italic ctermfg=59 ctermbg=NONE cterm=italic
highlight Constant guifg=#d9b36a guibg=NONE gui=NONE ctermfg=179 ctermbg=NONE cterm=NONE
highlight String guifg=#7fd3a1 guibg=NONE gui=NONE ctermfg=115 ctermbg=NONE cterm=NONE
highlight Character guifg=#7fd3a1 guibg=NONE gui=NONE ctermfg=115 ctermbg=NONE cterm=NONE
highlight Number guifg=#d9b36a guibg=NONE gui=NONE ctermfg=179 ctermbg=NONE cterm=NONE
highlight Boolean guifg=#d9b36a guibg=NONE gui=NONE ctermfg=179 ctermbg=NONE cterm=NONE
highlight Float guifg=#d9b36a guibg=NONE gui=NONE ctermfg=179 ctermbg=NONE cterm=NONE
highlight Identifier guifg=#c9c9ce guibg=NONE gui=NONE ctermfg=251 ctermbg=NONE cterm=NONE
highlight Function guifg=#7ea6c9 guibg=NONE gui=NONE ctermfg=110 ctermbg=NONE cterm=NONE
highlight Statement guifg=#e07be0 guibg=NONE gui=NONE ctermfg=176 ctermbg=NONE cterm=NONE
highlight Operator guifg=#8f8f98 guibg=NONE gui=NONE ctermfg=246 ctermbg=NONE cterm=NONE
highlight PreProc guifg=#e07be0 guibg=NONE gui=NONE ctermfg=176 ctermbg=NONE cterm=NONE
highlight Type guifg=#b3a1e6 guibg=NONE gui=NONE ctermfg=146 ctermbg=NONE cterm=NONE
highlight Special guifg=#6fb3aa guibg=NONE gui=NONE ctermfg=73 ctermbg=NONE cterm=NONE
highlight Delimiter guifg=#6f6f78 guibg=NONE gui=NONE ctermfg=243 ctermbg=NONE cterm=NONE
highlight Underlined guifg=#7ea6c9 guibg=NONE gui=underline ctermfg=110 ctermbg=NONE cterm=underline
highlight Ignore guifg=#5c5c64 guibg=NONE gui=NONE ctermfg=59 ctermbg=NONE cterm=NONE
highlight Error guifg=#e07b7b guibg=#1c1c20 gui=NONE ctermfg=174 ctermbg=234 cterm=NONE
highlight Todo guifg=#d9b36a guibg=#1c1c20 gui=bold ctermfg=179 ctermbg=234 cterm=bold
highlight Cursor guifg=#0d0d0f guibg=#c9c9ce gui=NONE ctermfg=233 ctermbg=251 cterm=NONE
highlight CursorLine guifg=NONE guibg=#1c1c20 gui=NONE ctermfg=NONE ctermbg=234 cterm=NONE
highlight CursorColumn guifg=NONE guibg=#1c1c20 gui=NONE ctermfg=NONE ctermbg=234 cterm=NONE
highlight ColorColumn guifg=NONE guibg=#1c1c20 gui=NONE ctermfg=NONE ctermbg=234 cterm=NONE
highlight LineNr guifg=#5c5c64 guibg=#0d0d0f gui=NONE ctermfg=59 ctermbg=233 cterm=NONE
highlight CursorLineNr guifg=#d9b36a guibg=#1c1c20 gui=bold ctermfg=179 ctermbg=234 cterm=bold
highlight SignColumn guifg=#c9c9ce guibg=#0d0d0f gui=NONE ctermfg=251 ctermbg=233 cterm=NONE
highlight FoldColumn guifg=#5c5c64 guibg=#0d0d0f gui=NONE ctermfg=59 ctermbg=233 cterm=NONE
highlight Folded guifg=#5c5c64 guibg=#1c1c20 gui=NONE ctermfg=59 ctermbg=234 cterm=NONE
highlight NonText guifg=#5c5c64 guibg=NONE gui=NONE ctermfg=59 ctermbg=NONE cterm=NONE
highlight EndOfBuffer guifg=#1c1c20 guibg=NONE gui=NONE ctermfg=234 ctermbg=NONE cterm=NONE
highlight SpecialKey guifg=#5c5c64 guibg=NONE gui=NONE ctermfg=59 ctermbg=NONE cterm=NONE
highlight Conceal guifg=#5c5c64 guibg=NONE gui=NONE ctermfg=59 ctermbg=NONE cterm=NONE
highlight Visual guifg=#ececf0 guibg=#2e2e34 gui=NONE ctermfg=255 ctermbg=236 cterm=NONE
highlight Search guifg=#0d0d0f guibg=#d9b36a gui=NONE ctermfg=233 ctermbg=179 cterm=NONE
highlight IncSearch guifg=#0d0d0f guibg=#e07be0 gui=NONE ctermfg=233 ctermbg=176 cterm=NONE
highlight CurSearch guifg=#0d0d0f guibg=#e07be0 gui=NONE ctermfg=233 ctermbg=176 cterm=NONE
highlight MatchParen guifg=#ececf0 guibg=#2e2e34 gui=bold ctermfg=255 ctermbg=236 cterm=bold
highlight StatusLine guifg=#ececf0 guibg=#2e2e34 gui=NONE ctermfg=255 ctermbg=236 cterm=NONE
highlight StatusLineNC guifg=#5c5c64 guibg=#1c1c20 gui=NONE ctermfg=59 ctermbg=234 cterm=NONE
highlight VertSplit guifg=#2e2e34 guibg=#0d0d0f gui=NONE ctermfg=236 ctermbg=233 cterm=NONE
highlight WinSeparator guifg=#2e2e34 guibg=#0d0d0f gui=NONE ctermfg=236 ctermbg=233 cterm=NONE
highlight Pmenu guifg=#c9c9ce guibg=#1c1c20 gui=NONE ctermfg=251 ctermbg=234 cterm=NONE
highlight PmenuSel guifg=#ececf0 guibg=#2e2e34 gui=NONE ctermfg=255 ctermbg=236 cterm=NONE
highlight PmenuSbar guifg=NONE guibg=#1c1c20 gui=NONE ctermfg=NONE ctermbg=234 cterm=NONE
highlight PmenuThumb guifg=NONE guibg=#5c5c64 gui=NONE ctermfg=NONE ctermbg=59 cterm=NONE
highlight TabLine guifg=#5c5c64 guibg=#1c1c20 gui=NONE ctermfg=59 ctermbg=234 cterm=NONE
highlight TabLineSel guifg=#ececf0 guibg=#2e2e34 gui=bold ctermfg=255 ctermbg=236 cterm=bold
highlight TabLineFill guifg=NONE guibg=#0d0d0f gui=NONE ctermfg=NONE ctermbg=233 cterm=NONE
highlight Title guifg=#7ea6c9 guibg=NONE gui=bold ctermfg=110 ctermbg=NONE cterm=bold
highlight Directory guifg=#7ea6c9 guibg=NONE gui=NONE ctermfg=110 ctermbg=NONE cterm=NONE
highlight ErrorMsg guifg=#e07b7b guibg=NONE gui=NONE ctermfg=174 ctermbg=NONE cterm=NONE
highlight WarningMsg guifg=#d9b36a guibg=NONE gui=NONE ctermfg=179 ctermbg=NONE cterm=NONE
highlight MoreMsg guifg=#7fd3a1 guibg=NONE gui=NONE ctermfg=115 ctermbg=NONE cterm=NONE
highlight ModeMsg guifg=#7fd3a1 guibg=NONE gui=NONE ctermfg=115 ctermbg=NONE cterm=NONE
highlight Question guifg=#6fb3aa guibg=NONE gui=NONE ctermfg=73 ctermbg=NONE cterm=NONE
highlight WildMenu guifg=#0d0d0f guibg=#7ea6c9 gui=NONE ctermfg=233 ctermbg=110 cterm=NONE
highlight DiffAdd guifg=#7fd3a1 guibg=#182a22 gui=NONE ctermfg=115 ctermbg=235 cterm=NONE
highlight DiffDelete guifg=#e07b7b guibg=#301e22 gui=NONE ctermfg=174 ctermbg=235 cterm=NONE
highlight DiffChange guifg=#7ea6c9 guibg=#1b252f gui=NONE ctermfg=110 ctermbg=235 cterm=NONE
highlight DiffText guifg=#d9b36a guibg=#343020 gui=bold ctermfg=179 ctermbg=236 cterm=bold
highlight SpellBad guifg=NONE guibg=NONE gui=undercurl ctermfg=NONE ctermbg=NONE cterm=undercurl guisp=#e07b7b
highlight SpellCap guifg=NONE guibg=NONE gui=undercurl ctermfg=NONE ctermbg=NONE cterm=undercurl guisp=#7ea6c9
highlight SpellRare guifg=NONE guibg=NONE gui=undercurl ctermfg=NONE ctermbg=NONE cterm=undercurl guisp=#b3a1e6
highlight SpellLocal guifg=NONE guibg=NONE gui=undercurl ctermfg=NONE ctermbg=NONE cterm=undercurl guisp=#6fb3aa

" Standard syntax links and common Markdown/diff groups.
highlight! link Conditional Statement
highlight! link Repeat Statement
highlight! link Label Statement
highlight! link Keyword Statement
highlight! link Exception Statement
highlight! link Include PreProc
highlight! link Define PreProc
highlight! link Macro PreProc
highlight! link PreCondit PreProc
highlight! link StorageClass Statement
highlight! link Structure Type
highlight! link Typedef Type
highlight! link SpecialChar Special
highlight! link Tag Special
highlight! link SpecialComment Comment
highlight! link Debug Special
highlight! link lCursor Cursor
highlight! link CursorIM Cursor
highlight! link VisualNOS Visual
highlight! link StatusLineTerm StatusLine
highlight! link StatusLineTermNC StatusLineNC
highlight! link QuickFixLine PmenuSel
highlight! link diffAdded String
highlight! link diffRemoved ErrorMsg
highlight! link diffChanged Number
highlight! link diffFile Title
highlight! link diffNewFile String
highlight! link diffOldFile ErrorMsg
highlight! link diffLine Function
highlight! link markdownHeadingDelimiter Title
highlight! link markdownCode String
highlight! link markdownCodeBlock String
highlight! link markdownLinkText Underlined
highlight! link markdownUrl Underlined
highlight markdownBold guifg=#ececf0 guibg=NONE gui=bold ctermfg=255 ctermbg=NONE cterm=bold
highlight markdownItalic guifg=#c9c9ce guibg=NONE gui=italic ctermfg=251 ctermbg=NONE cterm=italic

" Palette for Vim terminal buffers.
let g:terminal_ansi_colors = [
      \ '#1c1c20', '#e07b7b', '#7fd3a1', '#d9b36a',
      \ '#7ea6c9', '#e07be0', '#6fb3aa', '#c9c9ce',
      \ '#5c5c64', '#ec9b9b', '#a3e3bd', '#e8cb8f',
      \ '#a3c4df', '#b3a1e6', '#9ad0c9', '#ececf0']
