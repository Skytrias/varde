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
