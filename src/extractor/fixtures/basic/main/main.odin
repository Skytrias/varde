package main

import helper "../helper"

// The documented answer.
Answer :: 42

// A record type.
Record :: struct {
	value: int,
}

Run :: proc() {}

Counter: int = 0

Copy: Record

Items: []Record

Transform :: proc(input: int) -> int {}
