import gleam/set.{type Set}
import gleam/string

/// If there are no trigrams, return an empty set.
pub fn unique_trigrams(data: BitArray) -> Set(String) {
  let result =
    data
    |> fold_trigrams(from: set.new(), with: fn(acc, trigram) {
      set.insert(acc, trigram)
    })

  case result {
    Ok(trigrams) -> trigrams
    Error(Nil) -> set.new()
  }
}

@internal
pub fn fold_trigrams(
  over bit_array: BitArray,
  from initial: a,
  with fun: fn(a, String) -> a,
) -> Result(a, Nil) {
  case bit_array {
    <<a:utf8_codepoint, b:utf8_codepoint, c:utf8_codepoint, rest:bytes>> ->
      Ok(do_fold_trigrams(a, b, c, rest, initial, fun))
    _ -> Error(Nil)
  }
}

fn do_fold_trigrams(
  a: UtfCodepoint,
  b: UtfCodepoint,
  c: UtfCodepoint,
  rest: BitArray,
  acc: acc,
  fun: fn(acc, String) -> acc,
) -> acc {
  let acc = case is_ascii(a) && is_ascii(b) && is_ascii(c) {
    True -> fun(acc, string.from_utf_codepoints([a, b, c]))
    False -> acc
  }

  case rest {
    <<d:utf8_codepoint, rest:bytes>> -> {
      do_fold_trigrams(b, c, d, rest, acc, fun)
    }
    _ -> acc
  }
}

fn is_ascii(codepoint: UtfCodepoint) -> Bool {
  string.utf_codepoint_to_int(codepoint) < 128
}
