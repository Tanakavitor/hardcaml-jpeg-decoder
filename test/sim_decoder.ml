(* Cycle-accurate simulation of the decoder core.

   usage: sim_decoder.exe input.jpg [-ref reference.pnm] [-out out.ppm] [-stall]

   Feeds the JPEG bytes into the core (optionally with random gaps in in_valid), builds the
   image from the pixel stream, prints the checksum used by the FPGA self-check, and, if a
   reference PNM (from "djpeg -dct int -nosmooth") is given, compares every pixel. *)

open! Base
open Stdio
open Hardcaml
module D = Jpeg_hw.Decoder
module Sim = Cyclesim.With_interface (D.I) (D.O)

let read_file path = In_channel.read_all path

(* minimal binary PNM reader (P5 / P6, maxval 255) *)
let read_pnm path =
  let s = read_file path in
  let pos = ref 0 in
  let n = String.length s in
  let rec skip_ws () =
    if !pos < n
    then (
      let c = s.[!pos] in
      if Char.is_whitespace c
      then (
        Int.incr pos;
        skip_ws ())
      else if Char.equal c '#'
      then (
        while !pos < n && not (Char.equal s.[!pos] '\n') do
          Int.incr pos
        done;
        skip_ws ()))
  in
  let token () =
    skip_ws ();
    let start = !pos in
    while !pos < n && not (Char.is_whitespace s.[!pos]) do
      Int.incr pos
    done;
    String.sub s ~pos:start ~len:(!pos - start)
  in
  let magic = token () in
  let w = Int.of_string (token ()) in
  let h = Int.of_string (token ()) in
  let _maxval = token () in
  Int.incr pos;
  let channels =
    match magic with
    | "P5" -> 1
    | "P6" -> 3
    | _ -> failwith "unsupported PNM"
  in
  let data = String.sub s ~pos:!pos ~len:(w * h * channels) in
  w, h, channels, data
;;

let checksum ~w ~h (rgb : Bytes.t) =
  let acc = ref 0 in
  for y = 0 to h - 1 do
    for x = 0 to w - 1 do
      let idx = (y * w) + x in
      let p = idx * 3 in
      let pix =
        Char.to_int (Bytes.get rgb p)
        lor (Char.to_int (Bytes.get rgb (p + 1)) lsl 8)
        lor (Char.to_int (Bytes.get rgb (p + 2)) lsl 16)
      in
      acc := (!acc + (((2 * idx) + 1) * pix)) land 0xFFFF_FFFF
    done
  done;
  !acc
;;

let () =
  let args = Array.to_list (Sys.get_argv ()) |> List.tl_exn in
  let input = ref None in
  let reference = ref None in
  let out = ref None in
  let stall = ref false in
  let rec parse = function
    | "-ref" :: f :: rest ->
      reference := Some f;
      parse rest
    | "-out" :: f :: rest ->
      out := Some f;
      parse rest
    | "-stall" :: rest ->
      stall := true;
      parse rest
    | f :: rest ->
      input := Some f;
      parse rest
    | [] -> ()
  in
  parse args;
  let input = Option.value_exn ~message:"no input file" !input in
  let jpeg = read_file input in
  let len = String.length jpeg in
  let scope = Scope.create ~flatten_design:true () in
  let sim = Sim.create (D.create scope) in
  let i = Cyclesim.inputs sim in
  let o = Cyclesim.outputs ~clock_edge:Before sim in
  let set r v w = r := Bits.of_int ~width:w v in
  let rand = Random.State.make [| 42 |] in
  set i.clear 1 1;
  Cyclesim.cycle sim;
  set i.clear 0 1;
  set i.start 1 1;
  Cyclesim.cycle sim;
  set i.start 0 1;
  let pos = ref 0 in
  let img = ref None in
  let pixels = ref 0 in
  let cycles = ref 0 in
  let finished = ref false in
  let last_progress = ref 0 in
  let max_cycles = 200_000_000 in
  while not !finished do
    let offer = !pos < len && ((not !stall) || Random.State.int rand 100 < 70) in
    set i.in_valid (if offer then 1 else 0) 1;
    set i.in_data (if !pos < len then Char.to_int jpeg.[!pos] else 0) 8;
    Cyclesim.cycle sim;
    Int.incr cycles;
    if offer && Bits.to_bool !(o.in_ready)
    then (
      Int.incr pos;
      last_progress := !cycles);
    if Bits.to_bool !(o.pix_valid)
    then (
      let w = Bits.to_int !(o.width) in
      let h = Bits.to_int !(o.height) in
      let buf =
        match !img with
        | Some b -> b
        | None ->
          let b = Bytes.make (w * h * 3) '\000' in
          img := Some b;
          b
      in
      let x = Bits.to_int !(o.pix_x) in
      let y = Bits.to_int !(o.pix_y) in
      if x >= w || y >= h then failwith (Printf.sprintf "pixel out of range %d,%d" x y);
      let p = ((y * w) + x) * 3 in
      Bytes.set buf p (Char.of_int_exn (Bits.to_int !(o.pix_r)));
      Bytes.set buf (p + 1) (Char.of_int_exn (Bits.to_int !(o.pix_g)));
      Bytes.set buf (p + 2) (Char.of_int_exn (Bits.to_int !(o.pix_b)));
      Int.incr pixels);
    if Bits.to_bool !(o.finished) || Bits.to_bool !(o.error) then finished := true;
    if !cycles > max_cycles then failwith "timeout";
    if !pos >= len && !cycles - !last_progress > 1_000_000
    then (
      printf "STALLED: all %d input bytes consumed but the decoder never finished\n" len;
      Stdlib.exit 3)
  done;
  (* the core asserts finished only after its pixel pipeline has drained *)
  if Bits.to_bool !(o.error)
  then (
    printf "ERROR code %d after %d cycles (byte %d of %d)\n" (Bits.to_int !(o.error_code)) !cycles !pos len;
    Stdlib.exit 2);
  let w = Bits.to_int !(o.width) in
  let h = Bits.to_int !(o.height) in
  let buf = Option.value_exn ~message:"no pixels" !img in
  let expected_pixels = w * h in
  let cs = checksum ~w ~h buf in
  printf
    "%s: %dx%d, %d pixels (expected %d), %d cycles (%.2f ms @ 50 MHz), consumed %d/%d bytes, checksum %08X\n"
    input
    w
    h
    !pixels
    expected_pixels
    !cycles
    (Float.of_int !cycles /. 50_000.)
    !pos
    len
    cs;
  (match !out with
   | Some f ->
     Out_channel.with_file f ~f:(fun oc ->
       Out_channel.output_string oc (Printf.sprintf "P6\n%d %d\n255\n" w h);
       Out_channel.output_bytes oc buf)
   | None -> ());
  match !reference with
  | None -> ()
  | Some f ->
    let rw, rh, ch, data = read_pnm f in
    if rw <> w || rh <> h then failwith "reference size mismatch";
    let bad = ref 0 in
    let maxdiff = ref 0 in
    for idx = 0 to (w * h) - 1 do
      for c = 0 to 2 do
        let refv = Char.to_int data.[(idx * ch) + if ch = 1 then 0 else c] in
        let got = Char.to_int (Bytes.get buf ((idx * 3) + c)) in
        if refv <> got
        then (
          if !bad < 5
          then printf "  mismatch at x=%d y=%d c=%d: got %d want %d\n" (idx % w) (idx / w) c got refv;
          Int.incr bad;
          maxdiff := Int.max !maxdiff (abs (refv - got)))
      done
    done;
    if !bad = 0 && !pixels = expected_pixels
    then printf "  PASS: bit-exact with reference\n"
    else (
      printf "  FAIL: %d mismatching samples (max diff %d)\n" !bad !maxdiff;
      Stdlib.exit 1)
;;
