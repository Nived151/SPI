vlib work
vlog tb.v +acc
vlog master.v +acc
vlog slave.v +acc
vsim work.tb
add wave -r *
run -all