import gleam/time/calendar
import gleam/time/timestamp
import logging

fn log(level: logging.LogLevel, msg: String) -> Nil {
  let now =
    timestamp.system_time()
    |> timestamp.to_rfc3339(calendar.local_offset())

  let msg = now <> " " <> msg

  logging.log(level, msg)
}

pub fn debug(msg: String) -> Nil {
  log(logging.Debug, msg)
}

pub fn info(msg: String) -> Nil {
  log(logging.Info, msg)
}

pub fn error(msg: String) -> Nil {
  log(logging.Error, msg)
}

pub fn configure() {
  logging.configure()
  logging.set_level(logging.Debug)
}
