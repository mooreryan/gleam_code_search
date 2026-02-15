import gleeunit
import iv

pub fn main() -> Nil {
  gleeunit.main()
}

// gleeunit test functions end in `_test`
pub fn hello_world_test() {
  let name = "Joe"
  let greeting = "Hello, " <> name <> "!"

  assert greeting == "Hello, Joe!"
}

pub fn x_test() {
  let l = [1, 2, 3, 4]
  let a = iv.from_list(l)

  assert iv.get(a, 0) == Ok(1)

  assert iv.get(a, 3) == Ok(4)
}
