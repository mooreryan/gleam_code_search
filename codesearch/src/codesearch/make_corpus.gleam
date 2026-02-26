import argv
import codesearch/corpus
import envoy
import gleam/erlang/process
import gleam/string
import logging

pub fn main() -> Nil {
  logging.configure_with(logging.Config(show_timestamp: True))
  logging.set_level(logging.Debug)

  let assert Ok(hex_api_key) = envoy.get("HEX_API_KEY")
    as "make sure HEX_API_KEY env var is set"
  let outdir = parse_argv()

  let test_corpus = case envoy.get("MAKE_CORPUS_TEST") {
    Ok(_) -> True
    Error(Nil) -> False
  }

  case corpus.make_corpus(hex_api_key:, outdir:, test_corpus:) {
    Ok(Nil) -> Nil
    Error(error) -> {
      logging.log(logging.Error, string.inspect(error))
      let assert Ok(Nil) = stop(1)
      process.sleep_forever()
    }
  }
}

fn parse_argv() -> String {
  let assert [outdir] = argv.load().arguments as "provide an outdir"
  outdir
}

@external(erlang, "codesearch_ffi", "stop")
fn stop(status: Int) -> Result(Nil, String)
