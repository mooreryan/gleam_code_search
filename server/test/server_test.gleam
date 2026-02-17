import gleam/erlang/atom
import gleeunit
import server

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

pub fn format_with_commas__1_test() {
  assert server.format_with_commas(1) == "1"
}

pub fn format_with_commas__2_test() {
  assert server.format_with_commas(12) == "12"
}

pub fn format_with_commas__3_test() {
  assert server.format_with_commas(123) == "123"
}

pub fn format_with_commas__4_test() {
  assert server.format_with_commas(1234) == "1,234"
}

pub fn format_with_commas__5_test() {
  assert server.format_with_commas(12_345) == "12,345"
}

pub fn format_with_commas__6_test() {
  assert server.format_with_commas(123_456) == "123,456"
}

pub fn format_with_commas__7_test() {
  assert server.format_with_commas(1_234_567) == "1,234,567"
}

pub fn format_with_commas__8_test() {
  assert server.format_with_commas(-1) == "-1"
}

pub fn format_with_commas__9_test() {
  assert server.format_with_commas(-12) == "-12"
}

pub fn format_with_commas__10_test() {
  assert server.format_with_commas(-123) == "-123"
}

pub fn format_with_commas__11_test() {
  assert server.format_with_commas(-1234) == "-1,234"
}
