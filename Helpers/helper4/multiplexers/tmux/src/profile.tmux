refresh-client -f active-pane
refresh-client -B "dispatch-panes:%*:#{pane_id}|#{pane_width}|#{pane_height}|#{pane_pid}|#{s/[\001-\037\177|]/ /:pane_tty}|#{s/[\001-\037\177]/ /:pane_title}|#{pane_current_command}|#{@dispatch-harness-session}"
refresh-client -B "dispatch-windows:@*:#{window_id}|#{@dispatch-window}"
