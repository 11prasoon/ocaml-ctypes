(*
 * Copyright (c)  Jeremy Yallop.
 *
 * This file is distributed under the terms of the MIT License.
 * See the file LICENSE for details.
 *)

let c_headers = "
#include <sys/types.h>
#include <sys/stat.h>
#include <fts.h>
#include \"cstubs/cstubs_internals.h\"
"

let make_stubname cname = "fts_stub_" ^ cname

let main () =
  let ml_out = open_out "examples/fts/stub-generation/fts_generated.ml"
  and c_out = open_out "examples/fts/stub-generation/fts_stubs.c" in
  let ml_fmt = Format.formatter_of_out_channel ml_out
  and c_fmt = Format.formatter_of_out_channel c_out in
  Format.fprintf c_fmt "%s@\n" c_headers;
  let module M = Fts_bindings.Bindings(struct
    let foreign cname fn =
      let stub_name = make_stubname cname in
      Cstubs.write_c ~stub_name ~cname c_fmt fn;
      Cstubs.write_ml ~stub_name ~external_name:cname ml_fmt fn
  end) in
  Format.pp_print_flush ml_fmt ();
  Format.pp_print_flush c_fmt ();
  close_out ml_out;
  close_out c_out

let () = main ()
