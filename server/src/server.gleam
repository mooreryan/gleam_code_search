import codesearch/corpus.{type Corpus, type PackageMetadata}
import codesearch/serde
import contour
import envoy
import filepath
import formal/form.{type Form}
import gleam/erlang/process
import gleam/http.{Get, Post}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import gleam/time/timestamp.{type Timestamp}
import gleam/uri
import lifeguard
import logging
import lustre/attribute
import lustre/element
import lustre/element/html
import mist
import simplifile
import wisp.{type Request, type Response}
import wisp/wisp_mist

const min_query_length: Int = 3

const max_query_length: Int = 64

const page_size: Int = 25

const searcher_call_timeout_millis: Int = 20_000

const searcher_checkout_timeout_millis: Int = 5000

const searcher_pool_size: Int = 2

const searcher_startup_timeout_millis: Int = 5000

pub fn main() -> Nil {
  process.sleep_forever()
}

pub fn start(_type: _, _args: _) -> Result(process.Pid, _) {
  logging.configure_with(logging.default_config())
  wisp.set_logger_level(wisp.DebugLevel)

  // We don't use the secret key in this app, so just generate a random one at
  // start.
  let secret_key_base = wisp.random_string(64)

  let collect_garbage = case envoy.get("GLEAM_CODESEARCH_COLLECT_GARBAGE") {
    Ok(_) -> True
    Error(Nil) -> False
  }

  let assert Ok(index_directory) = envoy.get("GLEAM_CODESEARCH_INDEX_DIRECTORY")
    as "env var GLEAM_CODESEARCH_INDEX_DIRECTORY was not set"
  let assert Ok(True) = simplifile.is_directory(index_directory)
    as { "index directory " <> index_directory <> " does not exist" }

  let index_path = filepath.join(index_directory, "gleam_packages.index")
  let assert Ok(True) = simplifile.is_file(index_path)
    as { "index_path " <> index_path <> " does not exist" }

  let index_path_parent = filepath.join(index_directory, "..")
  let assert Ok(index_path_parent) = filepath.expand(index_path_parent)
  let assert Ok(True) = simplifile.is_directory(index_path_parent)
    as { "index_path_parent " <> index_path_parent <> " does not exist" }

  wisp.log_debug("Reading index")
  let assert Ok(index_bits) = simplifile.read_bits(index_path)
    as { "failed to read index: " <> index_path }

  let corpus = {
    logging.log(logging.Debug, "Deserializing files")
    let assert Ok(parsed) = corpus.deserialize_files(index_bits)
    let files = parsed.value

    logging.log(logging.Debug, "Deserializing trigram index")
    let assert Ok(parsed) =
      corpus.deserialize_trigram_index(parsed.remaining, collect_garbage:)
    let trigram_index = parsed.value

    logging.log(logging.Debug, "Deserializing package metadata")
    let assert Ok(parsed) =
      serde.deserialize_list(
        parsed.remaining,
        corpus.deserialize_package_metadata,
      )
      |> result.map_error(corpus.SerdeError)

    let package_metadata = parsed.value

    logging.log(logging.Debug, "Done deserializing")
    corpus.Corpus(files:, trigram_index:, package_metadata:)
  }

  wisp.log_debug("Putting index")
  put_corpus(corpus)

  wisp.log_debug("Starting server")

  let searcher_name = process.new_name("server-searcher")

  let context = Context(static_directory: static_directory(), searcher_name:)

  let server_child_specification =
    wisp_mist.handler(handle_request(_, context), secret_key_base)
    |> mist.new
    |> mist.bind("0.0.0.0")
    |> mist.port(4444)
    |> mist.supervised

  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(searcher(searcher_name, index_path_parent))
    |> static_supervisor.add(server_child_specification)
    |> static_supervisor.start
    as "failed to start supervisor"

  Ok(supervisor.pid)
}

pub fn stop(_: _) -> Nil {
  Nil
}

type SearcherMessage {
  Search(
    reply_to: process.Subject(
      Result(List(corpus.SearchResult), List(corpus.Error)),
    ),
    query: String,
    predicates: List(fn(PackageMetadata) -> Bool),
  )
}

fn searcher(
  pool_name: process.Name(lifeguard.PoolMsg(SearcherMessage)),
  index_directory_parent: String,
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  let lifeguard_child_spec =
    lifeguard.new(pool_name, Nil)
    |> lifeguard.on_message(fn(state, msg) {
      case msg {
        Search(reply_to:, query:, predicates:) -> {
          let corpus = get_corpus()

          let search_result =
            corpus.search_query(
              query,
              corpus,
              index_directory_parent,
              predicates,
              wisp.log_debug,
            )

          process.send(reply_to, search_result)
          actor.continue(state)
        }
      }
    })
    |> lifeguard.size(searcher_pool_size)
    |> lifeguard.supervised(timeout: searcher_startup_timeout_millis)

  lifeguard_child_spec
}

fn search(
  searcher_name: process.Name(lifeguard.PoolMsg(SearcherMessage)),
  query query: String,
  predicates predicates: List(fn(PackageMetadata) -> Bool),
) -> Result(
  Result(List(corpus.SearchResult), List(corpus.Error)),
  lifeguard.ApplyError,
) {
  lifeguard.call(
    process.named_subject(searcher_name),
    Search(reply_to: _, query:, predicates:),
    call_timeout: searcher_call_timeout_millis,
    // TODO: I'm not 100% clear on how this interacts with the call_timout!
    checkout_timeout: searcher_checkout_timeout_millis,
  )
}

type Context {
  Context(
    static_directory: String,
    searcher_name: process.Name(lifeguard.PoolMsg(SearcherMessage)),
  )
}

fn static_directory() -> String {
  let assert Ok(priv_directory) = wisp.priv_directory("server")
  priv_directory <> "/static"
}

const server_corpus_term_key = "server-corpus"

@external(erlang, "persistent_term", "put")
fn do_put_corpus(key: String, corpus: Corpus) -> Nil

fn put_corpus(corpus: Corpus) -> Nil {
  let _ = do_put_corpus(server_corpus_term_key, corpus)
  Nil
}

@external(erlang, "persistent_term", "get")
fn do_get_corpus(key: String) -> Corpus

fn get_corpus() -> Corpus {
  do_get_corpus(server_corpus_term_key)
}

fn handle_request(request: Request, context: Context) -> Response {
  use request <- middleware(request, context)

  case wisp.path_segments(request), request.method {
    [], Get -> handle_home_page_request(request)
    [], _ -> wisp.method_not_allowed(allowed: [Get])
    ["search"], Post -> handle_search_post_request(request)
    ["search"], Get -> handle_search_get_request(request, context)
    ["search"], _ -> wisp.method_not_allowed(allowed: [Get, Post])
    _, _ -> wisp.not_found()
  }
}

fn handle_home_page_request(request: Request) -> Response {
  use <- wisp.require_method(request, Get)
  let empty_form = search_form()
  let page = home_page(empty_form)
  let body = render_page(page, title: None)
  wisp.html_response(body, 200)
}

fn handle_search_post_request(request: Request) -> Response {
  use <- wisp.require_method(request, Post)
  use formdata <- wisp.require_form(request)

  let form_result =
    search_form() |> form.add_values(formdata.values) |> form.run

  case form_result {
    Ok(search_form) ->
      // We always start on page 1 from a post
      wisp.redirect(
        "/search?page=1&" <> search_form_to_query_params(search_form),
      )

    Error(form) -> {
      // Rerender the home page, the form has errors now.
      let body = render_page(home_page(form), title: None)
      wisp.html_response(body, 422)
    }
  }
}

fn handle_search_get_request(request: Request, context: Context) -> Response {
  use <- wisp.require_method(request, Get)

  let query_params = wisp.get_query(request)

  case parse_search_query_params(query_params) {
    Ok(SearchQueryParams(query:, page:, ..) as search_query_params) -> {
      let search_result =
        search(
          context.searcher_name,
          query:,
          predicates: search_query_params_to_predicates(search_query_params),
        )

      case search_result {
        Ok(search_result) -> {
          case search_result {
            Ok(search_results) -> {
              // Paginate
              let total_results = list.length(search_results)

              // TODO: handle pages that are out of range
              let search_results =
                search_results
                |> list.drop({ page - 1 } * page_size)
                |> list.take(page_size)

              // TODO: probably want a few tests for the pagination stuff!
              let total_pages = { total_results + page_size - 1 } / page_size

              render_page(
                search_results_page(
                  current_page: page,
                  total_pages:,
                  total_results:,
                  search_results:,
                  query:,
                ),
                title: Some("Search Results"),
              )
              |> wisp.html_response(200)
            }

            Error(errors) -> {
              let msg_for_log =
                errors |> list.map(string.inspect) |> string.join(with: "; ")
              wisp.log_error(msg_for_log)

              internal_server_error_page()
              |> render_page(title: Some("Internal Server Error"))
              |> wisp.html_response(500)
            }
          }
        }
        Error(lifeguard.NoResourcesAvailable) -> {
          render_page(no_workers_available_page(), title: Some("Too Busy"))
          // TODO: include retry-after header
          |> wisp.html_response(503)
        }
      }
    }

    Error(error) -> wisp.bad_request(error)
  }
}

fn search_results_page(
  current_page current_page: Int,
  total_pages total_pages: Int,
  // This is the REAL total, not the amount returned in the current page
  total_results total_results: Int,
  // This will generally be shorter than total results, as they are paginated
  search_results search_results: List(corpus.SearchResult),
  query query: String,
) -> element.Element(a) {
  html.div([attribute.class("space-y-6 pb-4")], [
    html.h2([attribute.class("text-2xl font-bold")], [
      html.text("Search Results"),
    ]),
    html.p([], [
      html.text("Total results: "),
      html.text(int.to_string(total_results)),
    ]),

    case total_results > 0 {
      False ->
        html.div([], [
          html.p([attribute.class("text-xs")], [
            html.text(
              "Note: queries must contain at least 3 contiguous ASCII characters",
            ),
          ]),
        ])
      True ->
        html.div([], [
          pagination_nav_view(current_page:, total_pages:, query:),
          html.div(
            [attribute.class("space-y-6")],
            list.map(search_results, search_result_view),
          ),
          pagination_nav_view(current_page:, total_pages:, query:),
        ])
    },
  ])
}

fn search_result_view(search_result: corpus.SearchResult) -> element.Element(a) {
  // Lines that are "empty" should still put a break in the code. Since we split
  // on the newline, add it back in to empty lines, so that the div won't be
  // "empty", and will show properly as a newline.
  let newlines = fn(line) {
    case line {
      "" -> "\n"
      _ -> line
    }
  }

  let matching_bg_color = "bg-[#ffaff326]"

  // This only highlights gleam code
  let highlighted_code = case string.ends_with(search_result.file, ".gleam") {
    True -> {
      let prefix =
        search_result.prefix_lines
        |> list.map(fn(line) {
          let highlighted = contour.to_html(newlines(line.line))
          element.unsafe_raw_html("", "div", [], highlighted)
        })

      let suffix =
        search_result.suffix_lines
        |> list.map(fn(line) {
          let highlighted = contour.to_html(newlines(line.line))
          element.unsafe_raw_html("", "div", [], highlighted)
        })

      let matching_line =
        element.unsafe_raw_html(
          "",
          "div",
          [attribute.class(matching_bg_color)],
          contour.to_html(newlines(search_result.matching_line.line)),
        )

      [prefix, [matching_line], suffix] |> list.flatten
    }
    False -> {
      let prefix =
        list.map(search_result.prefix_lines, fn(line) {
          html.div([], [html.text(newlines(line.line))])
        })

      let suffix =
        list.map(search_result.suffix_lines, fn(line) {
          html.div([], [html.text(newlines(line.line))])
        })

      let matching_line =
        html.div([attribute.class(matching_bg_color)], [
          html.text(newlines(search_result.matching_line.line)),
        ])

      [prefix, [matching_line], suffix] |> list.flatten
    }
  }

  let code = html.code([attribute.class("text-sm")], highlighted_code)

  let line_numbers =
    corpus.search_result_line_numbers(search_result)
    |> list.map(fn(line_number) {
      html.div([], [html.text(format_with_commas(line_number))])
    })

  html.div(
    [
      attribute.class("bg-base-300 rounded-box shadow-md p-4"),
    ],
    [
      html.h3([attribute.class("font-mono text-sm text-primary font-bold")], [
        html.text(search_result.file),
      ]),
      html.p([attribute.class("text-xs text-base-content/70 mt-2")], [
        html.text("Line: "),
        html.text(int.to_string(search_result.matching_line.index + 1)),
      ]),
      // flex gap-3 puts the line numbers and the code side-by-side
      html.div([attribute.class("rounded bg-base-100 p-3 mt-3 flex gap-3")], [
        html.div(
          [
            // shrink-0: don't shrink
            // select-none: don't let line numbers copy with the code
            attribute.class("shrink-0 text-sm text-right select-none"),
          ],
          [
            html.pre([], [
              html.code([attribute.class("hl-line-numbers")], line_numbers),
            ]),
          ],
        ),
        // min-w-0: override flex's min-width: auto, which allows elment to
        // shrink and trigger overflow
        html.div([attribute.class("overflow-x-auto min-w-0 flex-1")], [
          html.pre([], [code]),
        ]),
      ]),
    ],
  )
}

fn pagination_nav_view(
  current_page current_page: Int,
  total_pages total_pages: Int,
  query query: String,
) {
  let encoded_query = uri.percent_encode(query)

  let page_link = fn(page: Int, label: String, enabled: Bool) {
    let href = "/search?page=" <> int.to_string(page) <> "&q=" <> encoded_query

    let btn_disabled = attribute.classes([#("btn-disabled", !enabled)])

    html.a([attribute.class("btn btn-xs"), btn_disabled, attribute.href(href)], [
      html.text(label),
    ])
  }

  let first = page_link(1, "<<", current_page > 1)
  let prev = page_link(current_page - 1, "<", current_page > 1)
  let next = page_link(current_page + 1, ">", current_page < total_pages)
  let last = page_link(total_pages, ">>", current_page < total_pages)

  let current =
    html.form(
      [attribute.method("GET"), attribute.class("flex items-center gap-2")],
      [
        html.text("Page"),
        html.input([
          attribute.type_("number"),
          attribute.name("page"),
          attribute.id("page"),
          attribute.value(format_with_commas(current_page)),
          attribute.class("input input-sm input-bordered w-20 text-center"),
        ]),
        html.input([
          attribute.type_("hidden"),
          attribute.name("q"),
          attribute.value(query),
        ]),

        html.text("of "),
        // TODO: commas function
        html.text(format_with_commas(total_pages)),
      ],
    )

  html.div([attribute.class("flex items-center gap-4 text-xs py-2")], [
    first,
    prev,
    current,
    next,
    last,
  ])
}

@internal
pub fn format_with_commas(n: Int) -> String {
  let str = int.to_string(n)

  case n < 0 {
    True -> "-" <> format_digits(string.drop_start(str, 1))
    False -> format_digits(str)
  }
}

fn format_digits(str: String) -> String {
  str
  |> string.to_graphemes
  |> list.reverse
  |> group_by_threes
  |> list.reverse
  |> string.join("")
}

fn group_by_threes(digits: List(String)) -> List(String) {
  case digits {
    [] | [_] | [_, _] | [_, _, _] -> digits
    [a, b, c, ..rest] -> [a, b, c, ",", ..group_by_threes(rest)]
  }
}

fn middleware(
  request: Request,
  context: Context,
  handle_request: fn(Request) -> Response,
) -> Response {
  let request = wisp.method_override(request)
  use <- wisp.log_request(request)
  use <- wisp.rescue_crashes
  use request <- wisp.handle_head(request)
  use request <- wisp.csrf_known_header_protection(request)

  use <- wisp.serve_static(
    request,
    under: "/static",
    from: context.static_directory,
  )

  handle_request(request)
}

fn home_page(form: Form(SearchForm)) -> element.Element(a) {
  html.div([], [
    html.h1([attribute.class("text-2xl font-bold")], [
      html.text("Gleam Code Search"),
    ]),
    search_form_view(form),
  ])
}

type SearchForm {
  // TODO: start here!
  SearchForm(
    query: String,
    package_name: Option(String),
    minimum_inserted_at: Option(Timestamp),
    maximum_inserted_at: Option(Timestamp),
    minimum_updated_at: Option(Timestamp),
    maximum_updated_at: Option(Timestamp),
  )
}

fn search_form_to_query_params(search_form: SearchForm) {
  [
    Some(#("q", search_form.query)),
    search_form.package_name
      |> option.map(fn(package_name) { #("package_name", package_name) }),
    search_form.minimum_inserted_at
      |> option.map(fn(minimum_inserted_at) {
        #("minimum_inserted_at", timestamp_to_date(minimum_inserted_at))
      }),
    search_form.maximum_inserted_at
      |> option.map(fn(maximum_inserted_at) {
        #("maximum_inserted_at", timestamp_to_date(maximum_inserted_at))
      }),
    search_form.minimum_updated_at
      |> option.map(fn(minimum_updated_at) {
        #("minimum_updated_at", timestamp_to_date(minimum_updated_at))
      }),
    search_form.maximum_updated_at
      |> option.map(fn(maximum_updated_at) {
        #("maximum_updated_at", timestamp_to_date(maximum_updated_at))
      }),
  ]
  |> list_filter_option
  |> list.reverse
  |> uri.query_to_string
}

fn list_filter_option(l: List(Option(a))) -> List(a) {
  list.fold(l, [], fn(acc, opt) {
    case opt {
      None -> acc
      Some(x) -> [x, ..acc]
    }
  })
}

fn timestamp_to_date(timestamp: Timestamp) -> String {
  let #(date, _time) = timestamp.to_calendar(timestamp, calendar.utc_offset)
  let calendar.Date(year:, month:, day:) = date

  int.to_string(year)
  <> "-"
  <> int.to_string(calendar.month_to_int(month))
  <> "-"
  <> int.to_string(day)
}

// TODO: any more param validation needed here?
fn search_form() -> Form(SearchForm) {
  form.new({
    use query <- form.field("query", {
      form.parse_string
      |> form.check_not_empty
      |> form.check_string_length_more_than(min_query_length - 1)
      |> form.check_string_length_less_than(max_query_length + 1)
    })
    use package_name <- form.field("package_name", {
      form.parse_optional(form.parse_string)
    })
    use minimum_inserted_at <- form.field(
      "minimum_inserted_at",
      form_parse_timestamp(),
    )
    use maximum_inserted_at <- form.field(
      "maximum_inserted_at",
      form_parse_timestamp(),
    )
    use minimum_updated_at <- form.field(
      "minimum_updated_at",
      form_parse_timestamp(),
    )
    use maximum_updated_at <- form.field(
      "maximum_updated_at",
      form_parse_timestamp(),
    )
    form.success(SearchForm(
      query:,
      package_name:,
      minimum_inserted_at:,
      maximum_inserted_at:,
      minimum_updated_at:,
      maximum_updated_at:,
    ))
  })
}

fn form_parse_timestamp() -> form.Parser(Option(Timestamp)) {
  form.parse_optional(form.parse_date)
  |> form.map(option.map(_, timestamp_from_date))
}

fn timestamp_from_date(date) {
  timestamp.from_calendar(
    date:,
    time: calendar.TimeOfDay(0, 0, 0, 0),
    offset: calendar.utc_offset,
  )
}

/// NOTE: this goes along with the SearchForm type. So check it out!
type SearchQueryParams {
  SearchQueryParams(
    query: String,
    page: Int,
    package_name: Option(String),
    minimum_inserted_at: Option(Timestamp),
    maximum_inserted_at: Option(Timestamp),
    minimum_updated_at: Option(Timestamp),
    maximum_updated_at: Option(Timestamp),
  )
}

fn search_query_params_to_predicates(
  params: SearchQueryParams,
) -> List(fn(PackageMetadata) -> Bool) {
  [
    optional_predicate(params.package_name, fn(name) {
      fn(pm: PackageMetadata) { pm.name == name }
    }),
    optional_predicate(params.minimum_inserted_at, fn(minimum) {
      fn(pm: PackageMetadata) { at_or_after(pm.inserted_at, minimum) }
    }),
    optional_predicate(params.minimum_updated_at, fn(minimum) {
      fn(pm: PackageMetadata) { at_or_after(pm.updated_at, minimum) }
    }),
    optional_predicate(params.maximum_inserted_at, fn(maximum) {
      fn(pm: PackageMetadata) { at_or_before(pm.inserted_at, maximum) }
    }),
    optional_predicate(params.maximum_updated_at, fn(maximum) {
      fn(pm: PackageMetadata) { at_or_before(pm.updated_at, maximum) }
    }),
  ]
  |> list.flatten
}

/// This is like option.map but puts results in lists.
///
fn optional_predicate(
  option: Option(a),
  to_predicate: fn(a) -> fn(PackageMetadata) -> Bool,
) -> List(fn(PackageMetadata) -> Bool) {
  case option {
    None -> []
    Some(value) -> [to_predicate(value)]
  }
}

fn at_or_after(field_value: Timestamp, minimum: Timestamp) -> Bool {
  timestamp.compare(field_value, minimum) != order.Lt
}

fn at_or_before(field_value: Timestamp, maximum: Timestamp) -> Bool {
  timestamp.compare(field_value, maximum) != order.Gt
}

/// This one is for parsing the search query when it is encoded in a query
/// string.
///
fn parse_search_query_params(
  query_params: List(#(String, String)),
) -> Result(SearchQueryParams, String) {
  let page = case list.key_find(query_params, "page") {
    Ok(page) -> int.parse(page) |> result.unwrap(1)
    Error(Nil) -> 1
  }

  // TODO: would be better to return all the errors rather than the first one!

  use query <- result.try(case list.key_find(query_params, "q") {
    Ok(query) -> {
      case string.length(query) {
        n if min_query_length <= n && n <= max_query_length -> Ok(query)
        _ -> Error("missing or malformed query string")
      }
    }

    Error(Nil) -> Error("missing or malformed query string")
  })

  use minimum_inserted_at <- result.try(
    list.key_find(query_params, "minimum_inserted_at") |> maybe_parse_timestamp,
  )

  use maximum_inserted_at <- result.try(
    list.key_find(query_params, "maximum_inserted_at") |> maybe_parse_timestamp,
  )

  use minimum_updated_at <- result.try(
    list.key_find(query_params, "minimum_updated_at") |> maybe_parse_timestamp,
  )

  use maximum_updated_at <- result.try(
    list.key_find(query_params, "maximum_updated_at") |> maybe_parse_timestamp,
  )

  let package_name = case list.key_find(query_params, "package_name") {
    Ok(package_name) -> Some(package_name)
    Error(Nil) -> None
  }

  Ok(SearchQueryParams(
    query:,
    page:,
    package_name:,
    minimum_inserted_at:,
    maximum_inserted_at:,
    minimum_updated_at:,
    maximum_updated_at:,
  ))
}

fn maybe_parse_timestamp(
  input: Result(String, Nil),
) -> Result(Option(Timestamp), String) {
  case input {
    Error(Nil) -> Ok(None)
    Ok(input) -> {
      case parse_date(input) {
        Error(Nil) -> Error("failed to parse date " <> input)
        Ok(date) -> Ok(Some(timestamp_from_date(date)))
      }
    }
  }
}

fn parse_date(input: String) -> Result(Date, Nil) {
  case string.split(input, "-") {
    [year, month, day] -> {
      use year <- result.try(int.parse(year))
      use month <- result.try(int.parse(month))
      use day <- result.try(int.parse(day))
      use month <- result.try(calendar.month_from_int(month))
      let date = calendar.Date(year, month, day)
      case calendar.is_valid_date(date) {
        True -> Ok(date)
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn search_form_view(form: Form(SearchForm)) -> element.Element(b) {
  html.form(
    [
      attribute.method("post"),
      attribute.action("/search"),
      // A bit of JS to disable the submit button on form submit.
      attribute.attribute(
        "onsubmit",
        "this.querySelector('button[type=submit]').disabled=true",
      ),
    ],
    [
      html.fieldset(
        [
          attribute.class(
            "fieldset bg-base-200 border-base-300 rounded-box w-xs border p-4",
          ),
        ],
        [
          html.legend([attribute.class("fieldset-legend")], [
            html.text("Search"),
          ]),

          // Required query field
          field_view(
            label_text: "Code",
            input_id: "query",
            input_attrs: [
              attribute.type_("text"),
              attribute.name("query"),
              attribute.id("query"),
              attribute.required(True),
              attribute.minlength(min_query_length),
              attribute.maxlength(max_query_length),
              attribute.value(form.field_value(form, "query")),
              attribute.class("input validator font-mono"),
            ],
            hint: Some("⚠️ Must be between 3 and 64 characters"),
            errors: form.field_error_messages(form, "query"),
          ),

          // TODO: make sure the validation errors work here!
          // Optional filters
          html.details([attribute.class("collapse")], [
            html.summary([attribute.class("label cursor-pointer")], [
              html.text("Filters"),
            ]),

            html.div([attribute.class("mt-2 flex flex-col gap-2")], [
              field_view(
                label_text: "Package name",
                input_id: "package_name",
                input_attrs: [
                  attribute.type_("text"),
                  attribute.name("package_name"),
                  attribute.id("package_name"),
                  attribute.value(form.field_value(form, "package_name")),
                  attribute.class("input font-mono"),
                ],
                hint: None,
                errors: form.field_error_messages(form, "package_name"),
              ),

              date_range_view(legend: "Inserted at", base: "inserted_at", form:),
              date_range_view(legend: "Updated at", base: "updated_at", form:),
            ]),
          ]),

          html.button(
            [attribute.type_("submit"), attribute.class("btn btn-primary mt-4")],
            [html.text("Submit")],
          ),
        ],
      ),
    ],
  )
}

/// A reusable field helper that uses the label/input/errors pattern.
///
/// `hint` is the HTML5 validator message: pass None for fields without
/// constraints.
///
fn field_view(
  label_text label_text: String,
  input_id input_id: String,
  input_attrs input_attrs: List(attribute.Attribute(a)),
  hint hint: Option(String),
  errors errors: List(String),
) -> element.Element(a) {
  html.div([attribute.class("mb-2")], [
    html.label([attribute.for(input_id), attribute.class("label")], [
      html.text(label_text),
    ]),
    html.input(input_attrs),

    // HTML5 validation errors
    case hint {
      Some(hint) ->
        html.span([attribute.class("validator-hint font-bold")], [
          html.text(hint),
        ])
      None -> element.none()
    },

    // Any backend form errors
    html.div(
      [],
      list.map(errors, fn(msg) {
        html.p([attribute.class("text-error")], [element.text(msg)])
      }),
    ),
  ])
}

// TODO: update the search form!

/// A date range component (use it for both inserted_at and updated_at).
///
/// - `base` is the field name base, e.g. "inserted_at" ->
/// "minimum_inserted_at and "maximum_inserted_at"
///
fn date_range_view(
  legend legend: String,
  base base: String,
  form form: Form(SearchForm),
) -> element.Element(a) {
  let from_id = "minimum_" <> base
  let to_id = "maximum_" <> base

  html.div([attribute.class("mt-3")], [
    html.p([attribute.class("label")], [html.text(legend)]),
    html.div([attribute.class("flex gap-2 items-center")], [
      field_view(
        "Minimum",
        from_id,
        [
          attribute.type_("date"),
          attribute.id(from_id),
          attribute.name(from_id),
          attribute.value(form.field_value(form, from_id)),
          attribute.class("input"),
          // JS: keep "to" min in sync with "from"
          attribute.attribute(
            "onchange",
            "document.getElementById('" <> to_id <> "').min = this.value",
          ),
        ],
        None,
        form.field_error_messages(form, from_id),
      ),
      field_view(
        "Maximum",
        to_id,
        [
          attribute.type_("date"),
          attribute.id(to_id),
          attribute.name(to_id),
          attribute.value(form.field_value(form, to_id)),
          attribute.class("input"),
          attribute.attribute(
            "onchange",
            "document.getElementById('" <> from_id <> "').max = this.value",
          ),
        ],
        None,
        form.field_error_messages(form, to_id),
      ),
    ]),
  ])
}

fn no_workers_available_page() -> element.Element(a) {
  html.div([], [
    html.h1([attribute.class("text-2xl font-bold")], [
      html.text("Gleam Code Search"),
    ]),
    html.div([], [
      html.p([], [
        html.text(
          "The server has too many requests right now.  Try again in a few moments!",
        ),
      ]),
    ]),
  ])
}

fn nav_view() -> element.Element(a) {
  html.nav([attribute.class("pb-4")], [
    html.a([attribute.href("/"), attribute.class("btn btn-ghost")], [
      html.text("Home"),
    ]),
  ])
}

fn internal_server_error_page() -> element.Element(_) {
  html.div([], [
    html.h1([attribute.class("text-2xl font-bold")], [
      html.text("Gleam Code Search"),
    ]),
    html.h2([attribute.class("text-xl text-error mt-4")], [
      html.text("500 — Internal Server Error"),
    ]),
    html.p([attribute.class("mt-2")], [
      html.text("Oh no, something went wrong on our end! Please "),
      html.a(
        [
          attribute.class("link"),
          attribute.href(
            "https://github.com/mooreryan/gleam_code_search/issues",
          ),
        ],
        [html.text("open an issue on GitHub")],
      ),
      html.text(" if this keeps happening."),
    ]),
  ])
}

fn layout(
  content: element.Element(a),
  title title: Option(String),
) -> element.Element(a) {
  let title = case title {
    None -> "Gleam Code Search"
    Some(title) -> title <> " | Gleam Code Search"
  }

  html.html([attribute.attribute("lang", "en")], [
    html.head([], [
      html.meta([attribute.charset("utf-8")]),
      html.meta([
        attribute.name("viewport"),
        attribute.content("width=device-width, initial-scale=1.0"),
      ]),
      html.title([], title),
      html.link([
        attribute.rel("stylesheet"),
        attribute.href("/static/css/app.css"),
      ]),
      html.script(
        [],
        "
      window.addEventListener('pageshow', function() {
        var btn = document.querySelector('button[type=submit]');
        if (btn) btn.disabled = false;
      });
",
      ),
    ]),
    html.body([attribute.class("container mx-auto pt-4 p-2")], [
      nav_view(),
      html.main([attribute.class("")], [
        content,
      ]),
    ]),
  ])
}

fn render_page(
  content: element.Element(a),
  title title: Option(String),
) -> String {
  layout(content, title:) |> element.to_document_string
}
