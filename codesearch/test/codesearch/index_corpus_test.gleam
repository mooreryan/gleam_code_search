import codesearch/index_corpus
import gleam/bit_array
import gleam/list
import gleam/result

fn trigram_list_from_string(string: String) -> Result(List(String), Nil) {
  bit_array.from_string(string)
  |> index_corpus.fold_trigrams(from: [], with: fn(acc, trigram) {
    [trigram, ..acc]
  })
  |> result.map(list.reverse)
}

pub fn fold_trigrams__0_letter__test() {
  assert trigram_list_from_string("") == Error(Nil)
}

pub fn fold_trigrams__1_letter__test() {
  assert trigram_list_from_string("a") == Error(Nil)
}

pub fn fold_trigrams__2_letters__test() {
  assert trigram_list_from_string("ab") == Error(Nil)
}

pub fn fold_trigrams__3_letters__test() {
  assert trigram_list_from_string("abc") == Ok(["abc"])
}

pub fn fold_trigrams__4_letters__test() {
  assert trigram_list_from_string("abcd") == Ok(["abc", "bcd"])
}

pub fn fold_trigrams__5_letters__test() {
  assert trigram_list_from_string("abcde") == Ok(["abc", "bcd", "cde"])
}

pub fn fold_trigrams__6_letters__test() {
  assert trigram_list_from_string("abcdef") == Ok(["abc", "bcd", "cde", "def"])
}

pub fn fold_trigrams__7_letters__test() {
  assert trigram_list_from_string("abcdefg")
    == Ok(["abc", "bcd", "cde", "def", "efg"])
}

pub fn fold_trigrams__only_emoji__test() {
  assert trigram_list_from_string("🍕🍕🍕") == Ok([])
}

pub fn fold_trigrams__emoji_in_middle__test() {
  assert trigram_list_from_string("ab🍕cd") == Ok([])
}

pub fn fold_trigrams__ascii_separated_by_emoji__test() {
  assert trigram_list_from_string("abc🍕def") == Ok(["abc", "def"])
}

pub fn fold_trigrams__division_sign_in_middle__test() {
  assert trigram_list_from_string("a÷b") == Ok([])
}

pub fn fold_trigrams__ascii_separated_by_division__test() {
  assert trigram_list_from_string("abc÷defg") == Ok(["abc", "def", "efg"])
}

pub fn fold_trigrams__mixed_non_ascii__test() {
  assert trigram_list_from_string("ab÷🍕cd") == Ok([])
}

pub fn fold_trigrams__ascii_before_non_ascii__test() {
  assert trigram_list_from_string("abcd🍕") == Ok(["abc", "bcd"])
}

pub fn fold_trigrams__non_ascii_before_ascii__test() {
  assert trigram_list_from_string("🍕abcd") == Ok(["abc", "bcd"])
}
