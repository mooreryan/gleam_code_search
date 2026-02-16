import argv
import codesearch/index
import codesearch/index_corpus
import envoy
import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/set
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import iv
import simplifile

fn log(msg: String) -> Nil {
  let now =
    timestamp.system_time() |> timestamp.to_rfc3339(calendar.local_offset())

  let msg = now <> " " <> msg

  io.println_error(msg)
}

pub fn main() -> Nil {
  let index_path = case envoy.get("GLEAM_CODESEARCH_INDEX") {
    Ok(index_path) -> index_path
    Error(Nil) ->
      "/Users/ryan/Projects/gleam/gleam_code_search/_index/magic_index.json"
  }

  log("Reading index")
  let assert Ok(index) = simplifile.read(index_path)

  log("Parsing index")
  let assert Ok(index) = json.parse(index, index.decoder())

  let query = case argv.load().arguments {
    [] -> panic as "pass a query"
    args -> string.join(args, " ")
  }

  case string.length(query) < 3 {
    True -> panic as "query must be at least 3 characters"
    False -> Nil
  }

  log("Parsing query")
  let query_trigrams = case
    index_corpus.unique_trigrams(bit_array.from_string(query))
  {
    Ok(x) -> x
    Error(Nil) -> panic as "query was to short to generate a single trigram"
  }

  log("Searching index")
  let file_indices = get_putative_file_indices(index.trigrams, query_trigrams)

  log("Searching hits")
  case file_indices {
    Ok(file_indices) -> {
      file_indices
      |> set.each(fn(file_index) {
        let assert Ok(file) = iv.get(index.files, file_index)
        let assert Ok(data) = simplifile.read(file)
        let lines = string.split(data, on: "\n")

        let line_indices = get_matching_line_indices(lines, query)

        let lines_with_context =
          line_indices |> list.map(get_line_and_context(lines, _))

        let _ =
          lines_with_context
          |> list.each(fn(x) {
            let #(line_index, line_and_context) = x

            let msg =
              "\n==== "
              <> "\n==== "
              <> "\n==== "
              <> "\n"
              <> file
              <> ":"
              <> int.to_string(line_index + 1)
              <> "\n\n"
              <> line_and_context
            io.println(msg)
          })
      })
    }

    Error(Nil) -> {
      echo "no possible file matches"
      Nil
    }
  }

  log("Done")

  Nil
}

// TODO: use this in the cli too...
pub fn read_index(index_path) {
  use index_json <- result.try(
    simplifile.read(index_path) |> result.map_error(simplifile.describe_error),
  )
  // TODO: better show function for decode errors
  json.parse(index_json, index.decoder()) |> result.map_error(string.inspect)
}

pub type SearchResult {
  SearchResult(file: String, line_index: Int, line_with_context: String)
}

// TODO: use this in the CLI too...
// TODO: move this into a different module, as its also used in the server
pub fn search_query(
  query: String,
  index: index.Index,
) -> Result(List(SearchResult), List(String)) {
  use query_trigrams <- result.try(
    query
    |> bit_array.from_string
    |> index_corpus.unique_trigrams
    |> result.replace_error(["no unique trigrams"]),
  )

  log("Searching index")
  let file_indices = get_putative_file_indices(index.trigrams, query_trigrams)

  log("Searching hits")
  case file_indices {
    // No search results
    Error(Nil) -> Error(["no search results"])

    // We had some search results
    Ok(file_indices) -> {
      let #(search_results, errors) =
        set.fold(file_indices, [], fn(acc, file_index) {
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

fn get_file_indices(trigrams, trigram) {
  case dict.get(trigrams, trigram) {
    Ok(file_indices) -> file_indices
    Error(Nil) -> set.new()
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
