import gleam/time/calendar
import gleam/time/timestamp
import logging

pub fn debug2(x: a, msg: String) -> a {
  let now =
    timestamp.system_time()
    |> timestamp.to_rfc3339(calendar.local_offset())

  let msg = now <> " " <> msg

  logging.log(logging.Debug, msg)

  x
}

pub fn debug(msg: String) -> Nil {
  let now =
    timestamp.system_time()
    |> timestamp.to_rfc3339(calendar.local_offset())

  let msg = now <> " " <> msg

  logging.log(logging.Debug, msg)
}
