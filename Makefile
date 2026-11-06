# Systolic-array matrix-multiply accelerator: build and test flow
#
#   make              run all tests
#   make unit         unit tests: PE
#   make clean

IVERILOG := iverilog -g2012 -Wall -Wno-timescale -Wno-sensitivity-entire-array -I rtl
VVP      := vvp -n
BUILD    := build


.PHONY: all test unit clean
.SECONDARY:

all: test

test: unit
	@echo ""
	@echo "All tests passed."

# ---------------------------------------------------------------- unit tests
define unit_test
	@echo "=== $(1) ==="
	@$(IVERILOG) $(2) -o $(BUILD)/$(1).vvp $(3)
	@$(VVP) $(BUILD)/$(1).vvp | grep -v "VCD info" | tee $(BUILD)/$(1).log
	@grep -q "TEST PASSED" $(BUILD)/$(1).log
endef

unit: | $(BUILD)
	$(call unit_test,tb_pe,,tb/tb_pe.v rtl/pe.v)

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
