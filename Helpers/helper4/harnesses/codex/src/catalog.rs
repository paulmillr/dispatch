use crate::{
    channel::{Channel, failure},
    native,
};
use dispatch_helper4_core::{
    api::{Done, Io, deferred},
    json::Data,
};
use std::{cell::RefCell, rc::Rc};

pub fn list(
    channel: Rc<RefCell<Channel>>,
    io: &mut dyn Io,
    mut models: Vec<native::Model>,
    cursor: Option<String>,
    done: Done<native::Catalog>,
) {
    let mut params = vec![
        ("limit", Data::Unsigned(100)),
        ("includeHidden", Data::Bool(true)),
    ];
    if let Some(cursor) = &cursor {
        params.push(("cursor", Data::String(cursor)));
    }
    let next = channel.clone();
    let previous = cursor.clone();
    channel.borrow_mut().request(
        io,
        "model/list",
        Data::Object(params),
        Box::new(move |io, result| {
            let result = result.and_then(|value| native::catalog(&value.root().write()?));
            match result {
                Ok(page) => {
                    models.extend(page.models);
                    if page.cursor == previous && previous.is_some() || models.len() > 16_384 {
                        deferred(done)(io, Err(failure("models", "Invalid model catalog cursor.")));
                    } else if page.cursor.is_some() {
                        list(next, io, models, page.cursor, done);
                    } else {
                        deferred(done)(
                            io,
                            Ok(native::Catalog {
                                models,
                                cursor: None,
                            }),
                        );
                    }
                }
                Err(error) => deferred(done)(io, Err(error)),
            }
        }),
    );
}
