//// Serializing and deserializing values endocded in bit arrays.
////
//// Note: All values are serialized/deserialized as little endian.
////

import gleam/bit_array
import gleam/list
import gleam/set.{type Set}
import gleam/time/timestamp.{type Timestamp}
import iv

pub type Parsed(a) {
  Parsed(value: a, remaining: BitArray)
}

pub type Error {
  DeserializeError(message: String)
}

const size_bits = 32

// ARRAYS --------------------------------------------------------------------

pub fn serialize_array(
  array: iv.Array(a),
  serialize: fn(a) -> BitArray,
) -> BitArray {
  let size = iv.size(array)

  let serialized =
    iv.fold(array, <<>>, fn(acc, item) {
      let item = serialize(item)
      <<acc:bits, item:bits>>
    })

  <<size:little-size(size_bits), serialized:bits>>
}

pub fn deserialize_array(
  data: BitArray,
  deserialize: fn(BitArray) -> Result(Parsed(a), Error),
) -> Result(Parsed(iv.Array(a)), Error) {
  case deserialize_list(data, deserialize) {
    Ok(parsed_list) -> {
      Ok(Parsed(..parsed_list, value: iv.from_reverse_list(parsed_list.value)))
    }
    Error(error) -> Error(error)
  }
}

// LISTS ---------------------------------------------------------------------

pub fn serialize_list(list: List(a), serialize: fn(a) -> BitArray) -> BitArray {
  let reversed = list.reverse(list)
  let #(size, data) = do_serialize_list(reversed, serialize, <<>>, 0)

  <<size:little-size(size_bits), data:bits>>
}

fn do_serialize_list(
  list: List(a),
  serialize: fn(a) -> BitArray,
  acc: BitArray,
  i: Int,
) -> #(Int, BitArray) {
  case list {
    [] -> #(i, acc)
    [item, ..list] -> {
      let item = serialize(item)
      let acc = <<acc:bits, item:bits>>

      do_serialize_list(list, serialize, acc, i + 1)
    }
  }
}

pub fn deserialize_list(
  data: BitArray,
  deserialize: fn(BitArray) -> Result(Parsed(a), Error),
) -> Result(Parsed(List(a)), Error) {
  case data {
    <<size:little-size(size_bits), data:bits>> -> {
      do_deserialize_list(data, deserialize, size, [], 0)
    }
    _ -> Error(DeserializeError(message: "expected size"))
  }
}

fn do_deserialize_list(
  data: BitArray,
  deserialize: fn(BitArray) -> Result(Parsed(a), Error),
  size: Int,
  acc: List(a),
  i: Int,
) -> Result(Parsed(List(a)), Error) {
  case i < size {
    True ->
      case deserialize(data) {
        Ok(parsed) -> {
          let acc = [parsed.value, ..acc]
          do_deserialize_list(parsed.remaining, deserialize, size, acc, i + 1)
        }
        Error(error) -> Error(error)
      }
    // Note: We serialized the reversed list so we don't need to reverse when
    // deserializing.
    False -> Ok(Parsed(value: acc, remaining: data))
  }
}

// SETS ----------------------------------------------------------------------

pub fn serialize_set(set: Set(a), serialize: fn(a) -> BitArray) -> BitArray {
  let size = set.size(set)

  let serialized =
    set.fold(set, <<>>, fn(acc, item) {
      let item = serialize(item)
      <<acc:bits, item:bits>>
    })

  <<size:little-size(size_bits), serialized:bits>>
}

pub fn deserialize_set(
  data: BitArray,
  deserialize: fn(BitArray) -> Result(Parsed(a), Error),
) -> Result(Parsed(Set(a)), Error) {
  case deserialize_list(data, deserialize) {
    Ok(parsed) -> Ok(Parsed(..parsed, value: set.from_list(parsed.value)))
    Error(error) -> Error(error)
  }
}

// INT32 ---------------------------------------------------------------------

pub fn serialize_int32(n: Int) -> BitArray {
  <<n:little-size(32)>>
}

pub fn deserialize_int32(data: BitArray) -> Result(Parsed(Int), Error) {
  case data {
    <<n:little-signed-size(32), data:bits>> ->
      Ok(Parsed(value: n, remaining: data))
    other -> {
      echo other
      Error(DeserializeError(message: "expected int32"))
    }
  }
}

// STRING --------------------------------------------------------------------

pub fn serialize_string(string: String) -> BitArray {
  let bits = bit_array.from_string(string)
  // Doing it this way rather than string length will handle utf8 byte length
  // when we are decoding.
  let data_size = bit_array.bit_size(bits)
  <<data_size:little-size(size_bits), string:utf8>>
}

pub fn deserialize_string(data: BitArray) -> Result(Parsed(String), Error) {
  case data {
    <<
      byte_size:little-size(size_bits),
      string:bits-size(byte_size),
      remaining:bits,
    >> -> {
      case bit_array.to_string(string) {
        Ok(string) -> Ok(Parsed(value: string, remaining: remaining))
        Error(Nil) ->
          Error(DeserializeError(message: "expected utf8 encoded string"))
      }
    }
    _ -> Error(DeserializeError(message: "expected size followed by bytes"))
  }
}

pub fn serialize_timestamp(timestamp: Timestamp) -> BitArray {
  let #(seconds, nanoseconds) =
    timestamp.to_unix_seconds_and_nanoseconds(timestamp)

  <<seconds:little-size(64), nanoseconds:little-size(64)>>
}

pub fn deserialize_timestamp(data: BitArray) -> Result(Parsed(Timestamp), Error) {
  case data {
    <<
      // These can be negative, so we specify signed
      seconds:little-signed-size(64),
      // These can never be negative...though, this is sorta an implementation
      // detail of timestamp.from_unix_seconds_and_nanoseconds
      nanoseconds:little-size(64),
      remaining:bits,
    >> ->
      Ok(Parsed(
        value: timestamp.from_unix_seconds_and_nanoseconds(seconds, nanoseconds),
        remaining:,
      ))
    _ -> Error(DeserializeError(message: "expected secods and nanoseconds"))
  }
}
