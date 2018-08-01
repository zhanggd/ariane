# Author: Florian Zaruba, ETH Zurich
# Date: 03/19/2017
# Description: Makefile for linting and testing Ariane.

# compile everything in the following library
library ?= work
# Top level module to compile
top_level ?= ariane_tb
test_top_level ?= ariane_tb
# Maximum amount of cycles for a successful simulation run
max_cycles ?= 10000000
# Test case to run
test_case ?= core_test
# QuestaSim Version
questa_version ?= -10.6b
# verilator version
verilator ?= verilator
# Sources
# Ariane PKG
ariane_pkg := include/riscv_pkg.sv src/debug/dm_pkg.sv include/ariane_pkg.sv include/nbdcache_pkg.sv include/axi_if.sv
# FPnew PKG
fpnew_pkg := src/fpnew/src/pkg/fpnew_pkg.vhd src/fpnew/src/pkg/fpnew_fmts_pkg.vhd src/fpnew/src/pkg/fpnew_comps_pkg.vhd src/fpnew/src/pkg/fpnew_pkg_constants.vhd
# utility modules
util := $(wildcard src/util/*.svh) src/util/instruction_tracer_pkg.sv src/util/instruction_tracer_if.sv \
		src/util/generic_fifo.sv src/util/cluster_clock_gating.sv src/util/behav_sram.sv
# Test packages
test_pkg := $(wildcard tb/test/*/*sequence_pkg.sv*) $(wildcard tb/test/*/*_pkg.sv*)
# DPI
dpi := $(patsubst tb/dpi/%.cc,work/%.o,$(wildcard tb/dpi/*.cc))
dpi_hdr := $(wildcard tb/dpi/*.h)
# this list contains the standalone components
src := $(wildcard src/*.sv) $(wildcard tb/common/*.sv) $(wildcard src/axi_slice/*.sv)                                \
       $(wildcard src/axi_node/*.sv) $(wildcard src/axi_mem_if/src/*.sv) src/fpu_legacy/hdl/fpu_utils/fpu_ff.sv      \
       src/fpu_legacy/hdl/fpu_div_sqrt_mvp/defs_div_sqrt_mvp.sv $(wildcard src/fpu_legacy/hdl/fpu_div_sqrt_mvp/*.sv) \
       $(fpnew_pkg) $(wildcard src/fpnew/src/utils/*.vhd) $(wildcard src/fpnew/src/ops/*.vhd)                        \
       $(wildcard src/fpnew/src/subunits/*.vhd) src/fpnew/src/fpnew.vhd src/fpnew/src/fpnew_top.vhd                  \
       $(filter-out src/debug/dm_pkg.sv, $(wildcard src/debug/*.sv)) $(wildcard bootrom/*.sv)                        \
       $(wildcard src/debug/debug_rom/*.sv)

# look for testbenches
tbs := tb/ariane_tb.sv tb/ariane_testharness.sv

# RISCV-tests path
riscv-test-dir := tmp/riscv-tests/build/isa
# there is a defined test-list of CI tests
riscv-ci-tests := $$(xargs printf '\n%s' < ci/test.list | cut -b 1-)
# preset which runs a single test
riscv-test ?= $(riscv-test-dir)/rv64ui-p-add
# failed test directory
failed-tests := $(wildcard failedtests/*.S)
# Search here for include files (e.g.: non-standalone components)
incdir := ./includes
# Compile and sim flags
compile_flag += +cover=bcfst+/dut -incr -64 -nologo -quiet -suppress 13262 -permissive
compile_flag_vhd += -64 -nologo -quiet -2008
uvm-flags += +UVM_NO_RELNOTES
# Iterate over all include directories and write them with +incdir+ prefixed
# +incdir+ works for Verilator and QuestaSim
list_incdir := $(foreach dir, ${incdir}, +incdir+$(dir))

# Build the TB and module using QuestaSim
build: $(library) $(library)/.build-srcs $(library)/.build-tb $(library)/ariane_dpi.so
		# Optimize top level
	vopt$(questa_version) $(compile_flag) -work $(library)  $(test_top_level) -o $(test_top_level)_optimized +acc -check_synthesis

# src files
$(library)/.build-srcs: $(ariane_pkg) $(util) $(src)
	vlog$(questa_version) $(compile_flag) -work $(library) $(filter %.sv,$(ariane_pkg)) $(list_incdir) -suppress 2583
	vlog$(questa_version) $(compile_flag) -work $(library) $(filter %.sv,$(util)) $(list_incdir) -suppress 2583
	# Suppress message that always_latch may not be checked thoroughly by QuestaSim.
	vcom$(questa_version) $(compile_flag_vhd) -work $(library) -pedanticerrors $(filter %.vhd,$(src))
	vlog$(questa_version) $(compile_flag) -work $(library) -pedanticerrors $(filter %.sv,$(src)) $(list_incdir) -suppress 2583
	touch $(library)/.build-srcs

# build TBs
$(library)/.build-tb: $(dpi) $(tbs)
	# Compile top level
	vlog$(questa_version) -sv $(tbs) -work $(library)
	touch $(library)/.build-tb

# compile DPIs
work/%.o: tb/dpi/%.cc $(dpi_hdr)
	$(CXX) -shared -fPIC -std=c++0x -Bsymbolic -I$(QUESTASIM_HOME)/include -o $@ $<

$(library)/ariane_dpi.so: $(dpi)
	# Compile C-code and generate .so file
	g++ -shared -m64 -o $(library)/ariane_dpi.so $? -lfesvr

$(library):
	# Create the library
	vlib${questa_version} ${library}
# +jtag_rbb_enable=1
sim: build $(library)/ariane_dpi.so
	vsim${questa_version} +permissive -64 -lib ${library} +max-cycles=$(max_cycles) +UVM_TESTNAME=${test_case} \
	 +BASEDIR=$(riscv-test-dir) $(uvm-flags) "+UVM_VERBOSITY=HIGH" -coverage -classdebug  +jtag_rbb_enable=1 \
	 -gblso $(RISCV)/lib/libfesvr.so -sv_lib $(library)/ariane_dpi -do " do tb/wave/wave_core.do; run -all; exit" ${top_level}_optimized +permissive-off ++$(riscv-test)

simc: build $(library)/ariane_dpi.so
	vsim${questa_version} +permissive -64 -c -lib ${library} +max-cycles=$(max_cycles) +UVM_TESTNAME=${test_case} \
	 +BASEDIR=$(riscv-test-dir) $(uvm-flags) "+UVM_VERBOSITY=HIGH" -coverage -classdebug +jtag_rbb_enable=1 \
	 -gblso $(RISCV)/lib/libfesvr.so -sv_lib $(library)/ariane_dpi -do " do tb/wave/wave_core.do; run -all; exit" ${top_level}_optimized +permissive-off ++$(riscv-test)

run-asm-tests: build
	$(foreach test, $(riscv-ci-tests), vsim$(questa_version) +permissive -64 +BASEDIR=$(riscv-test-dir) +max-cycles=$(max_cycles) \
		+UVM_TESTNAME=$(test_case) $(uvm-flags) +ASMTEST=$(test) +uvm_set_action="*,_ALL_,UVM_ERROR,UVM_DISPLAY|UVM_STOP" -c \
		-coverage -classdebug  -gblso $(RISCV)/lib/libfesvr.so -sv_lib $(library)/ariane_dpi \
		-do "coverage save -onexit $@.ucdb; run -a; quit -code [coverage attribute -name TESTSTATUS -concise]"  \
		$(library).$(test_top_level)_optimized +permissive-off ++$(test);)

verilate_command := $(verilator)                                                     \
                    $(ariane_pkg)                                                    \
                    tb/ariane_testharness.sv                                         \
                    $(filter-out src/ariane_regfile.sv, $(wildcard src/*.sv))        \
                    $(wildcard src/axi_slice/*.sv)                                   \
                    $(filter-out src/debug/dm_pkg.sv, $(wildcard src/debug/*.sv))    \
                    src/debug/debug_rom/debug_rom.sv                                 \
                    src/util/generic_fifo.sv                                         \
                    tb/common/SimDTM.sv                                              \
                    tb/common/SimJTAG.sv                                             \
                    tb/common/pulp_sync.sv                                           \
                    bootrom/bootrom.sv                                               \
                    src/util/cluster_clock_gating.sv                                 \
                    src/util/behav_sram.sv                                           \
                    src/axi_mem_if/src/axi2mem.sv                                    \
                    +incdir+src/axi_node                                             \
                    --unroll-count 256                                               \
                    -Werror-PINMISSING                                               \
                    -Werror-IMPLICIT                                                 \
                    -Wno-fatal                                                       \
                    -Wno-PINCONNECTEMPTY                                             \
                    -Wno-ASSIGNDLY                                                   \
                    -Wno-DECLFILENAME                                                \
                    -Wno-UNOPTFLAT                                                   \
                    -Wno-UNUSED                                                      \
                    -Wno-ASSIGNDLY                                                   \
                    $(if $(DEBUG),--trace-structs --trace,) \
                    -LDFLAGS "-lfesvr" -CFLAGS "-std=c++11 -I../tb/dpi" -Wall --cc  --vpi  \
                    $(list_incdir) --top-module ariane_testharness \
                    --Mdir build -O3 \
                    --exe tb/ariane_tb.cpp tb/dpi/SimDTM.cc tb/dpi/SimJTAG.cc tb/dpi/remote_bitbang.cc

# User Verilator, at some point in the future this will be auto-generated
verilate:
	$(verilate_command)
	cd build && make -j8 -f Variane_testharness.mk

verify:
	qverify vlog -sv src/csr_regfile.sv

clean:
	rm -rf work/ *.ucdb
	rm -rf build

.PHONY:
	build lint build-moore
