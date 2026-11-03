use super::*;
use crate::harness::{Tree, both, drive, system};

/// `files.read` of `path` from its start: the bytes, or the error.
fn read(files: &mut Files, path: &Path) -> Result<Vec<u8>, Error> {
    let request = Read {
        path: path.to_path_buf(),
        offset: 0,
        length: Some(64),
        revision: Default::default(),
    };
    let bytes = Rc::new(RefCell::new(Vec::new()));
    let sink = bytes.clone();
    let chunk: Chunk = Box::new(move |io, piece, done| {
        sink.borrow_mut().extend(piece);
        done(io, Ok(()));
    });
    drive(&mut system(), files, move |files, io, done| {
        files.read(io, &request, 1 << 20, chunk, done)
    })?;
    Ok(bytes.take())
}

#[test]
fn a_folder_read_answers_is_directory_and_files_still_read() {
    let tree = Tree::new("read");
    tree.file("a.txt", b"hello");
    tree.file("src/b.txt", b"");
    for mut files in both() {
        let folder = read(&mut files, &tree.root.join("src")).unwrap_err();
        assert_eq!(folder.code, "is_directory", "{folder:?}");
        assert_eq!(read(&mut files, &tree.root.join("a.txt")).unwrap(), b"hello");
        assert_eq!(read(&mut files, &tree.root.join("gone")).unwrap_err().code, "not_found");
    }
}
