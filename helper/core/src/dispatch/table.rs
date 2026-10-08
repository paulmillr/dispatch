use params::Rule::*;

operations! {
    self, p;
    "hello" => Object(&[]),
        core hello() value;
    "echo" => Any,
        core echo() value;
    "permissions.reduce" => Object(&[
        ("capabilities", Array(&Text)),
    ]),
        core reduce() value;
    "backends.list" => Object(&[
        ("mux", Unsigned),
    ]),
        core backends() value;
    "backends.open" => Object(&[
        ("mux", Unsigned),
        ("key", Text),
    ]),
        core open() backend;
    "backends.create" => Object(&[
        ("mux", Unsigned),
        ("key", Text),
    ]),
        mux open(text(p, "key")?) id;
    "multiplexers.list" => Object(&[]),
        core multiplexers() value;
    "launches.list" => Object(&[]),
        core launches() value;
    "containers.create" => Object(&[
        ("mux", Unsigned),
        ("parent", Unsigned),
    ]),
        mux create(local(number(p, "parent")?), None, None, None) id;
    "terminals.create" => Object(&[
        ("mux", Unsigned),
        ("parent", Unsigned),
        ("beside", Unsigned),
        ("cwd", Nullable(&Text)),
        ("launch", Unsigned),
        ("command", Nullable(&Text)),
        ("size", Object(params::GRID)),
        ("rows", Unsigned),
        ("columns", Unsigned),
        ("cell_width", Unsigned),
        ("cell_height", Unsigned),
        ("environment", Array(&Text)),
    ]),
        core create() id;
    "backends.prefix" => Object(&[
        ("mux", Unsigned),
        ("node", Unsigned),
    ]),
        mux prefix(local(number(p, "node")?)) value;
    "backends.command" => Object(&[
        ("mux", Unsigned),
        ("node", Unsigned),
        ("command", Text),
    ]),
        mux command(local(number(p, "node")?), text(p, "command")?) value;
    "entities.rename" => Object(&[
        ("mux", Unsigned),
        ("node", Unsigned),
        ("name", Text),
    ]),
        mux rename(local(number(p, "node")?), text(p, "name")?) value;
    "entities.focus" => Object(&[
        ("mux", Unsigned),
        ("node", Unsigned),
    ]),
        mux focus(local(number(p, "node")?)) value;
    "memberships.move" => Object(&[
        ("mux", Unsigned),
        ("node", Unsigned),
        ("parent", Unsigned),
        ("before", Unsigned),
    ]),
        mux r#move(
        local(number(p, "node")?),
        local(number(p, "parent")?),
        optional(p, "before").map(local)
    ) value;
    "memberships.reorder" => Object(&[
        ("mux", Unsigned),
        ("node", Unsigned),
        ("parent", Unsigned),
        ("before", Unsigned),
    ]),
        mux r#move(
        local(number(p, "node")?),
        local(number(p, "parent")?),
        optional(p, "before").map(local)
    ) value;
    "memberships.place" => Object(&[
        ("mux", Unsigned),
        ("node", Unsigned),
        ("place", Object(params::PLACE)),
    ]),
        mux place(local(number(p, "node")?), &place(p)?) value;
    "layouts.resize" => Object(&[
        ("mux", Unsigned),
        ("node", Unsigned),
        ("ratio", Decimal),
    ]),
        mux split(
        local(number(p, "node")?),
        p.get("ratio")
            .and_then(Value::number)
            .ok_or_else(|| invalid("ratio"))?
    ) value;
    "layouts.zoom" => Object(&[
        ("mux", Unsigned),
        ("terminal", Unsigned),
        ("zoomed", Boolean),
    ]),
        mux zoom(local(number(p, "terminal")?), flag(p, "zoomed")) value;
    "close.request" => Object(&[
        ("mux", Unsigned),
        ("node", Unsigned),
        ("policy", Text),
        ("check", Boolean),
    ]),
        core close() value;
    "terminals.attach" => Object(&[
        ("mux", Unsigned),
        ("terminal", Unsigned),
        ("size", Object(params::GRID)),
        ("rows", Unsigned),
        ("columns", Unsigned),
        ("cell_width", Unsigned),
        ("cell_height", Unsigned),
        ("takeover", Boolean),
    ]),
        mux attach(local(number(p, "terminal")?), size(p)?, flag(p, "takeover")) output;
    "terminals.observe" => Object(&[
        ("terminal", Unsigned),
    ]),
        core observe() value;
    "backends.claim" => Object(&[
        ("mux", Unsigned),
        ("enabled", Boolean),
    ]),
        core claim() value;
    "terminals.release" => Object(&[
        ("mux", Unsigned),
        ("terminal", Unsigned),
    ]),
        core release() value;
    "terminals.input" => Object(&[
        ("mux", Unsigned),
        ("terminal", Unsigned),
        ("bytes", Bytes),
        ("subscription", Unsigned),
    ]),
        core input() value;
    "terminals.keys" => Object(&[
        ("terminal", Unsigned),
        ("keys", Bytes),
        ("binding", Object(params::BINDING)),
    ]),
        core keys() value;
    "terminals.resize" => Object(&[
        ("mux", Unsigned),
        ("terminal", Unsigned),
        ("size", Object(params::GRID)),
        ("rows", Unsigned),
        ("columns", Unsigned),
        ("cell_width", Unsigned),
        ("cell_height", Unsigned),
    ]),
        mux resize(local(number(p, "terminal")?), size(p)?) value;
    "terminals.scroll" => Object(&[
        ("mux", Unsigned),
        ("terminal", Unsigned),
        ("lines", Signed),
        ("page", Boolean),
        ("column", Unsigned),
        ("row", Unsigned),
        ("modifiers", Unsigned),
    ]),
        mux scroll(local(number(p, "terminal")?), &scroll(p)?) value;
    "terminals.ready" => Object(&[
        ("mux", Unsigned),
        ("terminal", Unsigned),
    ]),
        mux screen(local(number(p, "terminal")?), false) value;
    "terminals.publish" => Object(&[
        ("mux", Unsigned),
        ("terminal", Unsigned),
        ("text", Text),
        ("cursor", Object(params::CURSOR)),
        ("faint_tail", Boolean),
    ]),
        core publish() value;
    "terminals.control" => Object(&[
        ("terminal", Unsigned),
        ("event", Text),
        ("bytes", Bytes),
    ]),
        core control() value;
    "renderer.request" => Object(&[
        ("mux", Unsigned),
        ("terminal", Unsigned),
        ("changed", Boolean),
    ]),
        mux screen(local(number(p, "terminal")?), flag(p, "changed")) value;
    "terminals.seek" => Object(&[
        ("mux", Unsigned),
        ("terminal", Unsigned),
        ("offset", Unsigned),
    ]),
        mux seek(local(number(p, "terminal")?), number(p, "offset")?) value;
    "terminals.history" => Object(&[
        ("terminal", Unsigned),
    ]),
        unavailable history() value;
    "clipboard.request" => Object(&[
        ("terminal", Unsigned),
    ]),
        unavailable clipboard() value;
    "chat.open" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
        ("transcript", Object(params::TRANSCRIPT)),
    ]),
        core chat() value;
    "chat.state" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
    ]),
        core state() value;
    "chat.page" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
        ("earlier", Nullable(&Text)),
        ("transcript", Object(params::TRANSCRIPT)),
    ]),
        core page() value;
    "chat.send" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
        ("text", Text),
        ("mode", Text),
        ("command", Boolean),
    ]),
        harness send(text(p, "text")?, mode(p)?, flag(p, "command")) send;
    "chat.command" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
        ("text", Text),
    ]),
        core command() value;
    "chat.stop" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
    ]),
        core stop() value;
    "chat.models" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
    ]),
        harness models() models;
    "chat.settings" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
        ("model", Text),
    ]),
        harness efforts(text(p, "model")?) efforts;
    "chat.settings.set" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
        ("model", Text),
        ("effort", Nullable(&Text)),
    ]),
        harness select(text(p, "model")?, p.get("effort").and_then(Value::string)) select;
    "chat.tools" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
        ("record", Text),
    ]),
        harness tool(text(p, "record")?) value;
    "interactions.answer" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
        ("interaction", Text),
        ("answers", Any),
    ]),
        core answer(false) value;
    "interactions.dismiss" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
        ("interaction", Text),
    ]),
        core answer(true) value;
    "queue.list" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
    ]),
        core queue("list") value;
    "queue.add" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
        ("text", Text),
        ("mode", Text),
        ("command", Boolean),
    ]),
        core queue("add") value;
    "queue.update" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
        ("item", Text),
        ("revision", Unsigned),
        ("text", Nullable(&Text)),
        ("command", Boolean),
    ]),
        core queue("update") value;
    "queue.remove" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
        ("item", Text),
        ("revision", Unsigned),
    ]),
        core queue("remove") value;
    "queue.start" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
        ("item", Text),
        ("revision", Unsigned),
        ("mode", Text),
    ]),
        core queue("start") value;
    "queue.reorder" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
        ("items", Array(&Text)),
    ]),
        core queue("reorder") value;
    "queue.restore" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
    ]),
        core queue("restore") value;
    "queue.edit" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
        ("item", Text),
        ("revision", Unsigned),
        ("editing", Boolean),
    ]),
        core queue("edit") value;
    "queue.hold" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
        ("held", Boolean),
    ]),
        core queue("hold") value;
    "chat.side" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
        ("question", Text),
        ("read_only", Boolean),
    ]),
        core side(false) value;
    "chat.side.close" => Object(&[
        ("terminal", Unsigned),
        ("session", Nullable(&Text)),
    ]),
        core side(true) value;
    "installation.install" => Object(&[
        ("launch", Unsigned),
        ("enabled", Boolean),
        ("terminal", Unsigned),
    ]),
        core install(false) value;
    "installation.audit" => Object(&[
        ("launch", Unsigned),
        ("terminal", Unsigned),
    ]),
        core install(true) value;
    "files.text" => Object(&[
        ("plugin", Text),
        ("path", Text),
    ]),
        plugin text(Path::new(text(p, "path")?)) value;
    "files.branch" => Object(&[
        ("plugin", Text),
        ("path", Text),
    ]),
        plugin branch(Path::new(text(p, "path")?)) value;
    "files.read" => Object(&[
        ("plugin", Text),
        ("path", Text),
        ("offset", Unsigned),
        ("length", Unsigned),
        ("revision", Nullable(&Object(params::REVISION))),
    ]),
        core read() value;
    "stats.sample" => Object(&[
        ("plugin", Text),
    ]),
        plugin sample() value;
    "stats.processes" => Object(&[
        ("plugin", Text),
    ]),
        plugin processes() value;
    "stats.disks" => Object(&[
        ("plugin", Text),
    ]),
        plugin disks() value;
    "plugins.reset" => Object(&[
        ("plugin", Text),
        ("topics", Array(&Text)),
    ]),
        plugin reset(&p.get("topics").map(|_| strings(p, "topics")).transpose()?.unwrap_or_default()) value;
}
