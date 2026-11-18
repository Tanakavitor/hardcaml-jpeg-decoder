(* Board-level system: JPEG ROM streamer -> decoder -> 320x240x24 frame buffer -> 640x480
   VGA (each image pixel shown 2x2), plus a self-check checksum, LEDs and 7-seg displays.

   Single 50 MHz clock domain; the VGA side runs on a 25 MHz clock enable and VGA_CLK is
   a register toggling at 25 MHz, phased so RGB/HS/VS change half a pixel before its
   rising edge.

   Checksum (also computed by tools/jpeg_ref.py):
     sum over all pixels of (2*(y*W + x) + 1) * (R | G<<8 | B<<16)   mod 2^32 *)

open! Base
open Hardcaml
open Signal

let rom_addr_bits = 17 (* 128 KiB JPEG ROM *)
let fb_w = 320
let fb_h = 240

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; rom_q : 'a [@bits 8]
    ; sw : 'a [@bits 10]
    ; expected_checksum : 'a [@bits 32]
    ; expected_valid : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { rom_addr : 'a [@bits rom_addr_bits]
    ; rom_en : 'a
    ; vga_r : 'a [@bits 8]
    ; vga_g : 'a [@bits 8]
    ; vga_b : 'a [@bits 8]
    ; vga_hs : 'a
    ; vga_vs : 'a
    ; vga_blank_n : 'a
    ; vga_sync_n : 'a
    ; vga_clk : 'a
    ; ledr : 'a [@bits 10]
    ; hex0 : 'a [@bits 7]
    ; hex1 : 'a [@bits 7]
    ; hex2 : 'a [@bits 7]
    ; hex3 : 'a [@bits 7]
    ; hex4 : 'a [@bits 7]
    ; hex5 : 'a [@bits 7]
    ; (* debug / simulation visibility *)
      checksum : 'a [@bits 32]
    ; done_ok : 'a
    }
  [@@deriving hardcaml]
end

(* 7-segment, active low, bit 0 = segment a *)
let seven_seg digit =
  let patterns =
    [ 0x3F; 0x06; 0x5B; 0x4F; 0x66; 0x6D; 0x7D; 0x07; 0x7F; 0x6F; 0x77; 0x7C; 0x39; 0x5E; 0x79; 0x71 ]
  in
  ~:(mux digit (List.map patterns ~f:(of_int ~width:7)))
;;

let create scope (i : _ I.t) =
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let r ?enable d = reg spec ?enable d in
  (* ---- start pulse on the first cycle after reset ---- *)
  let started = reg_fb spec ~width:1 ~f:(fun _ -> vdd) in
  let start = ~:started in
  (* ---- ROM streamer: 1-entry prefetch in front of a synchronous ROM ---- *)
  let in_ready = wire 1 in
  let q_valid = wire 1 in
  let fetch = ~:q_valid |: in_ready in
  let rom_addr = reg_fb spec ~enable:fetch ~width:rom_addr_bits ~f:(fun a -> a +:. 1) in
  q_valid <== r ~enable:fetch vdd;
  let dec =
    Decoder.create
      scope
      { Decoder.I.clock = i.clock
      ; clear = i.clear
      ; start
      ; in_data = i.rom_q
      ; in_valid = q_valid
      }
  in
  in_ready <== dec.in_ready;
  (* ---- frame buffer write ---- *)
  let in_fb = dec.pix_x <:. fb_w &: (dec.pix_y <:. fb_h) in
  let fb_addr_bits = 17 in
  let fb_waddr =
    let y = uresize dec.pix_y fb_addr_bits in
    sll y 8 +: sll y 6 +: uresize dec.pix_x fb_addr_bits
  in
  (* ---- VGA timing (640x480 @ 60 Hz, 25 MHz pixel enable) ---- *)
  let pix_en = reg_fb spec ~width:1 ~f:( ~: ) in
  let vga_clk = reg_fb spec ~width:1 ~f:( ~: ) in
  let hcnt = wire 10 in
  let vcnt = wire 10 in
  let h_end = hcnt ==:. 799 in
  let v_end = vcnt ==:. 524 in
  hcnt <== r ~enable:pix_en (mux2 h_end (zero 10) (hcnt +:. 1));
  vcnt <== r ~enable:(pix_en &: h_end) (mux2 v_end (zero 10) (vcnt +:. 1));
  let active = hcnt <:. 640 &: (vcnt <:. 480) in
  let hs = ~:(hcnt >=:. 656 &: (hcnt <:. 752)) in
  let vs = ~:(vcnt >=:. 490 &: (vcnt <:. 492)) in
  let fx = srl hcnt 1 in
  let fy = srl vcnt 1 in
  let show_w = mux2 (dec.width <:. fb_w) dec.width (of_int ~width:16 fb_w) in
  let show_h = mux2 (dec.height <:. fb_h) dec.height (of_int ~width:16 fb_h) in
  let in_image = uresize fx 16 <: show_w &: (uresize fy 16 <: show_h) in
  let fb_raddr =
    let y = uresize fy fb_addr_bits in
    sll y 8 +: sll y 6 +: uresize fx fb_addr_bits
  in
  let fb_q =
    (Ram.create
       ~name:"framebuffer"
       ~collision_mode:Read_before_write
       ~size:(fb_w * fb_h)
       ~write_ports:
         [| { write_clock = i.clock
            ; write_address = fb_waddr
            ; write_enable = dec.pix_valid &: in_fb
            ; write_data = concat_msb [ dec.pix_b; dec.pix_g; dec.pix_r ]
            }
         |]
       ~read_ports:
         [| { read_clock = i.clock; read_address = fb_raddr; read_enable = pix_en } |]
       ()).(0)
  in
  (* stage 1 (aligned with the RAM read) and stage 2 (output registers) *)
  let active1 = r ~enable:pix_en active in
  let show1 = r ~enable:pix_en (active &: in_image) in
  let hs1 = r ~enable:pix_en hs in
  let vs1 = r ~enable:pix_en vs in
  let rgb = mux2 show1 fb_q (zero 24) in
  let vga_r = r ~enable:pix_en (select rgb 7 0) in
  let vga_g = r ~enable:pix_en (select rgb 15 8) in
  let vga_b = r ~enable:pix_en (select rgb 23 16) in
  let vga_hs = r ~enable:pix_en hs1 in
  let vga_vs = r ~enable:pix_en vs1 in
  let vga_blank_n = r ~enable:pix_en active1 in
  (* ---- checksum over the decoded pixel stream ---- *)
  let pix24 = concat_msb [ dec.pix_b; dec.pix_g; dec.pix_r ] in
  let c1_valid = r dec.pix_valid in
  let c1_idx = r (uresize (dec.pix_y *: dec.width) 32 +: uresize dec.pix_x 32) in
  let c1_pix = r pix24 in
  let c2_valid = r c1_valid in
  let odd = concat_msb [ select c1_idx 30 0; vdd ] in
  let c2_term = r (uresize (odd *: c1_pix) 32) in
  let checksum =
    reg_fb spec ~enable:c2_valid ~width:32 ~f:(fun acc -> acc +: c2_term)
  in
  (* the core asserts finished after its own pipeline drained; wait for ours too *)
  let finished = pipeline spec ~n:4 dec.finished &: dec.finished in
  let match_ = finished &: i.expected_valid &: (checksum ==: i.expected_checksum) in
  let mismatch = finished &: i.expected_valid &: (checksum <>: i.expected_checksum) in
  (* ---- decode time in microseconds ---- *)
  let us_tick = wire 1 in
  let prescale =
    reg_fb spec ~enable:dec.busy ~width:6 ~f:(fun p -> mux2 (p ==:. 49) (zero 6) (p +:. 1))
  in
  us_tick <== (dec.busy &: (prescale ==:. 49));
  let decode_us = reg_fb spec ~enable:us_tick ~width:24 ~f:(fun t -> t +:. 1) in
  (* ---- LEDs ---- *)
  let heartbeat = reg_fb spec ~width:26 ~f:(fun t -> t +:. 1) in
  let ledr =
    concat_msb
      [ msb heartbeat
      ; dec.busy
      ; dec.error_code
      ; dec.error
      ; mismatch
      ; match_
      ; finished
      ]
  in
  (* ---- 7-segment: SW3 decode time (us), SW2 width/height, else checksum;
     SW1 selects the expected checksum, SW0 the top byte ---- *)
  let sw = i.sw in
  let cs_sel = mux2 (bit sw 1) i.expected_checksum checksum in
  let cs_view =
    mux2 (bit sw 0) (concat_msb [ zero 16; select cs_sel 31 24 ]) (select cs_sel 23 0)
  in
  let size_view = concat_msb [ select dec.width 11 0; select dec.height 11 0 ] in
  let view = mux2 (bit sw 3) decode_us (mux2 (bit sw 2) size_view cs_view) in
  let blank_top = ~:(bit sw 3) &: ~:(bit sw 2) &: bit sw 0 in
  let digit n =
    let seg = seven_seg (select view ((4 * n) + 3) (4 * n)) in
    if n >= 2 then mux2 blank_top (ones 7) seg else seg
  in
  { O.rom_addr
  ; rom_en = fetch
  ; vga_r
  ; vga_g
  ; vga_b
  ; vga_hs
  ; vga_vs
  ; vga_blank_n
  ; vga_sync_n = gnd
  ; vga_clk
  ; ledr = r ledr
  ; hex0 = r (digit 0)
  ; hex1 = r (digit 1)
  ; hex2 = r (digit 2)
  ; hex3 = r (digit 3)
  ; hex4 = r (digit 4)
  ; hex5 = r (digit 5)
  ; checksum
  ; done_ok = finished
  }
;;
