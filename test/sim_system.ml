(* Whole-board simulation: ROM model -> jpeg_system -> VGA pins.

   usage: sim_system.exe image.jpg reference.ppm EXPECTED_CHECKSUM_HEX

   1. loads the JPEG into a model of the synchronous ROM,
   2. runs until the decoder finishes and checks the LEDs (done / checksum match),
   3. captures one full VGA frame from the pins (sampled on VGA_CLK rising edges),
      checks the 640x480@60 timing and compares every pixel against the reference
      image shown 2x2 (top-left 320x240 window, black elsewhere). *)

open! Base
open Stdio
open Hardcaml
module S = Jpeg_hw.System
module Sim = Cyclesim.With_interface (S.I) (S.O)

let read_ppm path =
  let s = In_channel.read_all path in
  let toks = ref [] in
  let pos = ref 0 in
  while List.length !toks < 4 do
    while Char.is_whitespace s.[!pos] do
      Int.incr pos
    done;
    let st = !pos in
    while not (Char.is_whitespace s.[!pos]) do
      Int.incr pos
    done;
    toks := String.sub s ~pos:st ~len:(!pos - st) :: !toks
  done;
  Int.incr pos;
  match List.rev !toks with
  | [ "P6"; w; h; _ ] ->
    let w = Int.of_string w and h = Int.of_string h in
    w, h, String.sub s ~pos:!pos ~len:(w * h * 3)
  | _ -> failwith "expected a P6 ppm"
;;

let () =
  let argv = Sys.get_argv () in
  let jpeg = In_channel.read_all argv.(1) in
  let rw, rh, refpix = read_ppm argv.(2) in
  let expected = Int.of_string ("0x" ^ argv.(3)) in
  let rom = Array.create ~len:(1 lsl S.rom_addr_bits) 0 in
  String.iteri jpeg ~f:(fun idx c -> rom.(idx) <- Char.to_int c);
  let scope = Scope.create ~flatten_design:true () in
  let sim = Sim.create (S.create scope) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs ~clock_edge:Before sim in
  let set r v w = r := Bits.of_int ~width:w v in
  set i.expected_checksum expected 32;
  set i.expected_valid 1 1;
  set i.sw 0 10;
  set i.clear 1 1;
  Cyclesim.cycle sim;
  set i.clear 0 1;
  let cycles = ref 0 in
  let step () =
    Cyclesim.cycle sim;
    Int.incr cycles;
    (* synchronous ROM: q updates on the clock edge when enabled *)
    if Bits.to_bool !(o.rom_en) then set i.rom_q rom.(Bits.to_int !(o.rom_addr)) 8
  in
  let led () = Bits.to_int !(o.ledr) in
  while led () land 0b1001 = 0 do
    step ();
    if !cycles > 50_000_000 then failwith "timeout"
  done;
  for _ = 1 to 10 do
    step ()
  done;
  let l = led () in
  printf
    "decode finished after %d cycles: LEDR=%s done=%d match=%d mismatch=%d error=%d code=%d checksum=%08X\n"
    !cycles
    (Bits.to_string !(o.ledr))
    (l land 1)
    ((l lsr 1) land 1)
    ((l lsr 2) land 1)
    ((l lsr 3) land 1)
    ((l lsr 4) land 15)
    (Bits.to_int !(o.checksum));
  let ok = ref (l land 0b0011 = 0b0011) in
  (* ---- capture a VGA frame ---- *)
  let prev_clk = ref (Bits.to_int !(o.vga_clk)) in
  let samples = Queue.create () in
  (* sample = (blank_n, hs, vs, rgb) on each VGA_CLK rising edge *)
  let sample_edge () =
    step ();
    let c = Bits.to_int !(o.vga_clk) in
    let rising = !prev_clk = 0 && c = 1 in
    prev_clk := c;
    if rising
    then
      Some
        ( Bits.to_int !(o.vga_blank_n)
        , Bits.to_int !(o.vga_hs)
        , Bits.to_int !(o.vga_vs)
        , (Bits.to_int !(o.vga_r), Bits.to_int !(o.vga_g), Bits.to_int !(o.vga_b)) )
    else None
  in
  (* wait for the end of a vsync pulse *)
  let rec wait_vs want =
    match sample_edge () with
    | Some (_, _, vs, _) when vs = want -> ()
    | _ -> wait_vs want
  in
  wait_vs 0;
  wait_vs 1;
  (* collect one full frame of pixel clocks (800 x 525) *)
  let total = 800 * 525 in
  while Queue.length samples < total do
    match sample_edge () with
    | Some s -> Queue.enqueue samples s
    | None -> ()
  done;
  let arr = Queue.to_array samples in
  (* timing: hsync period and active pixels per line *)
  let hs_falls = ref [] in
  Array.iteri arr ~f:(fun idx (_, hs, _, _) ->
    if idx > 0
    then (
      let _, phs, _, _ = arr.(idx - 1) in
      if phs = 1 && hs = 0 then hs_falls := idx :: !hs_falls));
  let hs_falls = List.rev !hs_falls in
  let periods =
    List.zip_exn (List.drop_last_exn hs_falls) (List.tl_exn hs_falls)
    |> List.map ~f:(fun (a, b) -> b - a)
    |> List.dedup_and_sort ~compare:Int.compare
  in
  printf
    "hsync periods seen (pixel clocks): %s, hsync pulses in one frame: %d\n"
    (String.concat ~sep:"," (List.map periods ~f:Int.to_string))
    (List.length hs_falls);
  if not (List.equal Int.equal periods [ 800 ]) then ok := false;
  let active = Array.filter arr ~f:(fun (b, _, _, _) -> b = 1) in
  printf "active pixels in frame: %d (expected %d)\n" (Array.length active) (640 * 480);
  if Array.length active <> 640 * 480 then ok := false;
  let bad = ref 0 in
  let show_w = Int.min rw 320 and show_h = Int.min rh 240 in
  Array.iteri active ~f:(fun idx (_, _, _, (r, g, b)) ->
    if idx < 640 * 480
    then (
      let x = idx % 640 and y = idx / 640 in
      let fx = x / 2 and fy = y / 2 in
      let er, eg, eb =
        if fx < show_w && fy < show_h
        then (
          let p = ((fy * rw) + fx) * 3 in
          Char.to_int refpix.[p], Char.to_int refpix.[p + 1], Char.to_int refpix.[p + 2])
        else 0, 0, 0
      in
      if r <> er || g <> eg || b <> eb
      then (
        if !bad < 5
        then printf "  VGA mismatch at %d,%d: got %d,%d,%d want %d,%d,%d\n" x y r g b er eg eb;
        Int.incr bad)));
  printf "VGA frame: %d mismatching pixels\n" !bad;
  if !bad > 0 then ok := false;
  printf "%s (%d cycles total)\n" (if !ok then "SYSTEM PASS" else "SYSTEM FAIL") !cycles;
  if not !ok then Stdlib.exit 1
;;
