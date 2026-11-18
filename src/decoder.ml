(* Baseline JPEG decoder core.

   Supported: SOF0/SOF1 (8-bit Huffman, sequential), 1 component (grayscale) or
   3 components (YCbCr) in one interleaved scan, luma sampling 1x1 / 2x1 / 1x2 / 2x2 with
   1x1 chroma (4:4:4, 4:2:2, 4:4:0, 4:2:0), 8- and 16-bit quantisation tables, up to 4 DC
   and 4 AC Huffman tables, restart intervals (DRI / RSTn), any image size up to 65535.
   Not supported: progressive, arithmetic coding, 12-bit, lossless, multi-scan files.

   Output pixels are bit-exact with libjpeg-turbo "djpeg -dct int -nosmooth"
   (accurate integer IDCT, box upsampling of chroma).

   Byte input is a ready/valid stream. Pixels come out one per cycle at most, in MCU
   order, with their (x, y) coordinate; there is no output back-pressure. *)

open! Base
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; start : 'a
    ; in_data : 'a [@bits 8]
    ; in_valid : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { in_ready : 'a
    ; pix_valid : 'a
    ; pix_x : 'a [@bits 16]
    ; pix_y : 'a [@bits 16]
    ; pix_r : 'a [@bits 8]
    ; pix_g : 'a [@bits 8]
    ; pix_b : 'a [@bits 8]
    ; width : 'a [@bits 16]
    ; height : 'a [@bits 16]
    ; busy : 'a
    ; finished : 'a
    ; error : 'a
    ; error_code : 'a [@bits 4]
    }
  [@@deriving hardcaml]
end

module State = struct
  type t =
    | Idle
    | Soi1
    | Soi2
    | Find_ff
    | Marker
    | Dispatch
    | Len_hi
    | Len_lo
    | Skip
    | Sof
    | Sof_check
    | Dht_hdr
    | Dht_bits
    | Dht_vals
    | Dqt_hdr
    | Dqt_val
    | Dri
    | Sos
    | Sos_check
    | Mcu_start
    | Block_start
    | H_decode
    | H_consume
    | H_symbol
    | Extra
    | Write
    | Idct_start
    | Idct_wait
    | Next_block
    | Color
    | Color_drain
    | Mcu_done
    | Restart
    | Scan_done
    | Finished
    | Error
  [@@deriving sexp_of, compare, enumerate]
end

module Err = struct
  let unsupported_sof = 1 (* progressive / lossless / arithmetic *)
  let precision = 2 (* not 8-bit *)
  let components = 3 (* not 1 or 3 components *)
  let sampling = 4 (* unsupported sampling factors *)
  let scan = 5 (* scan does not cover all components (multi-scan file) *)
  let huff_code = 6 (* invalid Huffman code in the data *)
  let dht = 8 (* malformed DHT *)
  let dqt = 9 (* malformed DQT *)
  let seg_len = 10 (* segment length < 2 *)
  let dimensions = 11 (* zero width/height (DNL not supported) *)
  let not_jpeg = 12 (* the stream does not start with SOI (FF D8) *)
end

let zigzag_to_natural =
  [| 0; 1; 8; 16; 9; 2; 3; 10; 17; 24; 32; 25; 18; 11; 4; 5; 12; 19; 26; 33; 40; 48
   ; 41; 34; 27; 20; 13; 6; 7; 14; 21; 28; 35; 42; 49; 56; 57; 50; 43; 36; 29; 22
   ; 15; 23; 30; 37; 44; 51; 58; 59; 52; 45; 38; 31; 39; 46; 53; 60; 61; 54; 47; 55
   ; 62; 63
  |]
;;

let ram ~clock ~size ~we ~waddr ~wdata ~re ~raddr =
  (Ram.create
     ~collision_mode:Read_before_write
     ~size
     ~write_ports:
       [| { write_clock = clock
          ; write_address = waddr
          ; write_enable = we
          ; write_data = wdata
          }
       |]
     ~read_ports:[| { read_clock = clock; read_address = raddr; read_enable = re } |]
     ()).(0)
;;

let create (_scope : Scope.t) (i : _ I.t) =
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let open Always in
  let reg_v w = Variable.reg ~width:w spec in
  let wire_v w = Variable.wire ~default:(zero w) in
  let sm = State_machine.create (module State) spec in
  let vals a = Array.to_list (Array.map a ~f:(fun (v : Variable.t) -> v.value)) in
  (* ---- header / frame state ---- *)
  let marker = reg_v 8 in
  let len_hi = reg_v 8 in
  let seg_rem = reg_v 16 in
  let precision = reg_v 8 in
  let height = reg_v 16 in
  let width = reg_v 16 in
  let nf = reg_v 8 in
  let comp_id = Array.init 3 ~f:(fun _ -> reg_v 8) in
  let comp_h = Array.init 3 ~f:(fun _ -> reg_v 4) in
  let comp_v = Array.init 3 ~f:(fun _ -> reg_v 4) in
  let comp_tq = Array.init 3 ~f:(fun _ -> reg_v 2) in
  let sof_idx = reg_v 3 in
  let sof_ci = reg_v 2 in
  let sof_cf = reg_v 2 in
  let sof_seen = reg_v 1 in
  let is3 = reg_v 1 in
  let h2 = reg_v 1 in
  let v2 = reg_v 1 in
  let mcus_x = reg_v 13 in
  let mcus_y = reg_v 13 in
  let dht_t = reg_v 3 in
  let dht_l = reg_v 4 in
  let dht_code = reg_v 17 in
  let dht_k = reg_v 9 in
  let dht_n = reg_v 9 in
  let dqt_t = reg_v 2 in
  let dqt_pq = reg_v 1 in
  let dqt_k = reg_v 6 in
  let dqt_phase = reg_v 1 in
  let dqt_hi = reg_v 8 in
  let ri = reg_v 16 in
  let rst_left = reg_v 16 in
  let ns = reg_v 8 in
  let sos_phase = reg_v 2 in
  let sos_ci = reg_v 2 in
  let sos_cf = reg_v 1 in
  let sos_bad = reg_v 1 in
  let sc_fc = Array.init 3 ~f:(fun _ -> reg_v 2) in
  let sc_td = Array.init 3 ~f:(fun _ -> reg_v 2) in
  let sc_ta = Array.init 3 ~f:(fun _ -> reg_v 2) in
  let sc_ok = Array.init 3 ~f:(fun _ -> reg_v 1) in
  (* ---- entropy decoder state ---- *)
  let bb = reg_v 32 in
  let bcnt = reg_v 6 in
  let saw_ff = reg_v 1 in
  let marker_hit = reg_v 1 in
  let in_scan = reg_v 1 in
  let j = reg_v 2 in
  let bh = reg_v 1 in
  let bv = reg_v 1 in
  let k = reg_v 7 in
  let hl = reg_v 5 in
  let hidx = reg_v 8 in
  let s = reg_v 4 in
  let knew = reg_v 7 in
  let coef_val = reg_v 16 in
  let pred = Array.init 3 ~f:(fun _ -> reg_v 16) in
  let mcu_x = reg_v 13 in
  let mcu_y = reg_v 13 in
  let base_x = reg_v 16 in
  let base_y = reg_v 16 in
  let px = reg_v 4 in
  let py = reg_v 4 in
  let drain = reg_v 2 in
  let err_code = reg_v 4 in
  (* ---- control wires ---- *)
  let cons = wire_v 6 in
  let coef_clear = wire_v 1 in
  let coef_we = wire_v 1 in
  let huff_rd = wire_v 1 in
  let quant_rd = wire_v 1 in
  let quant_rd_k = wire_v 6 in
  let idct_start = wire_v 1 in
  let color_issue = wire_v 1 in
  let dht_we = wire_v 1 in
  let huffval_we = wire_v 1 in
  let quant_we = wire_v 1 in
  let quant_wdata = wire_v 16 in
  let byte = i.in_data in
  (* ---- input handshake ---- *)
  let header_ready =
    reduce
      ~f:( |: )
      (List.map
         State.
           [ Soi1
           ; Soi2
           ; Find_ff
           ; Marker
           ; Len_hi
           ; Len_lo
           ; Skip
           ; Sof
           ; Dht_hdr
           ; Dht_bits
           ; Dht_vals
           ; Dqt_hdr
           ; Dqt_val
           ; Dri
           ; Sos
           ]
         ~f:sm.is)
  in
  let fill_ready =
    in_scan.value
    &: ~:(marker_hit.value)
    &: (bcnt.value <=:. 24)
    &: ~:(sm.is Scan_done)
  in
  let in_ready = header_ready |: fill_ready in
  let fill_fire = fill_ready &: i.in_valid in
  (* ---- bit buffer: left aligned, bb[31] is the next bit; bits below the valid count
     are always zero, so after a marker the decoder reads zeros (like libjpeg) ---- *)
  let is_ff = byte ==:. 0xff in
  let is_00 = byte ==:. 0 in
  let c_after = mux2 (cons.value >: bcnt.value) (zero 6) (bcnt.value -: cons.value) in
  let bb_shift = log_shift sll bb.value cons.value in
  let insert = fill_fire &: (saw_ff.value &: is_00 |: (~:(saw_ff.value) &: ~:is_ff)) in
  let ins_byte = mux2 saw_ff.value (of_int ~width:8 0xff) byte in
  let ins_pos = of_int ~width:6 24 -: c_after in
  let ins = log_shift sll (uresize ins_byte 32) ins_pos in
  let bb_next = bb_shift |: mux2 insert ins (zero 32) in
  let bcnt_next = c_after +: mux2 insert (of_int ~width:6 8) (zero 6) in
  let saw_ff_next = mux2 fill_fire is_ff saw_ff.value in
  let marker_found = fill_fire &: saw_ff.value &: ~:is_ff &: ~:is_00 in
  (* ---- Huffman tables: for each table and code length L, store
     maxp1 = (last code of length L) + 1 and delta = valptr - mincode (mod 256).
     The decoded length is the smallest L with code_L < maxp1[L]. ---- *)
  let dht_maxp1_d = dht_code.value +: uresize byte 17 in
  let dht_delta_d = select dht_k.value 7 0 -: select dht_code.value 7 0 in
  let table_reg d t l =
    let we = dht_we.value &: (dht_t.value ==:. t) &: (dht_l.value ==:. l) in
    reg spec ~enable:we d
  in
  let maxp1 = Array.init 8 ~f:(fun t -> Array.init 16 ~f:(fun l -> table_reg dht_maxp1_d t l)) in
  let delta = Array.init 8 ~f:(fun t -> Array.init 16 ~f:(fun l -> table_reg dht_delta_d t l)) in
  let cur_fc = mux j.value (vals sc_fc) in
  let cur_td = mux j.value (vals sc_td) in
  let cur_ta = mux j.value (vals sc_ta) in
  let cur_qt = mux cur_fc (vals comp_tq) in
  let cur_pred = mux j.value (vals pred) in
  let k_is0 = k.value ==:. 0 in
  let tsel = mux2 k_is0 (concat_msb [ gnd; cur_td ]) (concat_msb [ vdd; cur_ta ]) in
  let decode_cands =
    List.init 16 ~f:(fun li ->
      let l = li + 1 in
      let code = select bb.value 31 (32 - l) in
      let mp = mux tsel (List.init 8 ~f:(fun t -> maxp1.(t).(li))) in
      let dl = mux tsel (List.init 8 ~f:(fun t -> delta.(t).(li))) in
      { Comb.valid = uresize code 17 <: mp
      ; value = concat_msb [ of_int ~width:5 l; uresize code 8 +: dl ]
      })
  in
  let dec = priority_select decode_cands in
  let dec_len = select dec.value 12 8 in
  let dec_idx = select dec.value 7 0 in
  (* ---- table memories ---- *)
  let huff_q =
    ram
      ~clock:i.clock
      ~size:2048
      ~we:huffval_we.value
      ~waddr:(concat_msb [ dht_t.value; select dht_n.value 7 0 ])
      ~wdata:byte
      ~re:huff_rd.value
      ~raddr:(concat_msb [ tsel; hidx.value ])
  in
  let quant_q =
    ram
      ~clock:i.clock
      ~size:256
      ~we:quant_we.value
      ~waddr:(concat_msb [ dqt_t.value; dqt_k.value ])
      ~wdata:quant_wdata.value
      ~re:quant_rd.value
      ~raddr:(concat_msb [ cur_qt; quant_rd_k.value ])
  in
  (* ---- magnitude bits (HUFF_EXTEND) ---- *)
  let top16 = select bb.value 31 16 in
  let shamt = of_int ~width:5 16 -: uresize s.value 5 in
  let v = uresize (log_shift srl top16 shamt) 17 in
  let pow_s = log_shift sll (of_int ~width:17 1) s.value in
  let msb_set = v &: srl pow_s 1 <>:. 0 in
  let ext = mux2 (s.value ==:. 0) (zero 17) (mux2 msb_set v (v -: pow_s +:. 1)) in
  let ext16 = select ext 15 0 in
  let dc_val = cur_pred +: ext16 in
  let coef_new = mux2 k_is0 dc_val ext16 in
  let sat63 x = mux2 (x >=:. 64) (of_int ~width:6 63) (select x 5 0) in
  (* ---- coefficient block (dequantised, natural order) ---- *)
  let coef_prod = select (coef_val.value *+ uresize quant_q 17) 31 0 in
  let zz = List.map (Array.to_list zigzag_to_natural) ~f:(of_int ~width:6) in
  let coef_addr = mux (sat63 knew.value) zz in
  let coef =
    Array.init 64 ~f:(fun n ->
      reg
        spec
        ~enable:(coef_clear.value |: (coef_we.value &: (coef_addr ==:. n)))
        (mux2 coef_clear.value (zero 32) coef_prod))
  in
  let idct = Idct.create spec ~start:idct_start.value ~coef in
  (* ---- MCU sample buffers: Y is 16x16 (two 8-sample words per row), Cb/Cr 8x8 ---- *)
  let cx = mux2 h2.value (srl px.value 1) px.value in
  let cy = mux2 v2.value (srl py.value 1) py.value in
  let y_q =
    ram
      ~clock:i.clock
      ~size:32
      ~we:(idct.row_we &: (cur_fc ==:. 0))
      ~waddr:(concat_msb [ bv.value; idct.row_idx; bh.value ])
      ~wdata:idct.row_data
      ~re:color_issue.value
      ~raddr:(concat_msb [ py.value; bit px.value 3 ])
  in
  let c_ram sel =
    ram
      ~clock:i.clock
      ~size:8
      ~we:(idct.row_we &: (cur_fc ==:. sel))
      ~waddr:idct.row_idx
      ~wdata:idct.row_data
      ~re:color_issue.value
      ~raddr:(select cy 2 0)
  in
  let cb_q = c_ram 1 in
  let cr_q = c_ram 2 in
  (* ---- colour conversion pipeline (jdcolor.c / jdmerge.c tables, SCALEBITS = 16) ---- *)
  let pix_xc = base_x.value +: uresize px.value 16 in
  let pix_yc = base_y.value +: uresize py.value 16 in
  let inside = pix_xc <: width.value &: (pix_yc <: height.value) in
  let r s = reg spec s in
  let v1 = r (color_issue.value &: inside) in
  let x1 = r pix_xc in
  let y1 = r pix_yc in
  let yb1 = r (select px.value 2 0) in
  let cb1 = r (select cx 2 0) in
  let byte_of word sel = mux sel (List.init 8 ~f:(fun n -> select word ((8 * n) + 7) (8 * n))) in
  let yv = byte_of y_q yb1 in
  let cbx = uresize (byte_of cb_q cb1) 9 -:. 128 in
  let crx = uresize (byte_of cr_q cb1) 9 -:. 128 in
  let mulk x c = x *+ of_int ~width:18 c in
  let r_t = mulk crx 91881 in
  let b_t = mulk cbx 116130 in
  let g_t = zero 27 -: (mulk cbx 22554 +: mulk crx 46802) in
  let v2r = r v1 in
  let x2 = r x1 in
  let y2 = r y1 in
  let yv2 = r yv in
  let r_t2 = r r_t in
  let g_t2 = r g_t in
  let b_t2 = r b_t in
  let descale t = select (sresize t 28 +: of_int ~width:28 32768) 27 16 in
  let add_clamp yy c =
    let sum = uresize yy 13 +: sresize c 13 in
    mux2 (msb sum) (zero 8) (mux2 (select sum 11 8 <>:. 0) (ones 8) (select sum 7 0))
  in
  let gray = ~:(is3.value) in
  let red = mux2 gray yv2 (add_clamp yv2 (descale r_t2)) in
  let green = mux2 gray yv2 (add_clamp yv2 (descale g_t2)) in
  let blue = mux2 gray yv2 (add_clamp yv2 (descale b_t2)) in
  (* ---- FSM helpers ---- *)
  let last = seg_rem.value ==:. 1 in
  let seg_dec = seg_rem <-- seg_rem.value -:. 1 in
  let goto_error code = [ err_code <--. code; sm.set_next Error ] in
  let is_marker m = marker.value ==:. m in
  let is_sof_ok = is_marker 0xc0 |: is_marker 0xc1 in
  let is_sof_bad =
    List.fold
      [ 0xc2; 0xc3; 0xc5; 0xc6; 0xc7; 0xc9; 0xca; 0xcb; 0xcd; 0xce; 0xcf ]
      ~init:gnd
      ~f:(fun acc m -> acc |: is_marker m)
  in
  let is_rst = select marker.value 7 3 ==:. 0b11010 in
  let seg_end_target =
    [ if_
        is_sof_ok
        [ sm.set_next Sof_check ]
        [ if_ (is_marker 0xda) [ sm.set_next Sos_check ] [ sm.set_next Find_ff ] ]
    ]
  in
  let start_actions =
    [ sof_seen <--. 0
    ; ri <--. 0
    ; in_scan <--. 0
    ; marker_hit <--. 0
    ; err_code <--. 0
    ; sm.set_next Soi1
    ]
  in
  let per_comp n f = List.init n ~f in
  (* SOF check values *)
  let h0 = comp_h.(0).value in
  let v0 = comp_v.(0).value in
  let nf_is1 = nf.value ==:. 1 in
  let nf_is3 = nf.value ==:. 3 in
  let hv12 x = x ==:. 1 |: (x ==:. 2) in
  let ok_samp =
    nf_is1
    |: (hv12 h0
        &: hv12 v0
        &: (comp_h.(1).value ==:. 1)
        &: (comp_v.(1).value ==:. 1)
        &: (comp_h.(2).value ==:. 1)
        &: (comp_v.(2).value ==:. 1))
  in
  let h2n = nf_is3 &: (h0 ==:. 2) in
  let v2n = nf_is3 &: (v0 ==:. 2) in
  let blocks_of d is2 =
    let d17 = uresize d 17 in
    uresize (mux2 is2 (srl (d17 +:. 15) 4) (srl (d17 +:. 7) 3)) 13
  in
  (* SOS matching *)
  let sos_match =
    Array.init 3 ~f:(fun c ->
      comp_id.(c).value ==: byte &: if c = 0 then vdd else is3.value)
  in
  let fc_match =
    mux2 sos_match.(0) (of_int ~width:2 0) (mux2 sos_match.(1) (of_int ~width:2 1) (of_int ~width:2 2))
  in
  let any_match = sos_match.(0) |: sos_match.(1) |: sos_match.(2) in
  let fc0 = sc_fc.(0).value in
  let fc1 = sc_fc.(1).value in
  let fc2 = sc_fc.(2).value in
  let ok_comps =
    mux2
      is3.value
      (sc_ok.(0).value
       &: sc_ok.(1).value
       &: sc_ok.(2).value
       &: (fc0 <>: fc1)
       &: (fc0 <>: fc2)
       &: (fc1 <>: fc2))
      sc_ok.(0).value
  in
  (* entropy helpers *)
  let rs = huff_q in
  let run = select rs 7 4 in
  let sz = select rs 3 0 in
  let k_plus_run = k.value +: uresize run 7 in
  let k16 = k.value +:. 16 in
  let ycomp = is3.value &: (cur_fc ==:. 0) in
  let bh_last = bh.value |: ~:(ycomp &: h2.value) in
  let bv_last = bv.value |: ~:(ycomp &: v2.value) in
  let j_last = uresize j.value 8 +:. 1 ==: ns.value in
  let px_last = px.value ==: mux2 h2.value (of_int ~width:4 15) (of_int ~width:4 7) in
  let py_last = py.value ==: mux2 v2.value (of_int ~width:4 15) (of_int ~width:4 7) in
  let mcu_w = mux2 h2.value (of_int ~width:16 16) (of_int ~width:16 8) in
  let mcu_h = mux2 v2.value (of_int ~width:16 16) (of_int ~width:16 8) in
  let x_last = mcu_x.value ==: mcus_x.value -:. 1 in
  let y_last = mcu_y.value ==: mcus_y.value -:. 1 in
  let clear_preds = per_comp 3 (fun c -> pred.(c) <--. 0) in
  compile
    [ (* bit-buffer refill runs in the background during a scan *)
      when_
        in_scan.value
        [ bb <-- bb_next
        ; bcnt <-- bcnt_next
        ; saw_ff <-- saw_ff_next
        ; when_ marker_found [ marker_hit <-- vdd; marker <-- byte ]
        ]
    ; sm.switch
        [ Idle, [ when_ i.start start_actions ]
        ; ( Soi1
          , [ when_ i.in_valid [ if_ is_ff [ sm.set_next Soi2 ] (goto_error Err.not_jpeg) ] ] )
        ; ( Soi2
          , [ when_
                i.in_valid
                [ if_ (byte ==:. 0xd8) [ sm.set_next Find_ff ] (goto_error Err.not_jpeg) ]
            ] )
        ; Find_ff, [ when_ i.in_valid [ when_ is_ff [ sm.set_next Marker ] ] ]
        ; Marker, [ when_ i.in_valid [ unless is_ff [ marker <-- byte; sm.set_next Dispatch ] ] ]
        ; ( Dispatch
          , [ if_
                (is_marker 0xd8)
                [ sm.set_next Find_ff ]
                [ if_
                    (is_marker 0xd9)
                    [ sm.set_next Finished ]
                    [ if_
                        is_sof_bad
                        (goto_error Err.unsupported_sof)
                        [ if_
                            (is_rst |: is_marker 0x01)
                            [ sm.set_next Find_ff ]
                            [ sm.set_next Len_hi ]
                        ]
                    ]
                ]
            ] )
        ; Len_hi, [ when_ i.in_valid [ len_hi <-- byte; sm.set_next Len_lo ] ]
        ; ( Len_lo
          , let len = concat_msb [ len_hi.value; byte ] in
            [ when_
                i.in_valid
                [ seg_rem <-- len -:. 2
                ; if_
                    (len <:. 2)
                    (goto_error Err.seg_len)
                    [ if_
                        (len ==:. 2)
                        seg_end_target
                        [ if_
                            is_sof_ok
                            [ sof_idx <--. 0; sof_ci <--. 0; sof_cf <--. 0; sm.set_next Sof ]
                            [ if_
                                (is_marker 0xc4)
                                [ sm.set_next Dht_hdr ]
                                [ if_
                                    (is_marker 0xdb)
                                    [ sm.set_next Dqt_hdr ]
                                    [ if_
                                        (is_marker 0xda)
                                        ([ sos_phase <--. 0
                                         ; sos_ci <--. 0
                                         ; sos_cf <--. 0
                                         ; sos_bad <--. 0
                                         ; sm.set_next Sos
                                         ]
                                         @ per_comp 3 (fun c -> sc_ok.(c) <--. 0))
                                        [ if_
                                            (is_marker 0xdd)
                                            [ sm.set_next Dri ]
                                            [ sm.set_next Skip ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ] )
        ; Skip, [ when_ i.in_valid [ seg_dec; when_ last [ sm.set_next Find_ff ] ] ]
        ; ( Sof
          , [ when_
                i.in_valid
                [ seg_dec
                ; if_
                    (sof_idx.value <:. 6)
                    [ sof_idx <-- sof_idx.value +:. 1
                    ; when_ (sof_idx.value ==:. 0) [ precision <-- byte ]
                    ; when_
                        (sof_idx.value ==:. 1 |: (sof_idx.value ==:. 2))
                        [ height <-- concat_msb [ select height.value 7 0; byte ] ]
                    ; when_
                        (sof_idx.value ==:. 3 |: (sof_idx.value ==:. 4))
                        [ width <-- concat_msb [ select width.value 7 0; byte ] ]
                    ; when_ (sof_idx.value ==:. 5) [ nf <-- byte ]
                    ]
                    [ proc
                        (per_comp 3 (fun c ->
                           when_
                             (sof_ci.value ==:. c)
                             [ when_ (sof_cf.value ==:. 0) [ comp_id.(c) <-- byte ]
                             ; when_
                                 (sof_cf.value ==:. 1)
                                 [ comp_h.(c) <-- select byte 7 4
                                 ; comp_v.(c) <-- select byte 3 0
                                 ]
                             ; when_ (sof_cf.value ==:. 2) [ comp_tq.(c) <-- select byte 1 0 ]
                             ]))
                    ; if_
                        (sof_cf.value ==:. 2)
                        [ sof_cf <--. 0
                        ; when_ (sof_ci.value <:. 3) [ sof_ci <-- sof_ci.value +:. 1 ]
                        ]
                        [ sof_cf <-- sof_cf.value +:. 1 ]
                    ]
                ; when_ last [ sm.set_next Sof_check ]
                ]
            ] )
        ; ( Sof_check
          , [ if_
                (precision.value <>:. 8)
                (goto_error Err.precision)
                [ if_
                    ~:(nf_is1 |: nf_is3)
                    (goto_error Err.components)
                    [ if_
                        ~:ok_samp
                        (goto_error Err.sampling)
                        [ if_
                            (width.value ==:. 0 |: (height.value ==:. 0))
                            (goto_error Err.dimensions)
                            [ sof_seen <--. 1
                            ; is3 <-- nf_is3
                            ; h2 <-- h2n
                            ; v2 <-- v2n
                            ; mcus_x <-- blocks_of width.value h2n
                            ; mcus_y <-- blocks_of height.value v2n
                            ; sm.set_next Find_ff
                            ]
                        ]
                    ]
                ]
            ] )
        ; ( Dht_hdr
          , [ when_
                i.in_valid
                [ seg_dec
                ; dht_t <-- concat_msb [ bit byte 4; select byte 1 0 ]
                ; dht_l <--. 0
                ; dht_code <--. 0
                ; dht_k <--. 0
                ; if_
                    (select byte 7 5 <>:. 0 |: (select byte 3 2 <>:. 0) |: last)
                    (goto_error Err.dht)
                    [ sm.set_next Dht_bits ]
                ]
            ] )
        ; ( Dht_bits
          , let newk = dht_k.value +: uresize byte 9 in
            [ when_
                i.in_valid
                [ seg_dec
                ; dht_we <-- vdd
                ; dht_code <-- sll (dht_code.value +: uresize byte 17) 1
                ; dht_k <-- newk
                ; dht_l <-- dht_l.value +:. 1
                ; if_
                    (dht_l.value ==:. 15)
                    [ dht_n <--. 0
                    ; if_
                        (newk >:. 256)
                        (goto_error Err.dht)
                        [ if_
                            (newk ==:. 0)
                            [ if_ last [ sm.set_next Find_ff ] [ sm.set_next Dht_hdr ] ]
                            [ if_ last (goto_error Err.dht) [ sm.set_next Dht_vals ] ]
                        ]
                    ]
                    [ when_ last (goto_error Err.dht) ]
                ]
            ] )
        ; ( Dht_vals
          , [ when_
                i.in_valid
                [ seg_dec
                ; huffval_we <-- vdd
                ; dht_n <-- dht_n.value +:. 1
                ; if_
                    (dht_n.value +:. 1 ==: dht_k.value)
                    [ if_ last [ sm.set_next Find_ff ] [ sm.set_next Dht_hdr ] ]
                    [ when_ last [ sm.set_next Find_ff ] ]
                ]
            ] )
        ; ( Dqt_hdr
          , [ when_
                i.in_valid
                [ seg_dec
                ; dqt_pq <-- bit byte 4
                ; dqt_t <-- select byte 1 0
                ; dqt_k <--. 0
                ; dqt_phase <--. 0
                ; if_
                    (select byte 7 5 <>:. 0 |: (select byte 3 2 <>:. 0) |: last)
                    (goto_error Err.dqt)
                    [ sm.set_next Dqt_val ]
                ]
            ] )
        ; ( Dqt_val
          , [ when_
                i.in_valid
                [ seg_dec
                ; if_
                    (~:(dqt_pq.value) |: dqt_phase.value)
                    [ quant_we <-- vdd
                    ; quant_wdata
                      <-- mux2 dqt_pq.value (concat_msb [ dqt_hi.value; byte ]) (uresize byte 16)
                    ; dqt_k <-- dqt_k.value +:. 1
                    ; dqt_phase <--. 0
                    ; if_
                        (dqt_k.value ==:. 63)
                        [ if_ last [ sm.set_next Find_ff ] [ sm.set_next Dqt_hdr ] ]
                        [ when_ last [ sm.set_next Find_ff ] ]
                    ]
                    [ dqt_hi <-- byte; dqt_phase <--. 1; when_ last [ sm.set_next Find_ff ] ]
                ]
            ] )
        ; ( Dri
          , [ when_
                i.in_valid
                [ seg_dec
                ; ri <-- concat_msb [ select ri.value 7 0; byte ]
                ; when_ last [ sm.set_next Find_ff ]
                ]
            ] )
        ; ( Sos
          , [ when_
                i.in_valid
                [ seg_dec
                ; when_
                    (sos_phase.value ==:. 0)
                    [ ns <-- byte
                    ; sos_ci <--. 0
                    ; sos_cf <--. 0
                    ; sos_phase <-- mux2 (byte ==:. 0) (of_int ~width:2 2) (of_int ~width:2 1)
                    ]
                ; when_
                    (sos_phase.value ==:. 1)
                    [ if_
                        (sos_cf.value ==:. 0)
                        (per_comp 3 (fun c ->
                           when_
                             (sos_ci.value ==:. c)
                             [ sc_fc.(c) <-- fc_match; sc_ok.(c) <-- any_match ])
                         @ [ sos_cf <--. 1 ])
                        (per_comp 3 (fun c ->
                           when_
                             (sos_ci.value ==:. c)
                             [ sc_td.(c) <-- select byte 5 4; sc_ta.(c) <-- select byte 1 0 ])
                         @ [ when_
                               (select byte 7 6 <>:. 0 |: (select byte 3 2 <>:. 0))
                               [ sos_bad <--. 1 ]
                           ; sos_cf <--. 0
                           ; sos_ci <-- sos_ci.value +:. 1
                           ; when_
                               (uresize sos_ci.value 8 +:. 1
                                ==: ns.value
                                |: (sos_ci.value ==:. 3))
                               [ sos_phase <--. 2 ]
                           ])
                    ]
                ; when_ last [ sm.set_next Sos_check ]
                ]
            ] )
        ; ( Sos_check
          , [ if_
                ~:(sof_seen.value &: (ns.value ==: nf.value) &: ok_comps &: ~:(sos_bad.value))
                (goto_error Err.scan)
                (clear_preds
                 @ [ bb <--. 0
                   ; bcnt <--. 0
                   ; saw_ff <--. 0
                   ; marker_hit <--. 0
                   ; in_scan <--. 1
                   ; mcu_x <--. 0
                   ; mcu_y <--. 0
                   ; base_x <--. 0
                   ; base_y <--. 0
                   ; rst_left <-- ri.value
                   ; sm.set_next Mcu_start
                   ])
            ] )
        ; Mcu_start, [ j <--. 0; bh <--. 0; bv <--. 0; sm.set_next Block_start ]
        ; Block_start, [ coef_clear <-- vdd; k <--. 0; sm.set_next H_decode ]
        ; ( H_decode
          , [ when_
                (bcnt.value >=:. 16 |: marker_hit.value)
                [ if_
                    dec.valid
                    [ hl <-- dec_len; hidx <-- dec_idx; sm.set_next H_consume ]
                    (goto_error Err.huff_code)
                ]
            ] )
        ; ( H_consume
          , [ cons <-- uresize hl.value 6; huff_rd <-- vdd; sm.set_next H_symbol ] )
        ; ( H_symbol
          , [ if_
                k_is0
                [ s <-- sz
                ; knew <--. 0
                ; quant_rd <-- vdd
                ; quant_rd_k <--. 0
                ; sm.set_next Extra
                ]
                [ if_
                    (sz ==:. 0)
                    [ if_
                        (run ==:. 15)
                        [ k <-- k16
                        ; if_ (k16 >=:. 64) [ sm.set_next Idct_start ] [ sm.set_next H_decode ]
                        ]
                        [ sm.set_next Idct_start ]
                    ]
                    [ knew <-- k_plus_run
                    ; s <-- sz
                    ; quant_rd <-- vdd
                    ; quant_rd_k <-- sat63 k_plus_run
                    ; sm.set_next Extra
                    ]
                ]
            ] )
        ; ( Extra
          , [ when_
                (bcnt.value >=: uresize s.value 6 |: marker_hit.value)
                [ cons <-- uresize s.value 6
                ; coef_val <-- coef_new
                ; when_
                    k_is0
                    [ proc (per_comp 3 (fun c -> when_ (j.value ==:. c) [ pred.(c) <-- dc_val ])) ]
                ; sm.set_next Write
                ]
            ] )
        ; ( Write
          , [ coef_we <-- vdd
            ; k <-- knew.value +:. 1
            ; if_ (knew.value >=:. 63) [ sm.set_next Idct_start ] [ sm.set_next H_decode ]
            ] )
        ; Idct_start, [ idct_start <-- vdd; sm.set_next Idct_wait ]
        ; Idct_wait, [ when_ idct.finished [ sm.set_next Next_block ] ]
        ; ( Next_block
          , [ if_
                ~:bh_last
                [ bh <--. 1; sm.set_next Block_start ]
                [ if_
                    ~:bv_last
                    [ bh <--. 0; bv <--. 1; sm.set_next Block_start ]
                    [ if_
                        ~:j_last
                        [ j <-- j.value +:. 1; bh <--. 0; bv <--. 0; sm.set_next Block_start ]
                        [ px <--. 0; py <--. 0; sm.set_next Color ]
                    ]
                ]
            ] )
        ; ( Color
          , [ color_issue <-- vdd
            ; if_
                px_last
                [ px <--. 0
                ; if_
                    py_last
                    [ drain <--. 0; sm.set_next Color_drain ]
                    [ py <-- py.value +:. 1 ]
                ]
                [ px <-- px.value +:. 1 ]
            ] )
        ; ( Color_drain
          , [ drain <-- drain.value +:. 1; when_ (drain.value ==:. 3) [ sm.set_next Mcu_done ] ]
          )
        ; ( Mcu_done
          , [ if_
                (x_last &: y_last)
                [ sm.set_next Scan_done ]
                [ if_
                    x_last
                    [ mcu_x <--. 0
                    ; base_x <--. 0
                    ; mcu_y <-- mcu_y.value +:. 1
                    ; base_y <-- base_y.value +: mcu_h
                    ]
                    [ mcu_x <-- mcu_x.value +:. 1; base_x <-- base_x.value +: mcu_w ]
                ; if_
                    (ri.value <>:. 0)
                    [ if_
                        (rst_left.value ==:. 1)
                        [ rst_left <-- ri.value; sm.set_next Restart ]
                        [ rst_left <-- rst_left.value -:. 1; sm.set_next Mcu_start ]
                    ]
                    [ sm.set_next Mcu_start ]
                ]
            ] )
        ; ( Restart
          , [ cons <-- bcnt.value
            ; when_
                marker_hit.value
                [ if_
                    is_rst
                    (clear_preds
                     @ [ marker_hit <--. 0
                       ; bb <--. 0
                       ; bcnt <--. 0
                       ; saw_ff <--. 0
                       ; sm.set_next Mcu_start
                       ])
                    [ sm.set_next Scan_done ]
                ]
            ] )
        ; ( Scan_done
          , [ in_scan <--. 0
            ; if_
                marker_hit.value
                [ marker_hit <--. 0; sm.set_next Dispatch ]
                [ if_ saw_ff.value [ saw_ff <--. 0; sm.set_next Marker ] [ sm.set_next Find_ff ] ]
            ] )
        ; Finished, [ when_ i.start start_actions ]
        ; Error, [ when_ i.start start_actions ]
        ]
    ];
  { O.in_ready
  ; pix_valid = r v2r
  ; pix_x = r x2
  ; pix_y = r y2
  ; pix_r = r red
  ; pix_g = r green
  ; pix_b = r blue
  ; width = width.value
  ; height = height.value
  ; busy = ~:(sm.is Idle |: sm.is Finished |: sm.is Error)
  ; finished = sm.is Finished
  ; error = sm.is Error
  ; error_code = err_code.value
  }
;;
