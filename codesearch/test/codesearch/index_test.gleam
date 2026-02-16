import codesearch/index
import gleam/dict
import gleam/set
import iv

pub fn empty_index_serializing_roundtrip__test() {
  let index = index.Index(files: iv.from_list([]), trigrams: dict.new())

  let result = index |> index.serialize |> index.deserialize

  assert result == Ok(index)
}

pub fn index_serializing_roundtrip__test() {
  let index =
    index.Index(
      files: iv.from_list(["file1", "file2"]),
      trigrams: dict.from_list([
        #("abc", set.from_list([0])),
        #("bcd", set.from_list([1])),
        #("cde", set.from_list([0, 1])),
      ]),
    )

  let result =
    index |> echo |> index.serialize |> echo |> index.deserialize |> echo

  assert result == Ok(index)
}
