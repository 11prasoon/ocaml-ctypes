open Ffi
open OUnit


let testlib = Dl.(dlopen ~filename:"clib/test_functions.so" ~flags:[RTLD_NOW])


(*
   Call a C function of type

       int (int ( * )(int, int), int, int)

   passing various OCaml functions of type

       int -> int -> int

   as the first argument.
*)
let test_higher_order_basic () =
  let intfun = Type.(int @-> int @-> returning int) in

  let higher_order_1 = foreign ~from:testlib "higher_order_1"
    Type.(funptr intfun @-> int @-> int @-> returning int)
  in

  (* higher_order_1 f x y returns true iff f x y == x + y *)
  assert_equal 1 (higher_order_1 ( + ) 2 3);
  assert_equal 0 (higher_order_1 ( * ) 2 3);
  assert_equal 0 (higher_order_1 min 2 3);
  assert_equal 1 (higher_order_1 min (-3) 0)


(*
  Call a C function of type 

       int (int ( * )(int ( * )(int, int), int, int), int ( * )(int, int), int, int)

  passing OCaml functions of type

       (int -> int -> int) -> int -> int -> int
       int -> int -> int

  as the first and second arguments.
*)
let test_higher_higher_order () =
  let intfun = Type.(int @-> int @-> returning int) in
  let acceptor = Type.(funptr intfun @-> int @-> int @-> returning int) in
  let higher_order_3 = foreign ~from:testlib "higher_order_3"
    Type.(funptr acceptor @-> funptr intfun @-> int @-> int @-> returning int)
  in

  let acceptor op x y = op x (op x y) in
  (* let add = foreign ~from:testlib "add" intfun in *)

  assert_equal 10 (higher_order_3 acceptor ( + ) 3 4);
  assert_equal 36 (higher_order_3 acceptor ( * ) 3 4)


(*
  Call a C function of type

       int ( *(int))(int)

  (i.e. a function that returns a pointer-to-function) and ensure that we can
  call the returned function from OCaml.
*)
let test_returning_pointer_to_function () =
  let intfun = Type.(int @-> int @-> returning int) in
  let returning_funptr = foreign ~from:testlib "returning_funptr"
    Type.(int @-> returning (funptr intfun))
  in

  let add = returning_funptr 0 in

  let times = returning_funptr 1 in

  assert_equal 22 (add 10 12);
  assert_equal 15 (times 3 5);
  assert_equal 101 (add 100 1);
  assert_equal 0 (times 0 12)
  

(*
  Call a C function of type

       int (int ( * ( * )(int))(int), int)

  (i.e. a function whose first argument is a pointer-to-function
  returning a pointer-to-function.)
*)
let test_callback_returns_pointer_to_function () =
  let intfun = Type.(int @-> returning int) in
  let callback_returns_funptr = foreign ~from:testlib "callback_returns_funptr"
    Type.(funptr (int @-> returning (funptr intfun)) @-> int @-> returning int)
  in

  let callback = function
    | 0 -> ( + ) 10
    | 1 -> ( * ) 13
    | _ -> invalid_arg "callback"
  in

  assert_equal 280 (callback_returns_funptr callback 0)


let suite = "Higher-order tests" >:::
  ["test_higher_order_basic" >:: test_higher_order_basic;
   "test_higher_higher_order" >:: test_higher_higher_order;
   "test_returning_pointer_to_function" >:: test_returning_pointer_to_function;
   "test_callback_returns_pointer_to_function" >:: test_callback_returns_pointer_to_function;
  ]


let _ =
  run_test_tt_main suite
