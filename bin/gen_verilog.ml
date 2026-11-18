(* Writes the generated Verilog:
     quartus/jpeg_system.v   board-level system (used by the Quartus project)
     rtl/jpeg_decoder.v      decoder core on its own (for reuse in other designs) *)
open! Base
open Hardcaml

let () =
  let out_dir = if Array.length (Sys.get_argv ()) > 1 then (Sys.get_argv ()).(1) else "." in
  let emit (circuit : Circuit.t) path =
    Rtl.output ~output_mode:(To_file (Stdlib.Filename.concat out_dir path)) Verilog circuit;
    Stdio.printf "wrote %s\n" path
  in
  (let module C = Circuit.With_interface (Jpeg_hw.System.I) (Jpeg_hw.System.O) in
   let scope = Scope.create ~flatten_design:true () in
   emit (C.create_exn ~name:"jpeg_system" (Jpeg_hw.System.create scope)) "quartus/jpeg_system.v");
  let module C = Circuit.With_interface (Jpeg_hw.Decoder.I) (Jpeg_hw.Decoder.O) in
  let scope = Scope.create ~flatten_design:true () in
  emit (C.create_exn ~name:"jpeg_decoder" (Jpeg_hw.Decoder.create scope)) "rtl/jpeg_decoder.v"
;;
