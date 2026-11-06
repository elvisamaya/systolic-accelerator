# Systolic-array matrix-multiply accelerator: build and test flow
#
#   make              run everything below except synth
#   make unit         unit tests: PE, array (N=2,4,8), accelerator (N=4,8)
#   make regress      random regression vs the NumPy golden model
#   make soc          RISC-V + accelerator SoC: accelerated vs software matmul
#   make nn           int8 neural network (digits) running on the accelerator
#   make synth        synthesize to SkyWater 130nm cells: area + timing table
#   make lint         Verilator -Wall lint
#   make clean

IVERILOG := iverilog -g2012 -Wall -Wno-timescale -Wno-sensitivity-entire-array -I rtl -I rtl/soc
VVP      := vvp -n
PY       := python3
BUILD    := build

ACCEL_RTL := rtl/pe.v rtl/systolic_array.v rtl/accel.v
SOC_RTL   := $(wildcard rtl/soc/*.v) $(ACCEL_RTL)

LIB_URL  := https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/master/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
LIB      := $(BUILD)/sky130_fd_sc_hd__tt_025C_1v80.lib

.PHONY: all test unit regress soc nn synth lint clean
.SECONDARY:

all: test

test: unit regress soc nn
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

# ---------------------------------------------------------------- SoC
$(BUILD)/tb_soc.vvp: tb/tb_soc.v $(SOC_RTL) | $(BUILD)
	@$(IVERILOG) -o $@ tb/tb_soc.v $(SOC_RTL)

$(BUILD)/%.hex: programs/%.s scripts/rvasm.py | $(BUILD)
	@$(PY) scripts/rvasm.py $< -o $@

soc: $(BUILD)/tb_soc.vvp $(BUILD)/matmul_accel.hex $(BUILD)/matmul_sw.hex
	@echo "=== soc ==="
	@$(PY) scripts/soc_bench.py --build $(BUILD)

# ---------------------------------------------------------------- neural network
nn: $(BUILD)/tb_accel_jobs_n4.vvp
	@echo "=== nn ==="
	@$(PY) scripts/nn_demo.py --build $(BUILD)

# ---------------------------------------------------------------- synthesis
$(LIB): | $(BUILD)
	curl -sSfL -o $@ $(LIB_URL)

synth: $(LIB)
	@echo "=== synth (SkyWater 130nm, sky130_fd_sc_hd, typical corner) ==="
	@$(PY) scripts/synth_report.py --lib $(LIB) --build $(BUILD) | tee $(BUILD)/synth_table.md

# ---------------------------------------------------------------- lint
lint:
	verilator --lint-only -Wall -Irtl $(ACCEL_RTL) --top-module accel
	verilator --lint-only -Wall -Irtl -GN=8 $(ACCEL_RTL) --top-module accel
	verilator --lint-only -Wall -Irtl -Irtl/soc $(SOC_RTL) --top-module soc

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
