# [MiSTer-DB9 BEGIN] - cps15 timing closure assist
#
# Two pre-existing tight cps15 paths fail STA on Quartus 20.1 / DE10-Nano.
# Upstream jotego/jtcores `mister-pocket` CI hits the same failure (run
# 25274578482 mister-pocket (cps15) FAIL in 1h23m48s, six jtseed retries).
# The fork's added load (joydb*, db9_key_gate + siphash24, USER_PP,
# USER_IO[7] mux) makes the violation slightly worse but is not the root
# cause. Drop this file if upstream lands its own fix (registering
# post_addr in jtcps15_game.v or a generic jtframe SDC would cover both).

# Path family 1: download-time logic -> jtframe_sdram64|sdram_a[*]
#
# jtcps15_game.v post_addr = prog_addr - snd_start_addr + SND_OFFSET is a
# 22-bit Kabuki sound-region remap adder. Its output drives sdram_a[*] only
# during ROM download; gameplay drives sdram_a from main_rom/gfx0/gfx1/qsnd
# directly and the post_addr path is dead silicon. Download fan-in changes
# at HPS-IO rate, far below 96 MHz, so multicycle 2 is comfortable. Trailing
# `*` on each pattern catches Quartus's `~DUPLICATE` register replicas.
set sdram_a_dst [get_keepers {*jtframe_sdram64*|sdram_a[*]}]
foreach src {
    {*jtframe_mister_dwnld*|ddr_dwn*}
    {*jtframe_mister_dwnld*|dump_cnt[*]*}
    {*jtframe_mister_dwnld*|ioctl_rom*}
    {*hps_io*|ioctl_addr[*]*}
    {*jtcps15_game_sdram*|jtframe_dwnld*|prog_addr[*]*}
} {
    set src_keepers [get_keepers $src]
    set_multicycle_path -from $src_keepers -to $sdram_a_dst -setup -end 2
    set_multicycle_path -from $src_keepers -to $sdram_a_dst -hold  -end 1
}

# Path 2: jtframe_rsthold|rst_h (96 MHz) -> jtcps15_sound|rstn (48 MHz)
# Cross-clock reset assertion; deassertion is async and resynchronised
# inside jtcps15_sound, so STA on this edge is not meaningful.
set_false_path -from [get_keepers {*jtframe_rsthold*|rst_h}] \
               -to   [get_keepers {*jtcps15_sound*|rstn}]
# [MiSTer-DB9 END]
