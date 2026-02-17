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

/// Skip any files bigger than this
///
const max_file_size_bytes: Int = 500_000

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
  log_debug: fn(String) -> Nil,
  log_notice: fn(String) -> Nil,
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
      log_debug(
        "starting search on "
        <> int.to_string(set.size(file_indices))
        <> " files",
      )

      let #(search_results, errors) =
        file_indices
        |> set.to_list
        |> list.sort(int.compare)
        |> list.fold([], fn(acc, file_index) {
          let result = {
            use file <- result.try(pull_file(index.files, file_index))
            use file_info <- result.try(
              simplifile.file_info(file)
              |> result.map_error(simplifile.describe_error),
            )

            case file_info.size > max_file_size_bytes {
              True -> {
                log_notice(
                  "file too big ("
                  <> int.to_string(file_info.size)
                  <> " bytes): "
                  <> file,
                )

                // If file is too big, don't treat it as an error, simply return
                // the acc and move on to the next one.
                Ok(acc)
              }
              False -> {
                use file_data <- result.try(
                  simplifile.read(file)
                  |> result.map_error(simplifile.describe_error),
                )
                let lines = string.split(file_data, on: "\n")
                let search_results = get_matches(file, lines, query)
                // Wrapped in okay, because we're guarding against file
                // operation errors.
                Ok([Ok(search_results), ..acc])
              }
            }
          }

          case result {
            // Something went wrong in one of the file operations
            Error(msg) -> [Error(msg), ..acc]

            // The file operations were okay
            Ok(acc) -> acc
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

fn pull_file(files: Array(String), at_index: Int) -> Result(String, String) {
  iv.get(files, at_index)
  |> result.replace_error(
    "failed to get file at index "
    <> int.to_string(at_index)
    <> " which should be impossible",
  )
}

type PendingSearchResult {
  PendingSearchResult(
    file: String,
    line_index: Int,
    line: String,
    prefix_reversed: List(String),
    suffix_reversed: List(String),
    need: Int,
  )
}

fn push_suffix_line(
  pending: PendingSearchResult,
  line: String,
) -> PendingSearchResult {
  case pending.need {
    0 -> pending
    _ ->
      PendingSearchResult(..pending, need: pending.need - 1, suffix_reversed: [
        line,
        ..pending.suffix_reversed
      ])
  }
}

fn is_done(pending: PendingSearchResult) -> Bool {
  pending.need == 0
}

fn finalize(pending: PendingSearchResult) -> SearchResult {
  let prefix = list.reverse(pending.prefix_reversed)
  let suffix = list.reverse(pending.suffix_reversed)

  let line_with_context =
    [prefix, [pending.line], suffix] |> list.flatten |> string.join("\n")

  SearchResult(
    file: pending.file,
    line_index: pending.line_index,
    line_with_context:,
  )
}

// TODO: sometimes the reading of the very big file is still slow.

// This is kinda tricky, but basically, we need to go over the lines just once,
// but still keep the context. Converting to an iv.Array and getting context
// that way is too slow for the larger files.
fn get_matches(
  file: String,
  lines: List(String),
  query: String,
) -> List(SearchResult) {
  let prefix_line_count = 3
  let suffix_line_count = 8

  let #(completed_reversed, still_pending_reversed, _prefix_reversed) =
    list.index_fold(lines, #([], [], []), fn(acc, line, line_index) {
      let #(completed_reversed, still_pending_reversed, prefix_reversed) = acc

      // We need to add this line to any pending items
      let still_pending =
        list.map(still_pending_reversed, push_suffix_line(_, line))

      // Some of the pending ones may now be completed, so we need to handle
      // them.
      let #(ready_to_complete, still_pending) =
        list.partition(still_pending, is_done)

      let completed_reversed =
        list.fold(ready_to_complete, completed_reversed, fn(completed, pending) {
          [finalize(pending), ..completed]
        })

      // Check if the current line matches, if yes we need a new pending match
      let still_pending = case string.contains(does: line, contain: query) {
        True -> {
          let new_pending =
            PendingSearchResult(
              file:,
              line_index:,
              line:,
              prefix_reversed:,
              suffix_reversed: [],
              need: suffix_line_count,
            )
          [new_pending, ..still_pending]
        }

        // There is no match, so we don't change the still_pending list
        False -> still_pending
      }

      // Now, update the prefix
      let prefix_reversed = [line, ..prefix_reversed]
      let prefix_reversed = list.take(prefix_reversed, prefix_line_count)

      #(completed_reversed, still_pending, prefix_reversed)
    })

  // Now that we're here, there may still be some pending items that haven't
  // yet been finalized because we hit the end of the file. So finalize those
  // now.
  let completed_reversed =
    list.fold(
      still_pending_reversed,
      completed_reversed,
      fn(completed_reversed, pending) {
        [finalize(pending), ..completed_reversed]
      },
    )

  list.reverse(completed_reversed)
}
