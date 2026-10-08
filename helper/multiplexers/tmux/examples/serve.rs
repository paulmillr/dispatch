use dispatch_helper_core::DispatchHelper;
use dispatch_helper_tmux::Tmux;
use std::path::PathBuf;

fn main() -> std::io::Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    let mut helper = DispatchHelper::new();
    helper.add_multiplexer(Tmux::new(PathBuf::from("/usr/bin/tmux")));
    let socket = args.windows(2).find(|pair| pair[0] == "--socket").unwrap();
    helper.run(&PathBuf::from(&socket[1]))
}
