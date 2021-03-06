(*
 * Copyright (c) 2014 Jeremy Yallop.
 *
 * This file is distributed under the terms of the MIT License.
 * See the file LICENSE for details.
 *)

(* Stub generation driver for the macro tests. *)

let cheader = "
#include <tgmath.h>
#define exp_float exp
#define exp_double exp
"

let () = Tests_common.run ~cheader Sys.argv (module Functions.Stubs)
