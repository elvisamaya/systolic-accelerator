# Systolic-array matrix-multiply accelerator: build and test flow
#
#   make              run all tests
#   make unit         unit tests: PE, array (N=2,4,8), accelerator (N=4,8)
#   make regress      random regression vs the NumPy golden model
#   make clean

IVERILOG := iverilog -g2012 -Wall -Wno-timescale -Wno-sensitivity-entire-array -I rtl
VVP      := vvp -n
PY       := python3
BUILD    := build

ACCEL_RTL := rtl/pe.v rtl/systolic_array.v rtl/accel.v

.PHONY: all test unit regress clean
.SECONDARY:

all: test

test: unit regress
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
	$(call unit_test,tb_array_n2,-DN=2,tb/tb_array.v rtl/pe.v rtl/systolic_array.v)
	$(call unit_test,tb_array_n4,-DN=4,tb/tb_array.v rtl/pe.v rtl/systolic_array.v)
	$(call unit_test,tb_array_n8,-DN=8,tb/tb_array.v rtl/pe.v rtl/systolic_array.v)
	$(call unit_test,tb_accel_n4,-DN=4,tb/tb_accel.v $(ACCEL_RTL))
	$(call unit_test,tb_accel_n8,-DN=8,tb/tb_accel.v $(ACCEL_RTL))

# ---------------------------------------------------------------- golden-model regression
$(BUILD)/tb_accel_jobs_n%.vvp: tb/tb_accel_jobs.v $(ACCEL_RTL) | $(BUILD)
	@$(IVERILOG) -DN=$* -o $@ tb/tb_accel_jobs.v $(ACCEL_RTL)

regress: $(BUILD)/tb_accel_jobs_n4.vvp $(BUILD)/tb_accel_jobs_n8.vvp
	@echo "=== regress ==="
	@for n in 4 8; do for s in 1 2 3; do \
		$(PY) scripts/regress.py --n $$n --jobs 400 --seed $$s || exit 1; \
	done; done

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
