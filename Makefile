# Systolic-array matrix-multiply accelerator: build and test flow
#
#   make              run all tests (none yet)
#   make clean

IVERILOG := iverilog -g2012 -Wall -Wno-timescale -Wno-sensitivity-entire-array -I rtl
VVP      := vvp -n
BUILD    := build


.PHONY: all test clean
.SECONDARY:

all: test

test: 
	@echo ""
	@echo "All tests passed."

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
