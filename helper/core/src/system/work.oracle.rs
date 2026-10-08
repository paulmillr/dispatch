//! Unchanged helper2 work producer; extracted module body.
pub mod work {
    //! Bounded blocking work with event-driven completion and revocable results.
    use std::{
        collections::BTreeMap,
        io::{self, Read, Write},
        os::{
            fd::{AsRawFd, RawFd},
            unix::net::UnixStream,
        },
        sync::{
            Arc, Mutex,
            atomic::{AtomicBool, Ordering},
            mpsc,
        },
        thread,
    };

    #[derive(Debug, PartialEq, Eq)]
    pub enum Rejected {
        Full,
        Duplicate,
        Closed,
    }

    pub struct Completion<T> {
        pub id: u64,
        pub value: Option<T>,
    }

    struct Job<T> {
        id: u64,
        cancelled: Arc<AtomicBool>,
        run: Box<dyn FnOnce() -> T + Send>,
    }

    pub struct Executor<T> {
        jobs: mpsc::SyncSender<Job<T>>,
        results: mpsc::Receiver<Completion<T>>,
        wake: UnixStream,
        pending: BTreeMap<u64, Arc<AtomicBool>>,
        capacity: usize,
    }

    impl<T: Send + 'static> Executor<T> {
        pub fn new(workers: usize, capacity: usize) -> io::Result<Self> {
            if workers == 0 || capacity == 0 {
                return Err(io::ErrorKind::InvalidInput.into());
            }
            let (wake, notify) = UnixStream::pair()?;
            wake.set_nonblocking(true)?;
            notify.set_nonblocking(true)?;
            let (jobs, receive) = mpsc::sync_channel::<Job<T>>(capacity);
            let receive = Arc::new(Mutex::new(receive));
            let (send, results) = mpsc::sync_channel(capacity);
            for index in 0..workers {
                let receive = receive.clone();
                let send = send.clone();
                let mut notify = notify.try_clone()?;
                thread::Builder::new()
                    .name(format!("dispatch-disk-{index}"))
                    .spawn(move || {
                        loop {
                            // The lock covers admission only; jobs execute independently.
                            let job = match receive.lock().unwrap().recv() {
                                Ok(job) => job,
                                Err(_) => return,
                            };
                            let value = (!job.cancelled.load(Ordering::Acquire)).then(job.run);
                            if send.send(Completion { id: job.id, value }).is_err() {
                                return;
                            }
                            loop {
                                match notify.write(&[1]) {
                                    Err(error) if error.kind() == io::ErrorKind::Interrupted => {
                                        continue;
                                    }
                                    // A full socket already has a readable wakeup; notifications coalesce.
                                    Ok(_) => break,
                                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                                        break;
                                    }
                                    Err(_) => return,
                                }
                            }
                        }
                    })?;
            }
            Ok(Self {
                jobs,
                results,
                wake,
                pending: BTreeMap::new(),
                capacity,
            })
        }

        pub fn submit(
            &mut self,
            id: u64,
            run: impl FnOnce() -> T + Send + 'static,
        ) -> Result<(), Rejected> {
            if self.pending.contains_key(&id) {
                return Err(Rejected::Duplicate);
            }
            if self.pending.len() >= self.capacity {
                return Err(Rejected::Full);
            }
            let cancelled = Arc::new(AtomicBool::new(false));
            self.jobs
                .try_send(Job {
                    id,
                    cancelled: cancelled.clone(),
                    run: Box::new(run),
                })
                .map_err(|error| match error {
                    mpsc::TrySendError::Full(_) => Rejected::Full,
                    mpsc::TrySendError::Disconnected(_) => Rejected::Closed,
                })?;
            self.pending.insert(id, cancelled);
            Ok(())
        }

        pub fn cancel(&mut self, id: u64) -> bool {
            if let Some(token) = self.pending.get(&id) {
                token.store(true, Ordering::Release);
                true
            } else {
                false
            }
        }

        pub fn pending(&self) -> usize {
            self.pending.len()
        }

        pub fn drain(&mut self, mut emit: impl FnMut(Completion<T>)) -> io::Result<()> {
            let mut bytes = [0; 256];
            loop {
                match self.wake.read(&mut bytes) {
                    Ok(0) => break,
                    Ok(_) => {}
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                    Err(error) => return Err(error),
                }
            }
            while let Ok(mut completion) = self.results.try_recv() {
                let cancelled = self.pending.remove(&completion.id).unwrap();
                if cancelled.load(Ordering::Acquire) {
                    completion.value = None;
                }
                emit(completion);
            }
            Ok(())
        }
    }

    impl<T> AsRawFd for Executor<T> {
        fn as_raw_fd(&self) -> RawFd {
            self.wake.as_raw_fd()
        }
    }

    impl<T> Drop for Executor<T> {
        fn drop(&mut self) {
            // A filesystem syscall cannot be safely interrupted. Workers retain their
            // own resources and exit when admission closes; shutdown never joins them.
            for token in self.pending.values() {
                token.store(true, Ordering::Release);
            }
        }
    }
}
