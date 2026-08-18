package source_facts

Literal := "literal"
Value :: 1
Value_Alias :: Value

Record :: struct {
	id: int,
}
Record_Alias :: Record
Distinct_Bytes :: distinct [8]u32
Predicate :: #type proc(value: int) -> bool

Run :: proc() {}
Run_Alias :: Run

Container :: proc() {
	nested :: proc() {
		local := 1
	}
	_ = nested
}
