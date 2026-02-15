import formal/form.{type Form}
import gleam/erlang/process
import gleam/http
import gleam/list
import gleam/option
import lustre/attribute
import lustre/element
import lustre/element/html
import mist
import wisp
import wisp/wisp_mist

const min_query_length = 3

const max_query_length = 64

type Context {
  Context(static_directory: String)
}

fn static_directory() -> String {
  let assert Ok(priv_directory) = wisp.priv_directory("server") |> echo
  priv_directory <> "/static"
}

pub fn main() -> Nil {
  wisp.configure_logger()

  let secret_key_base = wisp.random_string(64)

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
          let fake_result = ["first matching line", "second matching line"]

          let body = search_result_view(fake_result)
          wisp.html_response(body, 200)
        }
        Error(form) -> {
          // Rerender the home page, the form has errors now.
          let body = render_page(home_page(form), title: option.None)
          wisp.html_response(body, 422)
        }
      }

      todo
    }

    _ -> wisp.not_found()
  }
}

fn search_result_view(fake_result: List(String)) -> String {
  todo
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

fn home_page(form) -> element.Element(a) {
  html.div([], [
    html.h1([attribute.class("text-2xl")], [
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

fn search_form_view(form) {
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
    option.Some(title) -> title <> " | Hello, World!"
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
