import codesearch/serde
import gleam/set
import gleam/time/timestamp
import iv
import qcheck

/// 2^32 - 1
const int32_max = 2_147_483_647

/// -2^31
const int32_min = -2_147_483_648

// ARRAYS --------------------------------------------------------------------

// Note: Arrays are a bit weird, as they don't roundtrip properly if you use
// `from_reverse_list` (and maybe in general?), which is why we test that the
// lists themselves are the same.

pub fn int_array_roundtrip__test() {
  use list <- qcheck.given(
    qcheck.list_from(qcheck.bounded_int(int32_min, int32_max)),
  )
  check_array_roundtrip(list, serde.serialize_int32, serde.deserialize_int32)
}

pub fn int_array_roundtrip_1__test() {
  check_array_roundtrip([0, -1], serde.serialize_int32, serde.deserialize_int32)
}

pub fn int_array_roundtrip_2__test() {
  check_array_roundtrip(
    // This is one that shows that the array itself doesn't have the same tree
    // structure in our current serialize/deserialize scheme.
    [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    serde.serialize_int32,
    serde.deserialize_int32,
  )
}

pub fn string_array_roundtrip__test() {
  use list <- qcheck.given(qcheck.list_from(qcheck.string()))
  check_array_roundtrip(list, serde.serialize_string, serde.deserialize_string)
}

fn check_array_roundtrip(
  list: List(a),
  serialize_element: fn(a) -> BitArray,
  deserialize_element: fn(BitArray) -> Result(serde.Parsed(a), serde.Error),
) -> Nil {
  let array = iv.from_list(list)

  let serialized = serde.serialize_array(array, serialize_element)
  let assert Ok(parsed) =
    serde.deserialize_array(serialized, deserialize_element)

  let parsed_list = parsed.value |> iv.to_list
  assert parsed_list == list
  assert parsed.remaining == <<>>
}

// LISTS ---------------------------------------------------------------------

pub fn int_list_roundtrip__test() {
  use list <- qcheck.given(
    qcheck.list_from(qcheck.bounded_int(int32_min, int32_max)),
  )

  let serialized = serde.serialize_list(list, serde.serialize_int32)
  let assert Ok(parsed) =
    serde.deserialize_list(serialized, serde.deserialize_int32)

  assert parsed == serde.Parsed(value: list, remaining: <<>>)
}

pub fn int_list_roundtrip_1__test() {
  let list = [0, 1]

  let serialized = serde.serialize_list(list, serde.serialize_int32)
  let assert Ok(parsed) =
    serde.deserialize_list(serialized, serde.deserialize_int32)

  assert parsed == serde.Parsed(value: list, remaining: <<>>)
}

pub fn int_list_roundtrip_2__test() {
  let list = []

  let serialized = serde.serialize_list(list, serde.serialize_int32)
  let assert Ok(parsed) =
    serde.deserialize_list(serialized, serde.deserialize_int32)

  assert parsed == serde.Parsed(value: list, remaining: <<>>)
}

pub fn string_list_roundtrip__test() {
  use list <- qcheck.given(qcheck.list_from(qcheck.string()))

  let serialized = serde.serialize_list(list, serde.serialize_string)
  let assert Ok(parsed) =
    serde.deserialize_list(serialized, serde.deserialize_string)

  assert parsed == serde.Parsed(value: list, remaining: <<>>)
}

// SETS ----------------------------------------------------------------------

pub fn int_set_roundtrip__test() {
  use set <- qcheck.given(qcheck.generic_set(
    elements_from: qcheck.bounded_int(int32_min, int32_max),
    size_from: qcheck.small_non_negative_int(),
  ))

  let serialized = serde.serialize_set(set, serde.serialize_int32)
  let assert Ok(parsed) =
    serde.deserialize_set(serialized, serde.deserialize_int32)

  assert parsed == serde.Parsed(value: set, remaining: <<>>)
}

pub fn int_set_roundtrip_1__test() {
  let set = set.from_list([])

  let serialized = serde.serialize_set(set, serde.serialize_int32)
  let assert Ok(parsed) =
    serde.deserialize_set(serialized, serde.deserialize_int32)

  assert parsed == serde.Parsed(value: set, remaining: <<>>)
}

pub fn string_set_roundtrip__test() {
  use set <- qcheck.given(qcheck.generic_set(
    elements_from: qcheck.string(),
    size_from: qcheck.small_non_negative_int(),
  ))

  let serialized = serde.serialize_set(set, serde.serialize_string)
  let assert Ok(parsed) =
    serde.deserialize_set(serialized, serde.deserialize_string)

  assert parsed == serde.Parsed(value: set, remaining: <<>>)
}

// INT32 ---------------------------------------------------------------------

pub fn int32_roundtrip_1__test() {
  let n = -1

  let serialized = serde.serialize_int32(n)
  let assert Ok(parsed) = serde.deserialize_int32(serialized)

  assert parsed == serde.Parsed(value: n, remaining: <<>>)
}

pub fn int32_roundtrip__test() {
  use n <- qcheck.given(qcheck.bounded_int(from: int32_min, to: int32_max))

  let serialized = serde.serialize_int32(n)
  let assert Ok(parsed) = serde.deserialize_int32(serialized)

  assert parsed == serde.Parsed(value: n, remaining: <<>>)
}

// STRING --------------------------------------------------------------------

pub fn string_roundtrip__test() {
  use string <- qcheck.given(qcheck.string())

  let serialized = serde.serialize_string(string)
  let assert Ok(parsed) = serde.deserialize_string(serialized)

  assert parsed == serde.Parsed(value: string, remaining: <<>>)
}

pub fn string_roundtrip_1__test() {
  // In utf8 this should be 194 128 or 0xC2 0x80
  let string = "\u{0080}"

  let serialized = serde.serialize_string(string)
  let assert Ok(parsed) = serde.deserialize_string(serialized)

  assert parsed == serde.Parsed(value: string, remaining: <<>>)
}

// TIMESTAMP -----------------------------------------------------------------

pub fn timestamp_roundtrip__test() {
  use timestamp <- qcheck.given(timestamp_generator())

  let serialized = serde.serialize_timestamp(timestamp)
  let assert Ok(parsed) = serde.deserialize_timestamp(serialized)

  assert parsed == serde.Parsed(value: timestamp, remaining: <<>>)
}

pub fn timestamp_roundtrip_1__test() {
  let timestamp = timestamp.from_unix_seconds_and_nanoseconds(-1_000_000, 0)
  let serialized = serde.serialize_timestamp(timestamp)
  let assert Ok(parsed) = serde.deserialize_timestamp(serialized)

  assert parsed == serde.Parsed(value: timestamp, remaining: <<>>)
}

// NOTE: This code is written by me from gleam_time package tests.

/// Generate timestamps representing instants in the range `0000-01-01T00:00:00Z`
/// to `9999-12-31T23:59:59.999999999Z`.
///
pub fn timestamp_generator() {
  // prng can only generate good integers in the range
  // [-2_147_483_648, 2_147_483_647]
  //
  // So we must get to the range we need by generating the values in parts, then
  // adding them together.
  //
  // The smallest number of milliseconds we need to generate:
  // > d=new Date("0000-01-01T00:00:00"); d.getTime()
  // -62_167_201_438_000 ms
  //     -62_167_201_438 s
  //
  // The largest number of milliseconds without leap second we need to generate:
  // > d=new Date("9999-12-31T23:59:59"); d.getTime()
  // 253_402_318_799_000 ms
  //     253_402_318_799 s
  //

  let megasecond_generator = {
    use second <- qcheck.map(qcheck.bounded_int(-62_167, 253_402))
    second * 1_000_000
  }

  let second_generator = qcheck.bounded_int(-201_438, 318_799)

  use megasecond, second, nanosecond <- qcheck.map3(
    megasecond_generator,
    second_generator,
    qcheck.bounded_int(0, 999_999_999),
  )
  let total_seconds = megasecond + second

  let assert True =
    -62_167_201_438 <= total_seconds && total_seconds <= 253_402_318_799

  timestamp.from_unix_seconds_and_nanoseconds(total_seconds, nanosecond)
}
