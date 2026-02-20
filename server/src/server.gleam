import codesearch/index.{type Index}
import contour
import envoy
import formal/form.{type Form}
import gleam/erlang/process
import gleam/http.{Get, Post}
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleam/uri
import lifeguard
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
  wisp.configure_logger()
  wisp.set_logger_level(wisp.InfoLevel)

  // We don't use the secret key in this app, so just generate a random one at
  // start.
  let secret_key_base = wisp.random_string(64)

  let assert Ok(index_path) = envoy.get("GLEAM_CODESEARCH_INDEX")
    as "env var GLEAM_CODESEARCH_INDEX was not set"
  let assert Ok(True) = simplifile.is_file(index_path)
    as { "index file " <> index_path <> " does not exist" }

  // This is the directory where the files that went into the index live.
  let assert Ok(index_data_directory) =
    envoy.get("GLEAM_CODESEARCH_INDEX_DATA_DIRECTORY")
    as "env var GLEAM_CODESEARCH_INDEX_DATA_DIRECTORY was not set"
  let assert Ok(True) = simplifile.is_directory(index_data_directory)
    as { "index data directory " <> index_data_directory <> " does not exist" }

  wisp.log_debug("Reading index")
  let assert Ok(index) = index.read_binary(index_path)
    as { "failed to read and parse index: " <> index_path }

  wisp.log_debug("Putting index")
  put_index(index)

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
    |> static_supervisor.add(searcher(searcher_name, index_data_directory))
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
      Result(List(index.SearchResult), List(index.Error)),
    ),
    query: String,
  )
}

fn searcher(
  pool_name: process.Name(lifeguard.PoolMsg(SearcherMessage)),
  index_data_directory: String,
) -> supervision.ChildSpecification(static_supervisor.Supervisor) {
  let lifeguard_child_spec =
    lifeguard.new(pool_name, Nil)
    |> lifeguard.on_message(fn(state, msg) {
      case msg {
        Search(reply_to:, query:) -> {
          let search_result =
            index.search_query(
              query,
              get_index(),
              index_data_directory,
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
  query: String,
) -> Result(
  Result(List(index.SearchResult), List(index.Error)),
  lifeguard.ApplyError,
) {
  lifeguard.call(
    process.named_subject(searcher_name),
    Search(reply_to: _, query:),
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

@external(erlang, "persistent_term", "put")
fn do_put_index(key: String, index: Index) -> Nil

fn put_index(index: Index) -> Nil {
  let _ = do_put_index("server-index", index)
  Nil
}

@external(erlang, "persistent_term", "get")
fn do_get_index(key: String) -> Index

fn get_index() -> Index {
  do_get_index("server-index")
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
  let body = render_page(page, title: option.None)
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
        "/search?page=1&q=" <> uri.percent_encode(search_form.query),
      )

    Error(form) -> {
      // Rerender the home page, the form has errors now.
      let body = render_page(home_page(form), title: option.None)
      wisp.html_response(body, 422)
    }
  }
}

fn handle_search_get_request(request: Request, context: Context) -> Response {
  use <- wisp.require_method(request, Get)

  let query_params = wisp.get_query(request)

  case parse_search_query_params(query_params) {
    Ok(SearchQueryParams(query:, page:)) -> {
      let search_result = search(context.searcher_name, query)

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
                errors |> list.map(string.inspect) |> string.join(with: ";")
              wisp.log_error(msg_for_log)

              let #(search_failed_errors, server_errors) =
                list.partition(errors, fn(error) {
                  case error {
                    index.SearchFailed(_) -> True
                    index.ServerError(_) -> False
                  }
                })

              case search_failed_errors, server_errors {
                // This should be impossible. Don't even bother sending a real
                // page to the user.
                [], [] -> {
                  wisp.internal_server_error()
                }
                _search_failed_errors, [] -> {
                  render_page(
                    search_results_page(
                      current_page: page,
                      total_pages: 0,
                      total_results: 0,
                      search_results: [],
                      query:,
                    ),
                    title: Some("Search Results"),
                  )
                  |> wisp.html_response(200)
                }
                [], _server_errors | _, _server_errors -> {
                  internal_server_error_page()
                  |> render_page(title: Some("Internal Server Error"))
                  |> wisp.html_response(500)
                }
              }
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
  search_results search_results: List(index.SearchResult),
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

fn search_result_view(search_result: index.SearchResult) -> element.Element(a) {
  let highlighted_code = contour.to_html(search_result.line_with_context)

  let code =
    element.unsafe_raw_html(
      "",
      "code",
      [attribute.class("text-sm")],
      highlighted_code,
    )

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
        html.text(int.to_string(search_result.line_index + 1)),
      ]),
      html.pre(
        [attribute.class("bg-base-100 rounded p-3 mt-3 overflow-x-auto")],
        [code],
      ),
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
  SearchForm(query: String)
}

fn search_form() -> Form(SearchForm) {
  form.new({
    use query <- form.field("query", {
      form.parse_string
      |> form.check_not_empty
      |> form.check_string_length_more_than(min_query_length - 1)
      |> form.check_string_length_less_than(max_query_length + 1)
    })
    form.success(SearchForm(query:))
  })
}

type SearchQueryParams {
  SearchQueryParams(query: String, page: Int)
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

  let query = list.key_find(query_params, "q")

  case query {
    Ok(query) -> {
      case string.length(query) {
        n if min_query_length <= n && n <= max_query_length ->
          Ok(SearchQueryParams(query:, page:))
        _ -> Error("missing or malformed query string")
      }
    }

    Error(Nil) -> Error("missing or malformed query string")
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

          html.div([], [
            html.label([attribute.for("query"), attribute.class("label")], [
              html.text("Query"),
            ]),
            html.input([
              attribute.type_("text"),
              attribute.name("query"),
              attribute.id("query"),
              attribute.required(True),
              attribute.minlength(min_query_length),
              attribute.maxlength(max_query_length),
              attribute.value(form.field_value(form, "query")),
              attribute.class("input validator font-mono"),
            ]),

            // HTML5 validation errors
            html.span([attribute.class("validator-hint font-bold")], [
              html.text("⚠️ Must be between 3 and 64 characters"),
            ]),

            // Any backend form errors
            html.div(
              [],
              list.map(form.field_error_messages(form, "query"), fn(msg) {
                html.p([attribute.class("text-error")], [
                  element.text(msg),
                ])
              }),
            ),
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
  title title: option.Option(String),
) -> element.Element(a) {
  let title = case title {
    option.None -> "Gleam Code Search"
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
  title title: option.Option(String),
) -> String {
  layout(content, title:) |> element.to_document_string
}
