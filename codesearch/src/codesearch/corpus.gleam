import codesearch/serde
import codesearch/tar
import codesearch/trigrams
import filepath
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import iv.{type Array}
import logging
import simplifile

// As an authenticated user, we can make 500 requests per minute per IP. That's
// 60,000 ms / 500 = 120 ms. So bump it a bit over that.
const http_request_wait_millis = 150

/// Skip any files bigger than this
///
const max_file_size_bytes: Int = 500_000

const prefix_line_count = 3

const suffix_line_count = 8

pub type TrigramIndex {
  TrigramIndex(index: Dict(String, Set(Int)))
}

fn trigram_index_to_json(trigram_index: TrigramIndex) -> json.Json {
  let TrigramIndex(index:) = trigram_index
  json.object([
    #("index", json.dict(index, fn(string) { string }, int_set_to_json)),
  ])
}

fn int_set_to_json(int_set: Set(Int)) -> json.Json {
  set.to_list(int_set) |> list.sort(int.compare) |> json.array(json.int)
}

pub type Corpus {
  Corpus(
    /// An array of source code files
    files: Array(String),
    /// A map from trigram to indices into the `files` field
    trigram_index: TrigramIndex,
    /// A list of PackageMetadata used for filtering the search.
    ///
    /// We don't index into this, so it's fine to be a list.
    package_metadata: List(PackageMetadata),
  )
}

pub fn corpus_to_json(corpus: Corpus) -> json.Json {
  let Corpus(files:, trigram_index:, package_metadata:) = corpus
  json.object([
    #("files", string_array_to_json(files)),
    #("trigram_index", trigram_index_to_json(trigram_index)),
    #(
      "package_metadata",
      json.array(package_metadata, package_metadata_to_json),
    ),
  ])
}

fn string_array_to_json(string_array: iv.Array(String)) -> json.Json {
  string_array |> iv.to_list |> json.array(json.string)
}

pub fn serialize_corpus(corpus: Corpus) -> BitArray {
  let files = serialize_files(corpus.files)
  let trigrams = serialize_trigram_index(corpus.trigram_index)
  let package_metadata =
    serde.serialize_list(corpus.package_metadata, serialize_package_metadata)

  <<files:bits, trigrams:bits, package_metadata:bits>>
}

// TODO: this function is only used in tests.
pub fn deserialize_corpus(data: BitArray) -> Result(Corpus, Error) {
  use parsed <- result.try(deserialize_files(data))
  let files = parsed.value
  // TODO: this value should be taken from a param
  use parsed <- result.try(deserialize_trigram_index(
    parsed.remaining,
    collect_garbage: False,
  ))
  let trigram_index = parsed.value
  use parsed <- result.try(
    serde.deserialize_list(parsed.remaining, deserialize_package_metadata)
    |> result.map_error(SerdeError),
  )
  let package_metadata = parsed.value

  Ok(Corpus(files:, trigram_index:, package_metadata:))
}

fn serialize_files(files: Array(String)) -> BitArray {
  serde.serialize_array(files, serde.serialize_string)
}

pub fn deserialize_files(
  data: BitArray,
) -> Result(serde.Parsed(Array(String)), Error) {
  serde.deserialize_array(data, serde.deserialize_string)
  |> result.map_error(SerdeError)
}

fn serialize_trigram_index(trigram_index: TrigramIndex) -> BitArray {
  // Doesn't matter if we get the dict entries out of order.
  let serialized_trigram_index =
    dict.fold(trigram_index.index, <<>>, fn(acc, trigram, file_indices) {
      let file_indices = serialize_int_set(file_indices)

      <<acc:bits, trigram:utf8, file_indices:bits>>
    })

  let trigrams_count = dict.size(trigram_index.index)

  <<trigrams_count:little-size(32), serialized_trigram_index:bits>>
}

pub fn deserialize_trigram_index(
  data: BitArray,
  collect_garbage collect_garbage: Bool,
) -> Result(serde.Parsed(TrigramIndex), Error) {
  case data {
    <<trigrams_count:little-size(32), data:bits>> -> {
      do_deserialize_trigram_index(
        data,
        trigrams_count,
        dict.new(),
        0,
        collect_garbage,
      )
      |> result.map_error(SerdeError)
    }

    _ ->
      Error(
        SerdeError(serde.DeserializeError(
          message: "expected count followed by trigram index",
        )),
      )
  }
}

@external(erlang, "erlang", "garbage_collect")
fn garbage_collect() -> Bool

fn do_deserialize_trigram_index(
  data: BitArray,
  trigrams_count: Int,
  acc: Dict(String, Set(Int)),
  i: Int,
  collect_garbage: Bool,
) -> Result(serde.Parsed(TrigramIndex), serde.Error) {
  case collect_garbage, i % 300 {
    True, 0 -> {
      // This keeps it under 2gb (like 1.5gb as of the packages fetch on
      // 2026-03-02)
      logging.log(
        logging.Debug,
        "Collecting garbage on trigram "
          <> int.to_string(i)
          <> " of "
          <> int.to_string(trigrams_count),
      )
      let _ = garbage_collect()
      Nil
    }
    _, _ -> Nil
  }

  case i < trigrams_count {
    True -> {
      case data {
        <<a:utf8_codepoint, b:utf8_codepoint, c:utf8_codepoint, data:bits>> -> {
          let trigram = string.from_utf_codepoints([a, b, c])
          case deserialize_int_set(data) {
            Ok(parsed) -> {
              let file_indices = parsed.value
              let acc = dict.insert(acc, trigram, file_indices)
              let data = parsed.remaining
              do_deserialize_trigram_index(
                data,
                trigrams_count,
                acc,
                i + 1,
                collect_garbage,
              )
            }
            Error(error) -> Error(error)
          }
        }
        _ ->
          Error(serde.DeserializeError(
            message: "expected trigram followed by file indices",
          ))
      }
    }
    False -> Ok(serde.Parsed(value: TrigramIndex(index: acc), remaining: data))
  }
}

fn serialize_int_set(int_set: Set(Int)) -> BitArray {
  serde.serialize_set(int_set, serde.serialize_int32)
}

fn deserialize_int_set(
  data: BitArray,
) -> Result(serde.Parsed(Set(Int)), serde.Error) {
  serde.deserialize_set(data, serde.deserialize_int32)
}

fn serialize_package_metadata(package_metadata: PackageMetadata) -> BitArray {
  let name = serde.serialize_string(package_metadata.name)
  let latest_version = serde.serialize_string(package_metadata.latest_version)
  let inserted_at = serde.serialize_timestamp(package_metadata.inserted_at)
  let updated_at = serde.serialize_timestamp(package_metadata.updated_at)
  let files = serialize_int_set(package_metadata.files)

  <<
    name:bits,
    latest_version:bits,
    inserted_at:bits,
    updated_at:bits,
    files:bits,
  >>
}

pub fn deserialize_package_metadata(
  data: BitArray,
) -> Result(serde.Parsed(PackageMetadata), serde.Error) {
  use parsed <- result.try(serde.deserialize_string(data))
  let name = parsed.value

  use parsed <- result.try(serde.deserialize_string(parsed.remaining))
  let latest_version = parsed.value

  use parsed <- result.try(serde.deserialize_timestamp(parsed.remaining))
  let inserted_at = parsed.value

  use parsed <- result.try(serde.deserialize_timestamp(parsed.remaining))
  let updated_at = parsed.value

  use parsed <- result.try(deserialize_int_set(parsed.remaining))
  let files = parsed.value

  let package_metadata =
    PackageMetadata(name, latest_version, inserted_at, updated_at, files)

  let parsed =
    serde.Parsed(value: package_metadata, remaining: parsed.remaining)

  Ok(parsed)
}

type CorpusBuilder {
  CorpusBuilder(
    files: List(List(String)),
    total_files: Int,
    trigram_index: TrigramIndex,
    package_metadata: List(PackageMetadata),
    errors: List(List(Error)),
  )
}

fn new_corpus_builder() {
  CorpusBuilder(
    files: [],
    total_files: 0,
    trigram_index: TrigramIndex(dict.new()),
    package_metadata: [],
    errors: [],
  )
}

fn build(corpus_builder: CorpusBuilder) -> Corpus {
  case list.flatten(corpus_builder.errors) {
    [] -> Nil
    errors ->
      list.each(errors, fn(error) {
        logging.log(logging.Error, string.inspect(error))
      })
  }

  Corpus(
    files: corpus_builder.files |> list.reverse |> list.flatten |> iv.from_list,
    trigram_index: corpus_builder.trigram_index,
    package_metadata: corpus_builder.package_metadata |> list.reverse,
  )
}

pub type PackageMetadata {
  PackageMetadata(
    name: String,
    latest_version: String,
    inserted_at: Timestamp,
    updated_at: Timestamp,
    /// Indices into the `files` field of the corpus
    files: Set(Int),
  )
}

fn package_metadata_to_json(package_metadata: PackageMetadata) -> json.Json {
  let PackageMetadata(name:, latest_version:, inserted_at:, updated_at:, files:) =
    package_metadata
  json.object([
    #("name", json.string(name)),
    #("latest_version", json.string(latest_version)),
    #("inserted_at", timestamp_to_json(inserted_at)),
    #("updated_at", timestamp_to_json(updated_at)),
    #("files", int_set_to_json(files)),
  ])
}

fn timestamp_to_json(timestamp: timestamp.Timestamp) -> json.Json {
  let #(seconds, nanoseconds) =
    timestamp.to_unix_seconds_and_nanoseconds(timestamp)
  json.array([seconds, nanoseconds], json.int)
}

fn package_metadata_from_hex_package(
  hex_package: HexPackage,
  files: Set(Int),
) -> PackageMetadata {
  PackageMetadata(
    name: hex_package.name,
    latest_version: hex_package.latest_version,
    inserted_at: hex_package.inserted_at,
    updated_at: hex_package.updated_at,
    files:,
  )
}

// TODO: convert all FileError into FileError2
pub type Error {
  BadCliArgsError
  FailedToBuildRequestError
  FileError(error: simplifile.FileError)
  FileError2(error: simplifile.FileError, while_processing: String)
  FileErrors(errors: List(simplifile.FileError))
  FileHadNoTrigramsError(path: String)
  HttpcError(error: httpc.HttpError)
  InvalidFileIndexError(at_index: Int)
  JsonDecodeError(error: json.DecodeError)
  MissingEnvVariableError(name: String)
  NotAFileError(path: String)
  SerdeError(error: serde.Error)
  TarError(error: tar.Error)
  UnexpectedHttpResponseStatusCodeError(expected: Int, received: Int)
}

pub fn make_corpus(
  hex_api_key hex_api_key: String,
  outdir outdir: String,
  test_corpus test_corpus: Bool,
) -> Result(Nil, Error) {
  // Script setup
  logging.log(logging.Info, "setting up")

  // TODO: check if outdir exists and if it does, fail
  use Nil <- result.try(create_directory_all(outdir))
  let data_outdir = filepath.join(outdir, "data")
  use Nil <- result.try(create_directory_all(data_outdir))

  // Download package info from hex
  logging.log(logging.Info, "fetching packages")
  use stdlib_package <- result.try(fetch_stdlib(hex_api_key))
  use stdlib_dependent_packages <- result.try(fetch_packages(hex_api_key))
  let all_packages = [stdlib_package, ..stdlib_dependent_packages]

  logging.log(
    logging.Info,
    "fetching "
      <> int.to_string(list.length(all_packages))
      <> " package source files",
  )

  logging.log(logging.Info, "creating corpus")
  // use corpus <- result.try(process_hex_packages(all_packages, data_outdir))

  let all_packages = case test_corpus {
    True -> list.take(all_packages, 10)
    False -> all_packages
  }

  let corpus = index_hex_packages(all_packages, data_outdir)

  logging.log(logging.Info, "writing index")

  let corpus_outfile = filepath.join(outdir, "gleam_packages.index")

  simplifile.write_bits(to: corpus_outfile, bits: serialize_corpus(corpus))
  |> result.map_error(FileError)
}

// FETCHING FROM HEX ---------------------------------------------------------

/// Represents a package fetched from hex.pm
pub type HexPackage {
  HexPackage(
    name: String,
    inserted_at: Timestamp,
    updated_at: Timestamp,
    latest_version: String,
  )
}

fn package_full_name(hex_package: HexPackage) -> String {
  hex_package.name <> "-" <> hex_package.latest_version
}

fn hex_package_source_directory_name(
  hex_package: HexPackage,
  parent_directory: String,
) -> String {
  let full_name = package_full_name(hex_package)
  filepath.join(parent_directory, full_name)
}

fn package_tar_name(hex_package: HexPackage) -> String {
  package_full_name(hex_package) <> ".tar"
}

fn hex_package_tarball_request(
  hex_package: HexPackage,
) -> request.Request(BitArray) {
  let package_tar = package_tar_name(hex_package)
  let path = "/tarballs/" <> package_tar

  request.Request(
    method: http.Get,
    headers: [],
    body: <<>>,
    scheme: http.Https,
    host: "repo.hex.pm",
    port: None,
    path:,
    query: None,
  )
}

/// Use this to decode packages from the JSON file fetched from hex.pm.
fn hex_package_decoder() -> decode.Decoder(HexPackage) {
  use name <- decode.field("name", decode.string)
  use inserted_at <- decode.field("inserted_at", timestamp_decoder())
  use updated_at <- decode.field("updated_at", timestamp_decoder())
  use latest_version <- decode.field("latest_version", decode.string)
  decode.success(HexPackage(name:, updated_at:, inserted_at:, latest_version:))
}

fn timestamp_decoder() {
  use string <- decode.then(decode.string)
  case timestamp.parse_rfc3339(string) {
    Ok(timestamp) -> decode.success(timestamp)
    Error(Nil) -> decode.failure(timestamp.unix_epoch, expected: "Timestamp")
  }
}

fn fetch_stdlib(hex_api_key: String) -> Result(HexPackage, Error) {
  process.sleep(http_request_wait_millis)
  logging.log(logging.Info, "fetching stdlib")

  use request <- result.try(
    request.to("https://hex.pm/api/packages/gleam_stdlib")
    |> result.replace_error(FailedToBuildRequestError),
  )

  let request =
    request
    |> request.prepend_header("accept", "application/json")
    |> request.prepend_header("authorization", hex_api_key)

  use body <- result.try(http_send(request))

  json.parse(body, hex_package_decoder()) |> result.map_error(JsonDecodeError)
}

fn fetch_packages(hex_api_key: String) {
  do_fetch_packages(hex_api_key, 1, [])
}

fn do_fetch_packages(
  hex_api_key: String,
  page: Int,
  packages: List(List(HexPackage)),
) -> Result(List(HexPackage), Error) {
  process.sleep(http_request_wait_millis)
  logging.log(logging.Info, "fetching page " <> int.to_string(page))

  use request <- result.try(
    request.to("https://hex.pm/api/packages")
    |> result.replace_error(FailedToBuildRequestError),
  )

  let request =
    request
    |> request.set_query([
      #("search", "depends:hexpm:gleam_stdlib"),
      #("sort", "recent_downloads"),
      // NOTE: you will know that you have hit the last page when you get an
      // empty json array back (`[]`)
      #("page", int.to_string(page)),
    ])
    |> request.prepend_header("accept", "application/json")
    |> request.prepend_header("authorization", hex_api_key)

  use body <- result.try(http_send(request))
  let body_parse_result = json.parse(body, decode.list(hex_package_decoder()))

  case body_parse_result {
    // An empty list here means done.
    Ok([]) -> packages |> list.reverse |> list.flatten |> Ok
    Ok(new_packages) ->
      do_fetch_packages(hex_api_key, page + 1, [new_packages, ..packages])
    Error(error) -> {
      logging.log(
        logging.Error,
        "hex json body decode error: " <> string.inspect(error),
      )
      Error(JsonDecodeError(error))
    }
  }
}

fn fetch_package_tarball(hex_package: HexPackage) {
  process.sleep(http_request_wait_millis)
  let request = hex_package_tarball_request(hex_package)

  let timeout_millis = 90 * 1000
  let config = httpc.configure() |> httpc.timeout(timeout_millis)

  use response <- result.try(
    httpc.dispatch_bits(config, request) |> result.map_error(HttpcError),
  )
  case response.status {
    200 -> Ok(response.body)
    code ->
      Error(UnexpectedHttpResponseStatusCodeError(expected: 200, received: code))
  }
}

/// Extract the source files from the given tarball into the given outdir.
///
/// Also, removes any unnecessary stuff from the output.
@internal
pub fn extract_source_files(
  tarball: BitArray,
  outdir: String,
) -> Result(List(String), Error) {
  let src_directory = filepath.join(outdir, "src")
  let include_directory = filepath.join(outdir, "include")
  let contents_tarball = outdir <> "/contents.tar.gz"

  use Nil <- result.try(create_directory_all(outdir))

  use tarball <- result.try(
    tar.binary_from_bit_array(tarball) |> result.map_error(TarError),
  )

  use Nil <- result.try(
    tar.extract_binary(tarball, cwd: outdir, compressed: False)
    |> result.map_error(TarError),
  )

  use contents_tarball <- result.try(accept_file(contents_tarball))

  use Nil <- result.try(
    tar.extract_file(contents_tarball, cwd: outdir, compressed: True)
    |> result.map_error(TarError),
  )

  use out_files <- result.try(
    simplifile.get_files(outdir) |> result.map_error(FileError),
  )

  let #(src_files, non_src_files) =
    list.partition(out_files, fn(path) {
      string.starts_with(path, src_directory)
    })

  use Nil <- result.try(
    simplifile.delete_all(non_src_files) |> result.map_error(FileError),
  )
  use Nil <- result.try(
    simplifile.delete_all([include_directory]) |> result.map_error(FileError),
  )

  use Nil <- result.try(
    simplifile.set_permissions_octal(outdir, 0o755)
    |> result.map_error(FileError),
  )

  // Set the permissions in the resulting directory. They are a little wonky
  // coming straight from hex, so we need to fix them up.
  use files <- result.try(
    simplifile.get_files(outdir) |> result.map_error(FileError),
  )
  let #(_, errors) =
    list.map(files, fn(file) {
      case simplifile.is_file(file), simplifile.is_directory(file) {
        Ok(True), Ok(False) -> [simplifile.set_permissions_octal(file, 0o644)]
        Ok(False), Ok(True) -> [simplifile.set_permissions_octal(file, 0o755)]
        // Not a file or a directory, skip
        Ok(False), Ok(False) -> [Ok(Nil)]
        Ok(True), Ok(True) -> panic as "both a file and a directory?"
        Error(e1), Error(e2) -> [Error(e1), Error(e2)]
        Error(e), Ok(_) | Ok(_), Error(e) -> [Error(e)]
      }
    })
    |> list.flatten
    |> result.partition

  case errors {
    [] -> Ok(list.sort(src_files, string.compare))
    errors -> Error(FileErrors(errors))
  }
}

/// This can never fail. The caller will need to check if the corpus is "empty"
/// or if there are some files in it.
fn index_hex_packages(hex_packages: List(HexPackage), outdir: String) -> Corpus {
  let corpus_builder = new_corpus_builder()

  let corpus_builder =
    list.index_fold(
      hex_packages,
      corpus_builder,
      fn(corpus_builder, hex_package, i) {
        logging.log(
          logging.Debug,
          "indexing package " <> int.to_string(i) <> " " <> hex_package.name,
        )
        index_hex_package(hex_package, outdir, corpus_builder)
      },
    )

  build(corpus_builder)
}

/// You should log the errors.
///
/// The trigram_index may be returned to you unchanged if every operation
/// generated an error.
///
fn index_hex_package(
  hex_package: HexPackage,
  outdir: String,
  corpus_builder: CorpusBuilder,
) -> CorpusBuilder {
  // TODO: we skip searching super large files, but we still index them.
  case fetch_package_source2(hex_package, outdir) {
    Ok(source_files) -> {
      let updated_file_count =
        corpus_builder.total_files + list.length(source_files)

      let #(trigram_index, errors, file_indices) =
        index_source_files(
          source_files,
          corpus_builder.total_files,
          corpus_builder.trigram_index.index,
        )

      CorpusBuilder(
        files: [source_files, ..corpus_builder.files],
        total_files: updated_file_count,
        trigram_index: TrigramIndex(trigram_index),
        package_metadata: [
          package_metadata_from_hex_package(hex_package, file_indices),
          ..corpus_builder.package_metadata
        ],
        errors: [errors, ..corpus_builder.errors],
      )
    }
    Error(error) ->
      CorpusBuilder(..corpus_builder, errors: [[error], ..corpus_builder.errors])
  }
}

@internal
pub fn index_source_files(
  source_files: List(String),
  current_file_count: Int,
  trigram_index: Dict(String, Set(Int)),
) -> #(Dict(String, Set(Int)), List(Error), Set(Int)) {
  let #(trigram_index, errors, file_indices) =
    list.index_fold(
      source_files,
      #(trigram_index, [], []),
      fn(acc, source_file, source_file_index) {
        let #(trigram_index, errors, file_indices) = acc
        let source_file_index = current_file_count + source_file_index

        // TODO: If there is an error, should we bother traking this index?
        let file_indices = [source_file_index, ..file_indices]

        case simplifile.read_bits(source_file) {
          Error(error) -> {
            #(
              trigram_index,
              [FileError2(error, while_processing: source_file), ..errors],
              file_indices,
            )
          }
          Ok(file_data) -> {
            let trigram_index =
              index_file_data(file_data, source_file_index, trigram_index)

            #(trigram_index, errors, file_indices)
          }
        }
      },
    )

  #(trigram_index, errors, set.from_list(file_indices))
}

fn index_file_data(file_data, source_file_index, trigram_index) {
  let trigrams = trigrams.unique_trigrams(file_data)
  update_trigram_index(trigram_index, trigrams, source_file_index)
}

fn update_trigram_index(
  trigram_index: Dict(String, Set(Int)),
  file_unique_trigrams: Set(String),
  file_index: Int,
) -> Dict(String, Set(Int)) {
  set.fold(
    over: file_unique_trigrams,
    from: trigram_index,
    with: fn(trigram_index, trigram) {
      dict.upsert(trigram_index, update: trigram, with: fn(maybe_file_indices) {
        case maybe_file_indices {
          Some(file_indices) -> set.insert(file_indices, file_index)
          None -> set.from_list([file_index])
        }
      })
    },
  )
}

/// Fetch the package source code, extract it, return the paths to the good
/// files.
///
fn fetch_package_source2(
  hex_package: HexPackage,
  outdir: String,
) -> Result(List(String), Error) {
  use tarball <- result.try(fetch_package_tarball(hex_package))
  let source_directory = hex_package_source_directory_name(hex_package, outdir)
  use source_files <- result.try(extract_source_files(tarball, source_directory))
  Ok(source_files)
}

// SEARCHING -----------------------------------------------------------------

/// A line from some source file
pub type Line {
  Line(
    /// Zero-based index in the file whence the line originated
    index: Int,
    /// The line itself
    line: String,
  )
}

pub type SearchResult {
  SearchResult(
    file: String,
    matching_line: Line,
    prefix_lines: List(Line),
    suffix_lines: List(Line),
  )
}

pub fn search_result_line_numbers(search_result: SearchResult) -> List(Int) {
  [
    search_result.prefix_lines,
    [search_result.matching_line],
    search_result.suffix_lines,
  ]
  |> list.flatten
  |> list.map(fn(line) { line.index + 1 })
}

pub fn filter_corpus(
  corpus: Corpus,
  predicates: List(fn(PackageMetadata) -> Bool),
) -> Set(Int) {
  // Empty predicates list will always return true
  let check_predicates = fn(package_metadata) {
    list.all(predicates, fn(predicate) { predicate(package_metadata) })
  }

  corpus.package_metadata
  |> list.fold(set.new(), fn(file_indices, package_metadata) {
    case check_predicates(package_metadata) {
      True -> set.union(file_indices, package_metadata.files)
      False -> file_indices
    }
  })
}

pub fn search_query(
  query: String,
  corpus: Corpus,
  index_directory_parent: String,
  predicates: List(fn(PackageMetadata) -> Bool),
  log_debug: fn(String) -> Nil,
) -> Result(List(SearchResult), List(Error)) {
  log_debug("searching query: " <> query)
  let query_trigrams =
    query |> bit_array.from_string |> trigrams.unique_trigrams

  // NOTE: Both of these are fast, so you shouldn't have to worry about
  // restricting the amount searched for either. The slower part is the exact
  // matching.
  let file_indices =
    set.intersection(
      get_putative_file_indices(corpus.trigram_index, query_trigrams),
      filter_corpus(corpus, predicates),
    )

  case set.size(file_indices) {
    0 -> {
      log_debug("no matching file indices")
      Ok([])
    }
    _ -> {
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
            use file <- result.try(pull_file(corpus.files, file_index))
            let file_with_directory =
              filepath.join(index_directory_parent, file)
            use file_info <- result.try(
              simplifile.file_info(file_with_directory)
              |> result.map_error(fn(error) {
                FileError2(error:, while_processing: file_with_directory)
              }),
            )

            case file_info.size > max_file_size_bytes {
              True -> {
                // If file is too big, don't treat it as an error, simply return
                // the acc and move on to the next one.
                log_debug("the file was too big: " <> file)
                Ok(acc)
              }
              False -> {
                use file_data <- result.try(
                  simplifile.read(file_with_directory)
                  |> result.map_error(fn(error) {
                    FileError2(error:, while_processing: file_with_directory)
                  }),
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

/// If there are no matching files then the resulting set will be empty.
fn get_putative_file_indices(
  index_trigrams: TrigramIndex,
  query_trigrams: Set(String),
) -> Set(Int) {
  case set.to_list(query_trigrams) {
    [] -> set.new()
    [trigram, ..rest] -> {
      let result =
        list.try_fold(
          rest,
          get_file_indices(index_trigrams.index, trigram),
          fn(acc, trigram) {
            let acc =
              set.intersection(
                acc,
                get_file_indices(index_trigrams.index, trigram),
              )

            case set.is_empty(acc) {
              True -> Error(Nil)
              False -> Ok(acc)
            }
          },
        )

      case result {
        Ok(file_indices) -> file_indices
        Error(Nil) -> set.new()
      }
    }
  }
}

fn get_file_indices(trigrams, trigram) {
  case dict.get(trigrams, trigram) {
    Ok(file_indices) -> file_indices
    Error(Nil) -> set.new()
  }
}

fn pull_file(files: Array(String), at_index: Int) -> Result(String, Error) {
  iv.get(files, at_index)
  |> result.replace_error(InvalidFileIndexError(at_index:))
}

type PendingSearchResult {
  PendingSearchResult(
    file: String,
    matching_line: Line,
    prefix_reversed: List(Line),
    suffix_reversed: List(Line),
    need: Int,
  )
}

fn push_suffix_line(
  pending: PendingSearchResult,
  line: Line,
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
  SearchResult(
    file: pending.file,
    matching_line: pending.matching_line,
    prefix_lines: list.reverse(pending.prefix_reversed),
    suffix_lines: list.reverse(pending.suffix_reversed),
  )
}

// This is kinda tricky, but basically, we need to go over the lines just once,
// but still keep the context. Converting to an iv.Array and getting context
// that way is too slow for the larger files.
fn get_matches(
  file: String,
  lines: List(String),
  query: String,
) -> List(SearchResult) {
  let #(completed_reversed, still_pending_reversed, _prefix_reversed) =
    list.index_fold(lines, #([], [], []), fn(acc, line, line_index) {
      let #(completed_reversed, still_pending_reversed, prefix_reversed) = acc

      let line = Line(index: line_index, line:)

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
      let still_pending = case
        string.contains(does: line.line, contain: query)
      {
        True -> {
          let new_pending =
            PendingSearchResult(
              file:,
              matching_line: line,
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

// UTILS ---------------------------------------------------------------------

fn accept_file(path: String) -> Result(String, Error) {
  case simplifile.is_file(path) {
    Ok(True) -> Ok(path)
    Ok(False) -> Error(NotAFileError(path))
    Error(e) -> Error(FileError(e))
  }
}

fn create_directory_all(path: String) -> Result(Nil, Error) {
  simplifile.create_directory_all(path) |> result.map_error(FileError)
}

fn http_send(request: request.Request(String)) -> Result(String, Error) {
  use response <- result.try(
    httpc.send(request) |> result.map_error(HttpcError),
  )
  case response.status {
    200 -> Ok(response.body)
    code ->
      Error(UnexpectedHttpResponseStatusCodeError(expected: 200, received: code))
  }
}
