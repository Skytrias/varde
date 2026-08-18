package enums

State :: enum u8 {
	// No state has been selected.
	Unknown, // The implicit default.
	// The system is ready.
	Ready = 0x8,
	Failed,
}

BMP_Gamut_Mapping_Intent :: enum u32le {
	INVALID          = 0x00000000, // If not V5, this field will just be zero-initialized and not valid.
	ABS_COLORIMETRIC = 0x00000008,
	BUSINESS         = 0x00000001,
	GRAPHICS         = 0x00000002,
	IMAGES           = 0x00000004,
}

RGB_Pixel  :: [3]u8
RGBA_Pixel :: [4]u8
Little_Endian_Count :: u32le

Pixel_Union :: union {
	// A one-channel pixel.
	u8,
	RGBA_Pixel,
	[4]u16,
}

Pixel_Flags          :: bit_set[BMP_Gamut_Mapping_Intent; u32]
Distinct_Pixel_Flags :: distinct bit_set[BMP_Gamut_Mapping_Intent; u32]

Pixel_Bits :: bit_field u8 {
	// The low channel.
	low:  3,
	high: 5,
}

Load_One :: proc() {}
Load_Two :: proc() {}
Load     :: proc{Load_One, Load_Two}

@(private)
hidden_value :: 1

@(private)
hidden_variable: int
