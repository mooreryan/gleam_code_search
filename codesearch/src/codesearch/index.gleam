import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/set.{type Set}
import iv.{type Array}

/// The type representing an index for a corpus
///
pub type Index {
  Index(
    /// The files, indexed by the values of the trigram dict
    files: Array(String),
    /// Key: trigram, value: list of indices into the `files` array
    trigrams: Dict(String, Set(Int)),
  )
}

pub fn decoder() -> decode.Decoder(Index) {
  use files <- decode.field("files", string_array_decoder())
  use trigrams <- decode.field(
    "trigrams",
    decode.dict(decode.string, int_set_decoder()),
  )
  decode.success(Index(files:, trigrams:))
}

fn string_array_decoder() {
  decode.map(decode.list(decode.string), iv.from_list)
}

fn int_set_decoder() {
  decode.map(decode.list(decode.int), set.from_list)
}

pub fn to_json(index: Index) -> Json {
  let Index(files:, trigrams:) = index
  json.object([
    #("files", string_array_to_json(files)),
    #("trigrams", json.dict(trigrams, fn(string) { string }, int_set_to_json)),
  ])
}

fn string_array_to_json(a: iv.Array(String)) -> Json {
  a |> iv.to_list |> json.array(json.string)
}

/// We don't care about ordering...it's a set.
///
fn int_set_to_json(int_set: Set(Int)) -> Json {
  json.array(set.to_list(int_set), json.int)
}
