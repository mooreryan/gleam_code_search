import gleam/erlang/atom
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

// gleeunit test functions end in `_test`
pub fn hello_world_test() {
  let name = "Joe"
  let greeting = "Hello, " <> name <> "!"

  assert greeting == "Hello, Joe!"
}

pub fn pt_test() {
  let _ = put_int(1)
  assert get_int() == 1
}

// Return should be ok atom
@external(erlang, "persistent_term", "put")
fn do_put_int(key: String, int: Int) -> atom.Atom

fn put_int(int: Int) {
  do_put_int("int", int)
}

@external(erlang, "persistent_term", "get")
fn do_get_int(key: String) -> int

fn get_int() {
  do_get_int("int")
}
