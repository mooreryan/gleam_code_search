import codesearch/fetch_packages.{HexPackage}
import gleam/http/request
import gleam/uri
import simplifile

pub fn hex_package_tarball_request_test() {
  let package =
    HexPackage(
      name: "xmlm",
      latest_version: "1.0.0",
      inserted_at: "",
      updated_at: "",
    )

  let request = fetch_packages.hex_package_tarball_request(package) |> echo
  let url = uri.to_string(request.to_uri(request))

  assert url == "https://repo.hex.pm/tarballs/xmlm-1.0.0.tar"
}
