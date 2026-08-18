package main

import helper "../helper"

// The documented answer.
Answer :: 42

// A record type.
Record :: struct #packed {
	// The stored record value.
	value: int,
	indices: [2]u32,
}

Run :: proc() {}

Counter: int = 0

Copy: Record

Items: []Record

Transform :: proc(input: int) -> int {}
