//! A thread-safe memo table for values computed once per key (parsed facts
//! per file, compiled patterns per name).

use std::borrow::Borrow;
use std::collections::HashMap;
use std::hash::Hash;
use std::sync::Mutex;

pub struct Memo<K, V>(Mutex<HashMap<K, V>>);

impl<K, V> Default for Memo<K, V> {
  fn default() -> Self {
    Memo(Mutex::default())
  }
}

impl<K: Eq + Hash, V: Clone> Memo<K, V> {
  /// The value for `key`, computed by `make` on first use. `make` runs
  /// without the lock held, so concurrent first uses may both compute it.
  pub fn get<Q>(&self, key: &Q, make: impl FnOnce() -> V) -> V
  where
    K: Borrow<Q>,
    Q: Eq + Hash + ToOwned<Owned = K> + ?Sized,
  {
    if let Some(v) = self.0.lock().unwrap().get(key) {
      return v.clone();
    }
    let v = make();
    self.0.lock().unwrap().insert(key.to_owned(), v.clone());
    v
  }
}
