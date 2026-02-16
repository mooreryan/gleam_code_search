import codesearch/index.{type Index}
import codesearch/log
import envoy
import formal/form.{type Form}
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import lustre/attribute
import lustre/element
import lustre/element/html
import mist
import wisp
import wisp/wisp_mist

const min_query_length: Int = 3

const max_query_length: Int = 64

type Context {
  Context(static_directory: String)
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

pub fn main() -> Nil {
  wisp.configure_logger()
  wisp.set_logger_level(wisp.DebugLevel)

  let secret_key_base = wisp.random_string(64)

  let assert Ok(index_path) = envoy.get("GLEAM_CODESEARCH_INDEX")
    as "env var GLEAM_CODESEARCH_INDEX was not set"

  log.debug("Reading index")

  wisp.log_debug("Reading index")
  // let assert Ok(index) = cli.read_index(index_path)
  //   as "failed to read and parse index"
  let assert Ok(index) = index.read_binary(index_path)
    as "failed to read and parse index"

  log.debug("Putting index")

  put_index(index)
  log.debug("Starting server")

  let context = Context(static_directory: static_directory())

  let assert Ok(_) =
    wisp_mist.handler(handle_request(_, context), secret_key_base)
    |> mist.new
    |> mist.port(4444)
    |> mist.start

  process.sleep_forever()
}

fn handle_request(request: wisp.Request, context: Context) -> wisp.Response {
  use request <- middleware(request, context)

  case wisp.path_segments(request) {
    [] -> {
      let empty_form = search_form()
      let page = home_page(empty_form)
      let body = render_page(page, title: option.None)
      wisp.html_response(body, 200)
    }

    ["search"] -> {
      use <- wisp.require_method(request, http.Post)
      use formdata <- wisp.require_form(request)

      let form_result =
        search_form() |> form.add_values(formdata.values) |> form.run

      case form_result {
        Ok(search_form) -> {
          wisp.log_debug("searching query: " <> search_form.query)
          let search_result = index.search_query(search_form.query, get_index())

          case search_result {
            Ok(search_results) -> {
              let sorted_search_results =
                list.sort(search_results, fn(a, b) {
                  string.compare(a.file, b.file)
                })
              let body =
                render_page(
                  search_results_page(sorted_search_results),
                  title: Some("Search Results"),
                )
              wisp.html_response(body, 200)
            }
            Error(errors) -> {
              wisp.log_error(string.join(errors, ";"))
              wisp.internal_server_error()
            }
          }
        }
        Error(form) -> {
          // Rerender the home page, the form has errors now.
          let body = render_page(home_page(form), title: option.None)
          wisp.html_response(body, 422)
        }
      }
    }

    _ -> wisp.not_found()
  }
}

fn search_results_page(
  search_results: List(index.SearchResult),
) -> element.Element(a) {
  html.div([attribute.class("space-y-6")], [
    html.h2([attribute.class("text-2xl font-bold")], [
      html.text("Search Results"),
    ]),
    html.p([], [
      html.text("Total results: "),
      html.text(int.to_string(list.length(search_results))),
    ]),
    html.div(
      [attribute.class("space-y-4")],
      list.map(search_results, search_result_view),
    ),
  ])
}

fn search_result_view(search_result: index.SearchResult) -> element.Element(a) {
  html.div(
    [attribute.class("bg-base-200 border-base-300 rounded-box border p-4")],
    [
      html.h3([attribute.class("font-mono text-sm text-primary font-bold")], [
        html.text(clean_file_name(search_result.file)),
      ]),
      html.p([attribute.class("text-xs text-base-content/70 mt-2")], [
        html.text("Line: "),
        html.text(int.to_string(search_result.line_index + 1)),
      ]),
      html.pre(
        [attribute.class("bg-base-300 rounded p-3 mt-3 overflow-x-auto")],
        [
          html.code([attribute.class("text-sm")], [
            html.text(search_result.line_with_context),
          ]),
        ],
      ),
    ],
  )
}

// TODO: this will need to change based on the actual production index location
fn clean_file_name(file_name: String) -> String {
  case string.split(file_name, "/tb/") {
    [_dir, good_part] -> good_part
    _ -> "unknown"
  }
}

fn middleware(
  request: wisp.Request,
  context: Context,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
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
      |> form.check_string_length_less_than(max_query_length)
    })
    form.success(SearchForm(query:))
  })
}

fn search_form_view(form: Form(SearchForm)) -> element.Element(b) {
  html.form([attribute.method("post"), attribute.action("/search")], [
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
        html.button(
          [attribute.type_("reset"), attribute.class("btn btn-ghost mt-1")],
          [html.text("Cancel")],
        ),
      ],
    ),
  ])
}

fn layout(
  content: element.Element(a),
  title title: option.Option(String),
) -> element.Element(a) {
  let title = case title {
    option.None -> "Hello, World!"
    Some(title) -> title <> " | Hello, World!"
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
    ]),
    html.body([], [
      html.main([attribute.class("container mx-auto pt-4")], [
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
