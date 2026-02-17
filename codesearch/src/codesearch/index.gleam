import codesearch/log
import codesearch/trigrams
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string
import iv.{type Array}
import simplifile

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

pub fn read_binary(index_path) {
  use bits <- result.try(
    simplifile.read_bits(index_path)
    |> result.map_error(simplifile.describe_error),
  )
  deserialize(bits)
}

pub fn deserialize(bits: BitArray) -> Result(Index, String) {
  use #(bits, files) <- result.try(deserialize_files(bits))
  use #(bits, trigrams) <- result.try(deserialize_trigrams(bits))
  use Nil <- result.try(accept_empty_bits(bits))
  Ok(Index(files, trigrams))
}

fn accept_empty_bits(bits: BitArray) {
  case bits {
    <<>> -> Ok(Nil)
    _ -> Error("malformed bits -- expected empty bits")
  }
}

fn deserialize_files(
  bits: BitArray,
) -> Result(#(BitArray, Array(String)), String) {
  case bits {
    <<file_count:little-size(32), bits:bits>> -> {
      do_deserialize_files(bits, file_count, 0, [])
    }
    _ -> Error("malformed file count")
  }
}

fn do_deserialize_files(
  bits: BitArray,
  file_count: Int,
  i: Int,
  filenames: List(String),
) -> Result(#(BitArray, Array(String)), String) {
  case i < file_count {
    False -> {
      let files = list.reverse(filenames) |> iv.from_list
      Ok(#(bits, files))
    }
    True ->
      case bits {
        <<
          filename_size:little-size(16),
          filename:bytes-size(filename_size),
          rest:bits,
        >> -> {
          let assert Ok(filename) = bit_array.to_string(filename)
          do_deserialize_files(rest, file_count, i + 1, [filename, ..filenames])
        }
        _ -> Error("malformed file info")
      }
  }
}

fn deserialize_trigrams(
  bits: BitArray,
) -> Result(#(BitArray, Dict(String, Set(Int))), String) {
  case bits {
    <<trigram_count:little-size(32), bits:bits>> -> {
      do_deserialize_trigrams(bits, trigram_count, 0, dict.new())
    }
    _ -> Error("malformed trigram count")
  }
}

fn do_deserialize_trigrams(
  bits: BitArray,
  trigram_count: Int,
  i: Int,
  trigrams: Dict(String, Set(Int)),
) -> Result(#(BitArray, Dict(String, Set(Int))), String) {
  case i < trigram_count {
    False -> Ok(#(bits, trigrams))

    True -> {
      case bits {
        <<
          a:utf8_codepoint,
          b:utf8_codepoint,
          c:utf8_codepoint,
          file_indices_count:little-size(32),
          bits:bits,
        >> -> {
          let trigram = string.from_utf_codepoints([a, b, c])
          use #(bits, file_indices) <- result.try(deserialize_file_indices(
            bits,
            file_indices_count,
          ))

          let trigrams = dict.insert(trigrams, trigram, file_indices)
          do_deserialize_trigrams(bits, trigram_count, i + 1, trigrams)
        }
        _ -> Error("malformed trigram")
      }
    }
  }
}

fn deserialize_file_indices(
  bits: BitArray,
  file_indices_count: Int,
) -> Result(#(_, _), String) {
  do_deserialize_file_indices(bits, file_indices_count, 0, [])
}

fn do_deserialize_file_indices(
  bits: BitArray,
  file_indices_count: Int,
  i: Int,
  file_indices: List(Int),
) -> Result(#(_, _), String) {
  case i < file_indices_count {
    False -> {
      let file_indices = file_indices |> set.from_list
      Ok(#(bits, file_indices))
    }
    True -> {
      case bits {
        <<file_index:little-size(32), bits:bits>> ->
          do_deserialize_file_indices(bits, file_indices_count, i + 1, [
            file_index,
            ..file_indices
          ])

        _ -> Error("malformed file index")
      }
    }
  }
}

pub fn serialize(index: Index) -> BitArray {
  let file_count = iv.size(index.files)

  log.debug("Serializing files")
  let files =
    // Reverse fold keeps the files in the correct order.
    iv.fold(index.files, <<>>, fn(acc, filename) {
      let filename_size = string.byte_size(filename)

      <<acc:bits, filename_size:little-size(16), filename:utf8>>
    })

  let trigrams_count = dict.size(index.trigrams)

  log.debug(
    "Serializing " <> int.to_string(dict.size(index.trigrams)) <> " trigrams",
  )
  let #(trigrams, _) =
    // Doesn't matter if we get the dict entries out of order.
    dict.fold(index.trigrams, #(<<>>, 0), fn(acc, trigram, file_indices) {
      let #(acc, i) = acc
      let file_indices_count = set.size(file_indices)

      case i % 1000 == 0 {
        True -> log.debug("Processed " <> int.to_string(i) <> " trigrams")
        False -> Nil
      }

      let file_indices =
        // Doesn't matter if we get the set entries out of order.
        set.fold(file_indices, <<>>, fn(acc, file_index) {
          <<acc:bits, file_index:little-size(32)>>
        })

      #(
        <<
          acc:bits,
          trigram:utf8,
          file_indices_count:little-size(32),
          file_indices:bits,
        >>,
        i + 1,
      )
    })

  log.debug("Returning from serialize")
  <<
    file_count:little-size(32),
    files:bits,
    trigrams_count:little-size(32),
    trigrams:bits,
  >>
}

// SEARCHING

pub type SearchResult {
  SearchResult(file: String, line_index: Int, line_with_context: String)
}

pub fn search_query(
  query: String,
  index: Index,
) -> Result(List(SearchResult), List(String)) {
  use query_trigrams <- result.try(
    query
    |> bit_array.from_string
    |> trigrams.unique_trigrams
    |> result.replace_error(["no unique trigrams"]),
  )

  let file_indices = get_putative_file_indices(index.trigrams, query_trigrams)

  case file_indices {
    // No search results
    Error(Nil) -> Error(["no search results"])

    // We had some search results
    Ok(file_indices) -> {
      let #(search_results, errors) =
        file_indices
        |> set.to_list
        |> list.sort(int.compare)
        |> list.fold([], fn(acc, file_index) {
          case read_file_from_index(index.files, file_index) {
            Error(e) -> [Error(e), ..acc]
            Ok(#(file, data)) -> {
              let lines = string.split(data, on: "\n")

              let line_indices = get_matching_line_indices(lines, query)

              let lines_with_context =
                line_indices
                |> list.map(get_line_and_context(lines, _))
                |> list.map(fn(x) {
                  let #(line_index, line_with_context) = x
                  SearchResult(file:, line_index:, line_with_context:)
                })

              [Ok(lines_with_context), ..acc]
            }
          }
        })
        |> result.partition

      case errors {
        [] -> Ok(list.flatten(search_results))

        errors -> Error(errors)
      }
    }
  }
}

fn get_putative_file_indices(index_trigrams, query_trigrams) {
  case set.to_list(query_trigrams) {
    [] -> panic as "should have seen at least one trigram"
    [trigram, ..rest] -> {
      list.try_fold(
        rest,
        get_file_indices(index_trigrams, trigram),
        fn(acc, trigram) {
          let acc =
            set.intersection(acc, get_file_indices(index_trigrams, trigram))

          case set.is_empty(acc) {
            True -> Error(Nil)
            False -> Ok(acc)
          }
        },
      )
    }
  }
}

fn get_file_indices(trigrams, trigram) {
  case dict.get(trigrams, trigram) {
    Ok(file_indices) -> file_indices
    Error(Nil) -> set.new()
  }
}

fn read_file_from_index(
  files: iv.Array(String),
  at_index: Int,
) -> Result(#(String, String), String) {
  use file <- result.try(
    iv.get(files, at_index)
    |> result.replace_error(
      "failed to get file at index "
      <> int.to_string(at_index)
      <> " which should be impossible",
    ),
  )
  use data <- result.try(
    simplifile.read(file) |> result.map_error(simplifile.describe_error),
  )
  Ok(#(file, data))
}

fn get_matching_line_indices(lines, query) {
  list.index_fold(lines, [], fn(acc, line, line_index) {
    case string.contains(does: line, contain: query) {
      True -> [line_index, ..acc]
      False -> acc
    }
  })
  |> list.reverse
}

fn get_line_and_context(lines: List(String), index: Int) -> #(Int, String) {
  let lines = iv.from_list(lines)

  let #(min, max) =
    get_range(index, min_line_index: 0, max_line_index: iv.size(lines) - 1)

  // If this is an Error, it's a logic bug. So assert is fine.
  let assert Ok(slice) = iv.slice(lines, start: min, size: max - min + 1)

  let hit_with_context = iv.to_list(slice) |> string.join("\n")

  #(index, hit_with_context)
}

fn get_range(
  index: Int,
  min_line_index min_line_index: Int,
  max_line_index max_line_index: Int,
) -> #(Int, Int) {
  let min = int.max(min_line_index, index - 3)
  let max = int.min(max_line_index, index + 8)
  #(min, max)
}
