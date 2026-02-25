import gleam/bit_array

pub type Error {
  BadBinaryError
  TarError(String)
}

pub opaque type Binary {
  // Technically this is a binary...ie bit string with size divisible by 8
  Binary(BitArray)
}

pub fn binary_from_bit_array(bit_array: BitArray) -> Result(Binary, Error) {
  case bit_array.bit_size(bit_array) % 8 {
    0 -> Ok(Binary(bit_array))
    _ -> Error(BadBinaryError)
  }
}

@external(erlang, "tar_ffi", "extract")
pub fn extract_binary(
  binary binary: Binary,
  cwd cwd: String,
  compressed compressed: Bool,
) -> Result(Nil, Error)

@external(erlang, "tar_ffi", "extract")
pub fn extract_file(
  filename filename: String,
  cwd cwd: String,
  compressed compressed: Bool,
) -> Result(Nil, Error)
