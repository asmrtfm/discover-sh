//! Order-preserving parallel map over a slice.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;

/// Maps `f` over `items` on all cores, keeping order.
pub fn par_map<T: Sync, R: Send>(items: &[T], f: impl Fn(&T) -> R + Sync) -> Vec<R> {
  let workers = thread::available_parallelism()
    .map_or(1, |n| n.get())
    .min(items.len())
    .max(1);
  let next = AtomicUsize::new(0);
  let (f, next) = (&f, &next);
  let mut slots: Vec<Option<R>> = items.iter().map(|_| None).collect();
  thread::scope(|scope| {
    let handles: Vec<_> = (0..workers)
      .map(|_| {
        scope.spawn(move || {
          let mut done = Vec::new();
          loop {
            let i = next.fetch_add(1, Ordering::Relaxed);
            let Some(item) = items.get(i) else { break };
            done.push((i, f(item)));
          }
          done
        })
      })
      .collect();
    for handle in handles {
      for (i, r) in handle.join().expect("worker panicked") {
        slots[i] = Some(r);
      }
    }
  });
  slots.into_iter().map(|r| r.expect("every slot filled")).collect()
}
