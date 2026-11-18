(* 8x8 inverse DCT, bit-exact with libjpeg / libjpeg-turbo "jidctint.c" (JDCT_ISLOW,
   CONST_BITS = 13, PASS1_BITS = 2), including the range-limit table of jdmaster.c.

   Why the widths below are exact (not an approximation):
   - The pass-2 result that matters is bits [27:18] of a sum built only from additions,
     subtractions, left shifts and multiplications by integer constants. Those are ring
     operations, so computing pass 2 modulo 2^28 gives the same bits.
   - Pass 2 therefore only needs the workspace modulo 2^28, i.e. bits [38:11] of the
     pass-1 sum, so pass 1 can be computed modulo 2^39.
   One 39-bit datapath is used for both passes. *)

open! Base
open Hardcaml
open Signal

let w = 39
let ws_width = 28

(* jidctint.c constants, FIX(x) = round(x * 2^13) *)
let fix_0_298631336 = 2446
let fix_0_390180644 = 3196
let fix_0_541196100 = 4433
let fix_0_765366865 = 6270
let fix_0_899976223 = 7373
let fix_1_175875602 = 9633
let fix_1_501321110 = 12299
let fix_1_847759065 = 15137
let fix_1_961570560 = 16069
let fix_2_053119869 = 16819
let fix_2_562915447 = 20995
let fix_3_072711026 = 25172

(* x * c mod 2^w, for a positive constant c < 2^15 *)
let mulc x c = uresize (x *: of_int ~width:15 c) w

(* One 8-point 1-D IDCT, 5 register stages. [tag] travels alongside the data;
   its bit 0 must be the "pass 2" flag (selects the rounding constant). *)
let idct_1d spec ~(tag : Signal.t) (x : Signal.t array) =
  let r s = reg spec s in
  (* stage 1: pre-additions *)
  let tag1 = r tag in
  let x0p4 = r (x.(0) +: x.(4)) in
  let x0m4 = r (x.(0) -: x.(4)) in
  let s26 = r (x.(2) +: x.(6)) in
  let x2_1 = r x.(2) in
  let x6_1 = r x.(6) in
  let z1 = x.(7) +: x.(1) in
  let z2 = x.(5) +: x.(3) in
  let z3 = x.(7) +: x.(3) in
  let z4 = x.(5) +: x.(1) in
  let z1_1 = r z1 in
  let z2_1 = r z2 in
  let z3_1 = r z3 in
  let z4_1 = r z4 in
  let s34_1 = r (z3 +: z4) in
  let x7_1 = r x.(7) in
  let x5_1 = r x.(5) in
  let x3_1 = r x.(3) in
  let x1_1 = r x.(1) in
  (* stage 2: multiplications. The DESCALE rounding constant is folded into tmp0/tmp1,
     which feed every output, so it is added exactly once per output. *)
  let tag2 = r tag1 in
  let pass2 = bit tag1 0 in
  let rnd = mux2 pass2 (of_int ~width:w (1 lsl 17)) (of_int ~width:w (1 lsl 10)) in
  let z1e = r (mulc s26 fix_0_541196100) in
  let mx6 = r (mulc x6_1 fix_1_847759065) in
  let mx2 = r (mulc x2_1 fix_0_765366865) in
  let tmp0 = r (sll x0p4 13 +: rnd) in
  let tmp1 = r (sll x0m4 13 +: rnd) in
  let z5 = r (mulc s34_1 fix_1_175875602) in
  let t0 = r (mulc x7_1 fix_0_298631336) in
  let t1 = r (mulc x5_1 fix_2_053119869) in
  let t2 = r (mulc x3_1 fix_3_072711026) in
  let t3 = r (mulc x1_1 fix_1_501321110) in
  let z1m = r (mulc z1_1 fix_0_899976223) in
  let z2m = r (mulc z2_1 fix_2_562915447) in
  let z3m = r (mulc z3_1 fix_1_961570560) in
  let z4m = r (mulc z4_1 fix_0_390180644) in
  (* stage 3 *)
  let tag3 = r tag2 in
  let tmp2 = r (z1e -: mx6) in
  let tmp3 = r (z1e +: mx2) in
  let tmp0_3 = r tmp0 in
  let tmp1_3 = r tmp1 in
  let z3s = r (z5 -: z3m) in
  let z4s = r (z5 -: z4m) in
  let t0_3 = r t0 in
  let t1_3 = r t1 in
  let t2_3 = r t2 in
  let t3_3 = r t3 in
  let z1m_3 = r z1m in
  let z2m_3 = r z2m in
  (* stage 4 *)
  let tag4 = r tag3 in
  let tmp10 = r (tmp0_3 +: tmp3) in
  let tmp13 = r (tmp0_3 -: tmp3) in
  let tmp11 = r (tmp1_3 +: tmp2) in
  let tmp12 = r (tmp1_3 -: tmp2) in
  let o0 = r (t0_3 -: z1m_3 +: z3s) in
  let o1 = r (t1_3 -: z2m_3 +: z4s) in
  let o2 = r (t2_3 -: z2m_3 +: z3s) in
  let o3 = r (t3_3 -: z1m_3 +: z4s) in
  (* stage 5: output butterflies *)
  let tag5 = r tag4 in
  let y =
    [| r (tmp10 +: o3)
     ; r (tmp11 +: o2)
     ; r (tmp12 +: o1)
     ; r (tmp13 +: o0)
     ; r (tmp13 -: o0)
     ; r (tmp12 -: o1)
     ; r (tmp11 -: o2)
     ; r (tmp10 -: o3)
    |]
  in
  tag5, y
;;

(* jdmaster.c post-IDCT range limit, indexed by the low 10 bits of the descaled value *)
let range_limit (i : Signal.t) =
  assert (width i = 10);
  let top3 = select i 9 7 in
  let pass_through = top3 ==:. 0 |: (top3 ==:. 7) in
  let wrapped = select (i +:. 128) 7 0 in
  mux2 pass_through wrapped (mux2 (bit i 9) (zero 8) (ones 8))
;;

module State = struct
  type t =
    | Idle
    | Feed1
    | Wait1
    | Feed2
    | Wait2
  [@@deriving sexp_of, compare, enumerate]
end

type t =
  { finished : Signal.t (* one-cycle pulse *)
  ; row_we : Signal.t
  ; row_idx : Signal.t (* 3 bits *)
  ; row_data : Signal.t (* 64 bits, sample k in bits [8k+7:8k] *)
  }

(* [coef] are 64 dequantized coefficients in natural (row-major) order, 32 bits each.
   They must stay stable from [start] until the first 8 cycles have passed (pass 1 feed). *)
let create spec ~start ~(coef : Signal.t array) =
  assert (Array.length coef = 64);
  let open Always in
  let sm = State_machine.create (module State) spec in
  let cnt = Variable.reg spec ~width:3 in
  let feed = Variable.wire ~default:gnd in
  let pass2 = Variable.wire ~default:gnd in
  let finished = Variable.wire ~default:gnd in
  (* forward declaration of the in-flight flag *)
  let inflight = wire 1 in
  compile
    [ sm.switch
        [ Idle, [ when_ start [ cnt <--. 0; sm.set_next Feed1 ] ]
        ; ( Feed1
          , [ feed <-- vdd
            ; cnt <-- cnt.value +:. 1
            ; when_ (cnt.value ==:. 7) [ sm.set_next Wait1 ]
            ] )
        ; Wait1, [ unless inflight [ cnt <--. 0; sm.set_next Feed2 ] ]
        ; ( Feed2
          , [ feed <-- vdd
            ; pass2 <-- vdd
            ; cnt <-- cnt.value +:. 1
            ; when_ (cnt.value ==:. 7) [ sm.set_next Wait2 ]
            ] )
        ; Wait2, [ unless inflight [ finished <-- vdd; sm.set_next Idle ] ]
        ]
    ];
  (* workspace registers, 28 bits each, row-major *)
  let ws_we = Array.init 64 ~f:(fun _ -> wire 1) in
  let ws_d = Array.init 64 ~f:(fun _ -> wire ws_width) in
  let ws = Array.init 64 ~f:(fun n -> reg spec ~enable:ws_we.(n) ws_d.(n)) in
  (* input selection: pass 1 takes column [cnt] of coef, pass 2 takes row [cnt] of ws *)
  let x_in =
    Array.init 8 ~f:(fun k ->
      let p1 = mux cnt.value (List.init 8 ~f:(fun u -> sresize coef.((k * 8) + u) w)) in
      let p2 = mux cnt.value (List.init 8 ~f:(fun r -> sresize ws.((r * 8) + k) w)) in
      mux2 pass2.value p2 p1)
  in
  (* stage 0: register the selected inputs *)
  let x0 = Array.map x_in ~f:(reg spec) in
  let tag_in = concat_msb [ feed.value; cnt.value; pass2.value ] in
  let tag0 = reg spec tag_in in
  let tag5, y = idct_1d spec ~tag:tag0 x0 in
  let valid_of t = msb t in
  (* in flight: anything in stages 0..5. tag0..tag5 are partly internal to idct_1d, so
     track a separate valid shift register of the same depth (6 stages). *)
  let v = Array.create ~len:6 gnd in
  v.(0) <- reg spec feed.value;
  for i = 1 to 5 do
    v.(i) <- reg spec v.(i - 1)
  done;
  inflight <== reduce ~f:( |: ) (Array.to_list v);
  let out_valid = valid_of tag5 in
  let out_idx = select tag5 3 1 in
  let out_pass2 = bit tag5 0 in
  (* pass-1 outputs go to workspace column [out_idx] *)
  for n = 0 to 63 do
    let row = n / 8 in
    let col = n % 8 in
    ws_we.(n) <== (out_valid &: ~:out_pass2 &: (out_idx ==:. col));
    ws_d.(n) <== select y.(row) (w - 1) (w - ws_width)
  done;
  let samples = Array.map y ~f:(fun yk -> range_limit (select yk 27 18)) in
  { finished = finished.value
  ; row_we = out_valid &: out_pass2
  ; row_idx = out_idx
  ; row_data = concat_msb (List.rev (Array.to_list samples))
  }
;;
