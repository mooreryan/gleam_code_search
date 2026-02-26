import argv
import codesearch/tar
import envoy
import filepath
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import logging
import simplifile

// TODO: set dir permissions to 755 and file permissions to 644 after the untar
// operation

const http_request_wait_millis = 1000

pub type Error {
  BadCliArgsError
  FailedToBuildRequestError
  FileError(simplifile.FileError)
  HttpcError(httpc.HttpError)
  JsonDecodeError(json.DecodeError)
  MissingEnvVariableError(name: String)
  NotAFileError(path: String)
  TarError(tar.Error)
  UnexpectedHttpResponseStatusCodeError(expected: Int, received: Int)
}

// TODO: move all ffi into one file
@external(erlang, "fetch_packages_ffi", "stop")
fn stop(status: Int) -> Result(Nil, String)

pub fn main() -> Nil {
  logging.configure(logging.Config(show_timestamp: True))

  case run() {
    Ok(Nil) -> Nil
    Error(error) -> {
      logging.log(logging.Error, string.inspect(error))
      let assert Ok(Nil) = stop(1)
      process.sleep_forever()
    }
  }
}

fn run() {
  use hex_api_key <- result.try(
    envoy.get("HEX_API_KEY")
    |> result.replace_error(MissingEnvVariableError("HEX_API_KEY")),
  )

  use #(source_outdir, metadata_outdir) <- result.try(
    case argv.load().arguments {
      [source_outdir, metadata_outdir] -> Ok(#(source_outdir, metadata_outdir))
      _ -> Error(BadCliArgsError)
    },
  )

  use Nil <- result.try(
    simplifile.create_directory_all(source_outdir)
    |> result.map_error(FileError),
  )
  use Nil <- result.try(
    simplifile.create_directory_all(metadata_outdir)
    |> result.map_error(FileError),
  )

  logging.log(logging.Info, "starting to fetch packages")
  use stdlib_package <- result.try(fetch_stdlib(hex_api_key))
  use stdlib_dependent_packages <- result.try(fetch_packages(hex_api_key))

  let gleam_packages = [stdlib_package, ..stdlib_dependent_packages]

  logging.log(logging.Info, "writing metadata")
  let metadata_outfile = filepath.join(metadata_outdir, "package_metadata.json")
  use Nil <- result.try(
    json.array(gleam_packages, hex_package_to_json)
    |> json.to_string
    |> simplifile.write(to: metadata_outfile, contents: _)
    |> result.map_error(FileError),
  )

  logging.log(
    logging.Info,
    "starting to fetch "
      <> int.to_string(list.length(gleam_packages))
      <> " tarballs",
  )
  use _ <- result.try(
    list.try_fold(gleam_packages, 1, fn(i, hex_package) {
      logging.log(
        logging.Info,
        "fetching tarball for package "
          <> int.to_string(i)
          <> " "
          <> hex_package.name,
      )
      use tarball <- result.try(fetch_tarball(hex_package))
      let full_name = package_full_name(hex_package)
      let source_outdir = filepath.join(source_outdir, full_name)
      use Nil <- result.try(extract_source_files(tarball, source_outdir))
      Ok(i + 1)
    }),
  )

  logging.log(logging.Info, "Done!")

  Ok(Nil)
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

  decode_hex_package(body) |> result.map_error(JsonDecodeError)
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
      // NOTE: you will know that you have hit the last page when you get an empty json array back (`[]`)
      #("page", int.to_string(page)),
    ])
    |> request.prepend_header("accept", "application/json")
    |> request.prepend_header("authorization", hex_api_key)

  use body <- result.try(http_send(request))

  case decode_hex_packages(body) {
    Ok([]) -> packages |> list.reverse |> list.flatten |> Ok
    Ok(new_packages) ->
      do_fetch_packages(hex_api_key, page + 1, [new_packages, ..packages])
    Error(error) -> {
      logging.log(logging.Error, "decode error: " <> string.inspect(error))
      Error(JsonDecodeError(error))
    }
  }
}

pub type HexPackage {
  HexPackage(
    name: String,
    inserted_at: String,
    updated_at: String,
    latest_version: String,
  )
}

fn hex_package_decoder() -> decode.Decoder(HexPackage) {
  use name <- decode.field("name", decode.string)
  use inserted_at <- decode.field("inserted_at", decode.string)
  use updated_at <- decode.field("updated_at", decode.string)
  use latest_version <- decode.field("latest_version", decode.string)
  decode.success(HexPackage(name:, updated_at:, inserted_at:, latest_version:))
}

fn hex_packages_decoder() -> decode.Decoder(List(HexPackage)) {
  decode.list(hex_package_decoder())
}

fn decode_hex_packages(
  json: String,
) -> Result(List(HexPackage), json.DecodeError) {
  json.parse(json, hex_packages_decoder())
}

fn decode_hex_package(json: String) -> Result(HexPackage, json.DecodeError) {
  json.parse(json, hex_package_decoder())
}

pub fn hex_package_to_json(hex_package: HexPackage) -> json.Json {
  let HexPackage(name:, inserted_at:, updated_at:, latest_version:) =
    hex_package
  json.object([
    #("name", json.string(name)),
    #("inserted_at", json.string(inserted_at)),
    #("updated_at", json.string(updated_at)),
    #("latest_version", json.string(latest_version)),
  ])
}

fn package_full_name(hex_package: HexPackage) -> String {
  hex_package.name <> "-" <> hex_package.latest_version
}

fn package_tar_name(hex_package: HexPackage) -> String {
  package_full_name(hex_package) <> ".tar"
}

@internal
pub fn hex_package_tarball_request(
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
    port: option.None,
    path:,
    query: option.None,
  )
}

@internal
pub fn fetch_tarball(hex_package: HexPackage) -> Result(BitArray, Error) {
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

fn extract_source_files(tarball: BitArray, outdir: String) -> Result(Nil, Error) {
  let src_directory = filepath.join(outdir, "src")
  let include_directory = filepath.join(outdir, "include")
  let contents_tarball = outdir <> "/contents.tar.gz"

  use Nil <- result.try(
    simplifile.create_directory_all(outdir) |> result.map_error(FileError),
  )

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

  let #(_src_files, non_src_files) =
    list.partition(out_files, fn(path) {
      string.starts_with(path, src_directory)
    })

  use Nil <- result.try(
    simplifile.delete_all(non_src_files) |> result.map_error(FileError),
  )
  use Nil <- result.try(
    simplifile.delete_all([include_directory]) |> result.map_error(FileError),
  )

  Ok(Nil)
}

fn accept_file(path: String) -> Result(String, Error) {
  case simplifile.is_file(path) {
    Ok(True) -> Ok(path)
    Ok(False) -> Error(NotAFileError(path))
    Error(e) -> Error(FileError(e))
  }
}
