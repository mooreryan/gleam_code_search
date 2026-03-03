import codesearch/corpus
import codesearch/serde_test
import filepath
import gleam/dict
import gleam/int
import gleam/list
import gleam/set
import gleam/string
import gleam/time/timestamp
import iv
import qcheck
import simplifile
import temporary

// EXTRACTING HEX PACKAGES ---------------------------------------------------
//
//

pub fn extract_source_files__qcheck__test() {
  let assert Ok(tarball) =
    simplifile.read_bits("test/codesearch/data/qcheck-1.0.4.tar")

  use directory <- temporary.create(temporary.directory())

  let assert Ok(files) = corpus.extract_source_files(tarball, directory)

  let expected =
    [
      "/src/qcheck.app.src",
      "/src/qcheck.erl",
      "/src/qcheck.gleam",
      "/src/qcheck/internal/gleam_panic.gleam",
      "/src/qcheck/internal/gleeunit_gleam_panic_ffi.erl",
      "/src/qcheck/internal/gleeunit_gleam_panic_ffi.mjs",
      "/src/qcheck/internal/read_file_ffi.mjs",
      "/src/qcheck/internal/reporting.gleam",
      "/src/qcheck/random.gleam",
      "/src/qcheck/shrink.gleam",
      "/src/qcheck/test_error_message.gleam",
      "/src/qcheck/tree.gleam",
      "/src/qcheck@internal@gleam_panic.erl",
      "/src/qcheck@internal@reporting.erl",
      "/src/qcheck@random.erl",
      "/src/qcheck@shrink.erl",
      "/src/qcheck@test_error_message.erl",
      "/src/qcheck@tree.erl",
      "/src/qcheck_ffi.erl",
      "/src/qcheck_ffi.mjs",
    ]
    |> list.map(fn(path) { filepath.join(directory, path) })
    |> list.sort(string.compare)

  assert files == expected
}

pub fn extract_source_files__xmlm__test() {
  let assert Ok(tarball) =
    simplifile.read_bits("test/codesearch/data/xmlm-1.0.1.tar")

  use directory <- temporary.create(temporary.directory())

  let assert Ok(files) = corpus.extract_source_files(tarball, directory)

  let expected =
    [
      "src/xmlm.app.src",
      "src/xmlm.erl",
      "src/xmlm.gleam",
      "src/xmlm_ffi.erl",
      "src/xmlm_ffi.mjs",
    ]
    |> list.map(fn(path) { filepath.join(directory, path) })
    |> list.sort(string.compare)

  assert files == expected
}

pub fn extract_source_files__correctly_sets_permissions__test() {
  let assert Ok(tarball) =
    simplifile.read_bits("test/codesearch/data/qcheck-1.0.4.tar")

  use directory <- temporary.create(temporary.directory())

  let assert Ok(_) = corpus.extract_source_files(tarball, directory)

  let assert Ok(files) = simplifile.read_directory(directory)

  list.each(files, fn(file) {
    let assert Ok(is_file) = simplifile.is_file(file)
    let assert Ok(is_directory) = simplifile.is_directory(file)

    let assert Ok(file_info) = simplifile.file_info(file)
    let permissions = simplifile.file_info_permissions_octal(file_info)

    case is_file, is_directory {
      True, True -> panic as "should be impossible"
      False, False -> Nil
      True, False -> {
        assert permissions == 0o644
      }
      False, True -> {
        assert permissions == 0o755
      }
    }
  })
}

// CORPUS --------------------------------------------------------------------
//
//

pub fn corpus_roundtrip_1__test() {
  let the_corpus =
    corpus.Corpus(
      files: iv.from_list(["file1", "file2", "file3", "file4"]),
      trigram_index: corpus.TrigramIndex(
        dict.from_list([
          #("abc", set.from_list([0])),
          #("bcd", set.from_list([1])),
          #("cde", set.from_list([0, 1])),
          #("def", set.from_list([0, 1, 2])),
          #("efg", set.from_list([3])),
        ]),
      ),
      package_metadata: [
        corpus.PackageMetadata(
          name: "package1",
          latest_version: "1.2.3",
          inserted_at: timestamp.from_unix_seconds(0),
          updated_at: timestamp.from_unix_seconds(1),
          files: set.from_list([0, 1, 2]),
        ),
        corpus.PackageMetadata(
          name: "package2",
          latest_version: "4.5.6",
          inserted_at: timestamp.from_unix_seconds(2),
          updated_at: timestamp.from_unix_seconds(3),
          files: set.from_list([3]),
        ),
      ],
    )

  let serialized = corpus.serialize_corpus(the_corpus)
  let assert Ok(deserialized) = corpus.deserialize_corpus(serialized)

  assert deserialized == the_corpus
}

pub fn corpus_roundtrip__test() {
  use corpus <- qcheck.given(corpus_generator())

  let serialized = corpus.serialize_corpus(corpus)
  let assert Ok(deserialized) = corpus.deserialize_corpus(serialized)

  assert_corpus_equal(deserialized, corpus)
}

fn assert_corpus_equal(a: corpus.Corpus, b: corpus.Corpus) {
  // We need to check the underlying list data as the array internal data isn't
  // stable with our serialization.
  assert iv.to_list(a.files) == iv.to_list(b.files) as "files should be equal"
  assert a.trigram_index == b.trigram_index as "trigram_index should be equal"
  assert a.package_metadata == b.package_metadata
    as "package_metadata should be equal"
}

// INDEXING SOURCE FILES -----------------------------------------------------
//
//

type TestFile {
  TestFile(data: String, directory: String, filename: String)
}

fn full_path(test_file: TestFile) -> String {
  filepath.join(test_file.directory, test_file.filename)
}

fn write_test_file(test_file: TestFile) {
  let assert Ok(Nil) = simplifile.create_directory_all(test_file.directory)
  let assert Ok(Nil) =
    simplifile.write(to: full_path(test_file), contents: test_file.data)
  Nil
}

pub fn index_source_files__test() {
  use dir <- temporary.create(temporary.directory())

  let package1 = [
    TestFile(data: "abc", directory: filepath.join(dir, "p1"), filename: "abc"),
    TestFile(
      data: "abcd",
      directory: filepath.join(dir, "p1"),
      filename: "abcd",
    ),
    TestFile(data: "xyz", directory: filepath.join(dir, "p1"), filename: "xyz"),
  ]
  let package2 = [
    TestFile(data: "ABC", directory: filepath.join(dir, "p2"), filename: "ABC"),
    TestFile(
      data: "ABCD",
      directory: filepath.join(dir, "p2"),
      filename: "ABCD",
    ),
    TestFile(data: "xyz", directory: filepath.join(dir, "p2"), filename: "xyz"),
  ]

  list.each(list.flatten([package1, package2]), write_test_file)

  let trigram_index = dict.new()

  // First package

  let source_files = list.map(package1, full_path)
  let assert #(trigram_index, []) =
    corpus.index_source_files(source_files, 0, trigram_index)

  let expected =
    dict.from_list([
      #("abc", set.from_list([0, 1])),
      #("bcd", set.from_list([1])),
      #("xyz", set.from_list([2])),
    ])

  assert trigram_index == expected

  // Second package

  let source_files = list.map(package2, full_path)
  let assert #(trigram_index, []) =
    corpus.index_source_files(source_files, 3, trigram_index)

  let expected =
    dict.from_list([
      #("abc", set.from_list([0, 1])),
      #("bcd", set.from_list([1])),
      #("xyz", set.from_list([2, 5])),
      #("ABC", set.from_list([3, 4])),
      #("BCD", set.from_list([4])),
    ])

  assert trigram_index == expected
}

// CORPUS GENERATOR ----------------------------------------------------------
//
//

fn corpus_generator() {
  use files <- qcheck.bind(files_generator())
  let file_count = iv.size(files)
  use trigram_index, package_metadata <- qcheck.map2(
    trigram_index_generator(file_count),
    package_metadata_list_generator(file_count),
  )

  corpus.Corpus(files:, trigram_index:, package_metadata:)
}

fn trigram_generator() {
  qcheck.fixed_length_string_from(qcheck.uniform_printable_ascii_codepoint(), 3)
}

fn files_generator() {
  use names <- qcheck.map(qcheck.list_from(qcheck.string()))
  iv.from_list(names)
}

fn file_indices_generator(file_count: Int) {
  use indices <- qcheck.map(
    qcheck.list_from(qcheck.bounded_int(0, file_count - 1)),
  )
  set.from_list(indices)
}

fn trigram_index_generator(file_count: Int) {
  use index <- qcheck.map(qcheck.generic_dict(
    keys_from: trigram_generator(),
    values_from: file_indices_generator(file_count),
    size_from: qcheck.small_non_negative_int(),
  ))
  corpus.TrigramIndex(index:)
}

/// Generate package metadata
///
/// - We don't generate more packages than files.
///
/// - We don't generate file indices that are "valid" across packages...real
/// data wouldn't have any overlap in the file indices across packages, but this
/// generate will generate those. Shouldn't matter for testing parsing though.
fn package_metadata_list_generator(file_count: Int) {
  let length_from = {
    use size <- qcheck.map(qcheck.small_strictly_positive_int())
    int.min(size, file_count)
  }

  qcheck.generic_list(
    elements_from: package_metadata_generator(file_count),
    length_from:,
  )
}

fn package_metadata_generator(file_count: Int) {
  use name, latest_version, inserted_at, updated_at, files <- qcheck.map5(
    qcheck.string(),
    version_generator(),
    serde_test.timestamp_generator(),
    serde_test.timestamp_generator(),
    file_indices_generator(file_count),
  )

  corpus.PackageMetadata(
    name:,
    latest_version:,
    inserted_at:,
    updated_at:,
    files:,
  )
}

fn version_generator() {
  use major, minor, patch <- qcheck.map3(
    qcheck.small_non_negative_int(),
    qcheck.small_non_negative_int(),
    qcheck.small_non_negative_int(),
  )

  int.to_string(major)
  <> "."
  <> int.to_string(minor)
  <> "."
  <> int.to_string(patch)
}
