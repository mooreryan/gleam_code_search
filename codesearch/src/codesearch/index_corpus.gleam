import argv
import codesearch/index.{type Index, Index}
import codesearch/log
import codesearch/trigrams
import filepath
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import iv
import simplifile

type Config {
  Config(corpus_directory: String, outfile: String)
}

pub fn main() {
  log.configure()

  use config <- result.try(config())

  log.info("Getting files to index")
  let #(corpus_files, errors) =
    get_files(config.corpus_directory) |> result.partition

  log_file_errors(errors)

  log.debug(
    "Total files to index: " <> int.to_string(list.length(corpus_files)),
  )

  use index <- result.try(process_corpus_files(corpus_files))

  log.info("Writing index json")
  use Nil <- result.try(
    write_index_binary(index, config.outfile)
    |> result.map_error(simplifile.describe_error),
  )

  log.info("Done")

  Ok(Nil)
}

fn config() -> Result(Config, String) {
  case argv.load().arguments {
    [corpus_directory, outfile] -> {
      use corpus_directory <- result.try(accept_directory(corpus_directory))
      Ok(Config(corpus_directory:, outfile:))
    }
    _ -> Error("pass the corpus dir and the outfile")
  }
}

fn accept_directory(directory: String) -> Result(String, String) {
  case simplifile.is_directory(directory) {
    Ok(True) -> Ok(directory)
    Ok(False) -> Error(directory <> "is not a directory")
    Error(e) -> Error(simplifile.describe_error(e))
  }
}

/// This is a special version of the simplifile function that doesn't stop on
/// the first error.
///
fn get_files(
  in directory: String,
) -> List(Result(String, #(String, simplifile.FileError))) {
  case simplifile.read_directory(directory) {
    Error(e) -> [Error(#(directory, e))]

    Ok(contents) -> {
      list.fold(over: contents, from: [], with: fn(acc, content) {
        let path = filepath.join(directory, content)

        case simplifile.file_info(path) {
          Error(e) -> [Error(#(path, e)), ..acc]
          Ok(info) -> {
            case simplifile.file_info_type(info) {
              simplifile.File -> {
                [Ok(path), ..acc]
              }
              simplifile.Directory -> {
                list.append(acc, get_files(path))
              }
              simplifile.Symlink -> acc
              simplifile.Other -> acc
            }
          }
        }
      })
    }
  }
}

fn log_file_errors(errors: List(#(String, simplifile.FileError))) -> Nil {
  case errors {
    [] -> Nil
    errors -> {
      log.error("Errors occurred while getting some files to index")
      use #(filename, file_error) <- list.each(errors)
      let msg =
        "Error getting file "
        <> filename
        <> ": "
        <> simplifile.describe_error(file_error)

      log.error(msg)
    }
  }
}

fn process_corpus_files(corpus_files: List(String)) -> Result(Index, String) {
  log.info("Filtering files")
  let corpus_files =
    corpus_files
    |> list.sort(string.compare)
    |> filter_corpus_files

  log.debug("Indexing files")

  let index = Index(files: iv.from_list(corpus_files), trigrams: dict.new())

  let index = list.index_fold(over: corpus_files, from: index, with: index_file)

  case dict.size(index.trigrams) {
    0 -> Error("no trigrams found ... must have been too many file errors?")
    _ -> Ok(index)
  }
}

fn write_index_binary(
  index: Index,
  outfile: String,
) -> Result(Nil, simplifile.FileError) {
  index
  |> index.serialize
  |> simplifile.write_bits(to: outfile, bits: _)
}

// TODO: need to get the gleam.toml and then look for things in those dirs right on <blah>/src
fn filter_corpus_files(corpus_files) {
  use file <- list.filter(corpus_files)

  // Avoid stuff like this: ./aws_api-0.1.1/src/aws_api@translate.erl
  !string.contains(does: file, contain: "@")
  && !string.contains(does: file, contain: "/build")
  && string.contains(does: file, contain: "/src")
  && {
    string.ends_with(file, ".gleam")
    || string.ends_with(file, ".erl")
    || string.ends_with(file, ".mjs")
    || string.ends_with(file, ".cjs")
    || string.ends_with(file, ".jsx")
    || string.ends_with(file, ".js")
    || string.ends_with(file, ".tsx")
    || string.ends_with(file, ".ts")
  }
}

fn debug(x: a, msg: String) {
  let now =
    timestamp.system_time()
    |> timestamp.to_rfc3339(calendar.local_offset())

  let msg = now <> " " <> msg

  log.debug(msg)

  x
}

// Note: building the index with a List(Int) rather than Set(Int) is a bit
// faster, but uses a lot more memory, since you have to store more copies of
// each file_index.  So, keep it a set ;)
fn index_file(index: index.Index, file: String, file_index: Int) {
  log.debug("Indexing file " <> int.to_string(file_index + 1) <> ": " <> file)

  case simplifile.read_bits(file) {
    Error(e) -> {
      log.error(
        "Error reading file: " <> file <> ": " <> simplifile.describe_error(e),
      )
      index
    }

    Ok(data) -> {
      debug(Nil, "Get unique trigrams")
      let trigrams = trigrams.unique_trigrams(data)

      case trigrams {
        // We found no trigrams, return index unchanged
        Error(Nil) -> index

        Ok(trigrams) -> {
          debug(Nil, "Update index")
          // Update the index one time per unique trigram, as opposed to doing
          // it for each trigram. Saves a bit of time/memory.
          let index =
            Index(
              ..index,
              trigrams: set.fold(
                over: trigrams,
                from: index.trigrams,
                with: fn(acc, trigram) {
                  dict.upsert(
                    acc,
                    update: trigram,
                    with: fn(maybe_file_indices) {
                      case maybe_file_indices {
                        Some(file_indices) ->
                          set.insert(file_indices, file_index)
                        None -> set.from_list([file_index])
                      }
                    },
                  )
                },
              ),
            )

          // This does keep the memory down, but it makes it significantly
          // slower... D:
          // debug(Nil, "Collect garbage")
          // garbage_collect()

          debug(Nil, "Done")

          index
        }
      }
    }
  }
}
