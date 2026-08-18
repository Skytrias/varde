package lowering

plain_text :: "plain"
raw_text :: `raw`
byte_value :: u8(3)
big_endian_value :: u32be(0x716f6966)
commented_big_endian_value :: u32be(0x716f6966) // tagged value
bit_mask :: (1 << 6) | (1 << 7)
base_count :: 8
double_count :: base_count * 2
byte_size :: size_of(u8)
unit_ratio :: 1000.0 / 25.4
qualified: remote.Value
config_count :: min(#config(MAX_COUNT, double_count), 128)

Flag :: enum {First, Second}
Flags :: bit_set[Flag]
first_flag :: Flags{.First}
combined_flags :: first_flag + first_flag
